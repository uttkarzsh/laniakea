// Application logic for the age-check demo: no SwiftUI and no Bundle access.
// Callers hand in the proving artifact and the circuit WASM as Data, so the same
// code runs in the app and in the macOS logic test (Tests-macOS/).
//
// What a result means: the circuit's public signals are [out, threshold], where
// out = 1 if age >= threshold and 0 otherwise. The circuit does NOT constrain
// out == 1, so a valid proof exists for an ineligible age too. Eligibility is
// therefore decided only by reading the public signals (see `classify`), never
// by the fact that proving succeeded. This app does not verify proofs.
//
// Range: circomlib's GreaterEqThan(8) is only meaningful for inputs below 2^8,
// and the circuit does not enforce that. Some larger ages fail an internal
// assertion (300); others prove (256, with out = 1), as does a field element near
// the modulus (with out = 0). The 0...255 range is enforced here, by `parseAge`,
// before anything reaches the prover.

import Foundation
import Laniakea

/// Why the text typed into the age field cannot be sent to the prover.
nonisolated enum AgeInputError: Error, Equatable, Sendable {
    case empty
    case notANumber
    case negative
    /// Above `AgeProofService.maxValue`: the circuit compares 8-bit numbers.
    case outOfRange
}

/// What a proof's public signals say about the age condition.
nonisolated enum Eligibility: Equatable, Sendable {
    /// `out == 1`: the circuit computed age >= threshold.
    case eligible
    /// `out == 0`: a valid proof that the condition is false.
    case notEligible
}

/// Why returned public signals were not accepted.
nonisolated enum SignalError: Error, Equatable, Sendable {
    case wrongCount(expected: Int, got: Int)
    /// The proof is about a different threshold than the one the app asked for.
    case thresholdMismatch(expected: String, got: String)
    /// `out` is neither "0" nor "1".
    case unexpectedOutput(String)
}

/// A generated (not verified) proof and what its public signals say.
nonisolated struct AgeProof: Equatable, Sendable {
    let eligibility: Eligibility
    /// `[out, threshold]`, as returned by the prover.
    let publicSignals: [String]
    /// snarkjs `proof.json` layout.
    let proofJson: String
    /// Wall-clock time of the prover call (witness generation and proving).
    let seconds: Double
}

/// Everything that can go wrong between "resources in hand" and "classified proof".
nonisolated enum AgeProofError: Error, Equatable, Sendable {
    /// A bundled resource could not be found or read (`name`, then why).
    case resourceUnavailable(name: String, detail: String)
    /// The Rust prover reported a typed error.
    case prover(ProverError)
    /// The loaded circuit does not have the two public signals this app expects.
    case unexpectedSignalCount(Int)
    /// A proof was generated but its public signals are not a valid answer.
    case unexpectedSignals(SignalError, [String])
    /// An error outside `ProverError` from the generated bindings (for example a
    /// Rust panic surfaced by UniFFI). Should not happen.
    case bindingFailure(String)
}

/// The two files the prover is built from.
nonisolated struct CircuitResources: Sendable {
    let artifact: Data
    let wasm: Data
}

