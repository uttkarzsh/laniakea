// Application logic for the age-check demo: no SwiftUI and no Bundle access.
// Callers hand in a `Circuit` (the proving artifact and the circuit WASM), so the
// same code runs in the app and in the macOS logic test (Tests-macOS/). Everything
// that talks to the Rust prover goes through the LaniakeaKit SDK (Circuit, Prover,
// Proof, LaniakeaError); this file only knows the age_check circuit.
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
import LaniakeaKit

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

/// Everything that can go wrong between "circuit in hand" and "classified proof".
nonisolated enum AgeProofError: Error, Equatable, Sendable {
    /// The SDK reported a typed error: loading the circuit's files, the artifact or
    /// WASM, the inputs, the circuit itself, or proving.
    case sdk(LaniakeaError)
    /// The loaded circuit does not have the two public signals this app expects.
    case unexpectedSignalCount(Int)
    /// A proof was generated but its public signals are not a valid answer.
    case unexpectedSignals(SignalError, [String])

    /// An error from the SDK, as an `AgeProofError`. Everything the SDK throws is a
    /// `LaniakeaError`; anything else is reported as an internal failure.
    static func wrapping(_ error: any Error) -> AgeProofError {
        .sdk(error as? LaniakeaError ?? .internalFailure(detail: String(describing: error)))
    }
}

/// Proves age_check statements through the SDK's `Prover`.
///
/// Concurrency: `Prover` is an actor, so the proof runs on its executor, one at a time
/// and never on the main thread, and nothing here needs `@unchecked Sendable`. This
/// type only holds the prover and the demo's constants.
nonisolated struct AgeProofService: Sendable {
    /// Fixed by this demo: the user only enters an age.
    static let threshold: UInt8 = 18
    /// The circuit compares 8-bit numbers (`GreaterEqThan(8)`), whose result is
    /// only meaningful below 2^8. The circuit does not check this; `parseAge` does.
    static let maxValue: UInt8 = 255
    /// age_check's public signals: `[out, threshold]`.
    static let expectedPublicSignals = 2

    private let prover: Prover

    /// Validates the artifact and compiles the WASM: real work, which `Prover` does off
    /// the caller's thread.
    init(circuit: Circuit) async throws(AgeProofError) {
        let prover: Prover
        do {
            prover = try await Prover(circuit: circuit)
        } catch {
            throw .wrapping(error)
        }
        guard prover.publicSignalCount == Self.expectedPublicSignals else {
            throw .unexpectedSignalCount(prover.publicSignalCount)
        }
        self.prover = prover
    }

    /// Generate a proof that `age >= threshold` or that it is not, and classify it.
    func prove(age: UInt8) async throws(AgeProofError) -> AgeProof {
        try await prove(ageDecimal: String(age))
    }

    /// Sends `ageDecimal` to the prover as is, bypassing the app's range check.
    /// Internal so that the logic test can show what the circuit itself does with
    /// out-of-range values (see the file comment); the app only calls `prove(age:)`.
    func prove(ageDecimal: String) async throws(AgeProofError) -> AgeProof {
        let start = DispatchTime.now().uptimeNanoseconds
        let proof: Proof
        do {
            proof = try await prover.prove([
                "age": .decimal(ageDecimal),
                "threshold": .integer(Int(Self.threshold)),
            ])
        } catch {
            throw .wrapping(error)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        switch Self.classify(publicSignals: proof.publicSignals) {
        case .success(let eligibility):
            return AgeProof(
                eligibility: eligibility,
                publicSignals: proof.publicSignals,
                proofJson: proof.proofJSON,
                seconds: seconds
            )
        case .failure(let error):
            throw .unexpectedSignals(error, proof.publicSignals)
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

// MARK: - Messages for the app's own errors (LaniakeaError's are in ProverError+Message.swift)

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
        case .sdk(let error):
            error.userMessage
        case .unexpectedSignalCount(let count):
            "The bundled circuit has \(count) public signals; this app expects \(AgeProofService.expectedPublicSignals). The resources do not match the app."
        case .unexpectedSignals:
            "The prover returned public signals this app does not accept, so the result was discarded."
        }
    }

    /// Diagnostic text for the details section. For people, not for parsing.
    var debugDetail: String {
        switch self {
        case .sdk(let error):
            error.debugDescription
        case .unexpectedSignalCount(let count):
            "numPublicSignals() == \(count)"
        case .unexpectedSignals(let error, let signals):
            "\(error); publicSignals = \(signals)"
        }
    }
}