/// Owns one Rust prover for the age_check circuit.
///
/// Concurrency: an actor, so the non-Sendable `LaniakeaProver` is created inside
/// it and never leaves it. No `@unchecked Sendable` is needed: all calls into the
/// prover happen on this actor's executor, one at a time, and never on the main
/// thread. (The Rust object would tolerate concurrent calls, being `Send + Sync`
/// with `prove(&self)`, but nothing here relies on that.)
///
/// `prove` blocks its executor thread for the duration of the proof: the Rust call
/// cannot yield. That is CPU-bound work, which the cooperative pool is meant for;
/// pinning it to a dedicated thread would need a custom actor executor (iOS 17+).
actor AgeProofService {
    /// Fixed by this demo: the user only enters an age.
    static let threshold: UInt8 = 18
    /// The circuit compares 8-bit numbers (`GreaterEqThan(8)`), whose result is
    /// only meaningful below 2^8. The circuit does not check this; `parseAge` does.
    static let maxValue: UInt8 = 255
    /// age_check's public signals: `[out, threshold]`.
    static let expectedPublicSignals = 2

    private let prover: LaniakeaProver

    /// Validates the artifact and compiles the WASM: real work, so construct off
    /// the main thread (this initializer runs on the caller's thread).
    init(resources: CircuitResources) throws(AgeProofError) {
        let prover: LaniakeaProver
        do {
            prover = try LaniakeaProver(artifactBytes: resources.artifact, wasmBytes: resources.wasm)
        } catch let error as ProverError {
            throw .prover(error)
        } catch {
            throw .bindingFailure(String(describing: error))
        }
        let count = Int(prover.numPublicSignals())
        guard count == Self.expectedPublicSignals else {
            throw .unexpectedSignalCount(count)
        }
        self.prover = prover
    }

    /// Generate a proof that `age >= threshold` or that it is not, and classify it.
    func prove(age: UInt8) throws(AgeProofError) -> AgeProof {
        try prove(ageDecimal: String(age))
    }

    /// Sends `ageDecimal` to the prover as is, bypassing the app's range check.
    /// Internal so that the logic test can show what the circuit itself does with
    /// out-of-range values (see the file comment); the app only calls `prove(age:)`.
    func prove(ageDecimal: String) throws(AgeProofError) -> AgeProof {
        // Structurally guaranteed by actor isolation; checked because blocking the
        // main thread here would freeze the UI.
        dispatchPrecondition(condition: .notOnQueue(.main))
        debugTrace("prover-call mainThread=\(Thread.isMainThread)")

        let inputs = [
            CircuitInput(name: "age", values: [ageDecimal]),
            CircuitInput(name: "threshold", values: [String(Self.threshold)]),
        ]
        let start = DispatchTime.now().uptimeNanoseconds
        let result: ProofResult
        do {
            result = try prover.prove(inputs: inputs)
        } catch let error as ProverError {
            throw .prover(error)
        } catch {
            throw .bindingFailure(String(describing: error))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        switch Self.classify(publicSignals: result.publicSignals) {
        case .success(let eligibility):
            return AgeProof(
                eligibility: eligibility,
                publicSignals: result.publicSignals,
                proofJson: result.proofJson,
                seconds: seconds
            )
        case .failure(let error):
            throw .unexpectedSignals(error, result.publicSignals)
        }
    }

    /// Interpret age_check's public signals `[out, threshold]`.
    ///
    /// Accepts exactly `["1", t]` (eligible) and `["0", t]` (not eligible), where `t`
    /// is the decimal threshold the app asked for. Anything else is rejected: a
    /// different count, a different threshold (the proof would be about another
    /// statement), or an `out` that is not 0 or 1. Signals are canonical decimals,
    /// so comparison is by exact string.
    static func classify(
        publicSignals: [String],
        threshold: UInt8 = threshold
    ) -> Result<Eligibility, SignalError> {
        guard publicSignals.count == expectedPublicSignals else {
            return .failure(.wrongCount(expected: expectedPublicSignals, got: publicSignals.count))
        }
        let expectedThreshold = String(threshold)
        guard publicSignals[1] == expectedThreshold else {
            return .failure(.thresholdMismatch(expected: expectedThreshold, got: publicSignals[1]))
        }
        switch publicSignals[0] {
        case "1": return .success(.eligible)
        case "0": return .success(.notEligible)
        case let other: return .failure(.unexpectedOutput(other))
        }
    }

    /// Parse the age field. Accepts ASCII digits only (surrounding whitespace is
    /// ignored), with a value from 0 to `maxValue`. Nothing that fails here is
    /// ever sent to the prover.
    static func parseAge(_ text: String) -> Result<UInt8, AgeInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }

        func isASCIIDigits(_ s: Substring) -> Bool {
            !s.isEmpty && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
        if trimmed.hasPrefix("-") {
            return isASCIIDigits(trimmed.dropFirst()) ? .failure(.negative) : .failure(.notANumber)
        }
        guard isASCIIDigits(Substring(trimmed)) else { return .failure(.notANumber) }

        // Arbitrarily long digit strings must not overflow: strip leading zeros and
        // compare lengths before converting.
        let digits = trimmed.drop { $0 == "0" }
        if digits.isEmpty { return .success(0) }
        guard digits.count <= 3, let value = Int(digits), value <= Int(maxValue) else {
            return .failure(.outOfRange)
        }
        return .success(UInt8(value))
    }
}

// MARK: - Messages for the app's own errors (ProverError's are in ProverError+Message.swift)

nonisolated extension AgeInputError {
    var userMessage: String {
        switch self {
        case .empty: "Enter your age."
        case .notANumber: "Enter the age as a whole number, using digits only."
        case .negative: "The age cannot be negative."
        case .outOfRange: "Enter an age from 0 to \(AgeProofService.maxValue). The circuit compares 8-bit numbers."
        }
    }
}

nonisolated extension AgeProofError {
    var userMessage: String {
        switch self {
        case .resourceUnavailable(let name, _):
            "The bundled file \(name) is missing or unreadable. Rebuild the app with its resources."
        case .prover(let error):
            error.userMessage
        case .unexpectedSignalCount(let count):
            "The bundled circuit has \(count) public signals; this app expects \(AgeProofService.expectedPublicSignals). The resources do not match the app."
        case .unexpectedSignals:
            "The prover returned public signals this app does not accept, so the result was discarded."
        case .bindingFailure:
            "An unexpected error occurred while calling the prover."
        }
    }

    /// Diagnostic text for the details section. For people, not for parsing.
    var debugDetail: String {
        switch self {
        case .resourceUnavailable(let name, let detail):
            "\(name): \(detail)"
        case .prover(let error):
            error.debugDetail
        case .unexpectedSignalCount(let count):
            "numPublicSignals() == \(count)"
        case .unexpectedSignals(let error, let signals):
            "\(error); publicSignals = \(signals)"
        case .bindingFailure(let detail):
            detail
        }
    }
}
