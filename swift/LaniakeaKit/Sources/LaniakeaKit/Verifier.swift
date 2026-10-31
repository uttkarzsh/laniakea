import Foundation
internal import _LaniakeaBindings

/// Verifies Groth16 proofs, on the device, against one circuit's verification key
/// (snarkjs `verification_key.json`, from `snarkjs zkey export verificationkey`).
///
/// ```swift
/// let url = Bundle.main.url(forResource: "verification_key", withExtension: "json")!
/// let verifier = try Verifier(verificationKeyAt: url)
/// let valid = try await verifier.verify(proof)     // or verify(proofJSON:publicSignals:)
/// ```
///
/// **Results.** `true`: the proof is valid for these public signals under this key.
/// `false`: everything was well formed but the proof does not check out (altered or
/// forged, other public signals, or made for another key). A thrown `VerificationError`
/// (`.invalidProof`, `.invalidPublicSignals`): the input could not be checked at all.
/// Only `true` accepts; treat `false` and an error alike.
///
/// **What `true` means.** Some private inputs satisfy the circuit with exactly these
/// public signals, assuming the key comes from an honest setup for that circuit. It does
/// not mean your application's condition holds: read the public signals (the `age_check`
/// example has valid proofs with `out = 0`). And the key must be one *you* chose and
/// trust, bundled with or pinned by the verifying app: a key that arrives with the proof
/// proves nothing. Verifying a proof on the same device that generated it only checks
/// the prover; it convinces no one else.
///
/// **Concurrency.** An actor, like `Prover`. Building it parses and validates the key;
/// each `verify` is a few pairings (milliseconds), synchronous Rust work on a
/// cooperative-pool thread, never the main thread. No `@unchecked Sendable` is used.
public actor Verifier {
    /// How many public signals a proof for this key carries.
    public nonisolated let publicSignalCount: Int

    private let engine: LaniakeaVerifier

    /// Reads a snarkjs `verification_key.json`.
    ///
    /// - Throws: `VerificationError.invalidVerificationKey` if it is not a Groth16 BN254
    ///   (`"bn128"`) key with valid points.
    public init(verificationKeyJSON: String) throws {
        do {
            engine = try LaniakeaVerifier(verificationKeyJson: verificationKeyJSON)
        } catch {
            throw VerificationError(wrapping: error)
        }
        publicSignalCount = Int(engine.numPublicSignals())
    }

    /// Reads a snarkjs `verification_key.json` from a file.
    ///
    /// - Throws: `VerificationError.keyUnreadable` or `.invalidVerificationKey`.
    public init(verificationKeyAt url: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VerificationError.keyUnreadable(file: url.path, reason: error.localizedDescription)
        }
        try self.init(verificationKeyJSON: text)
    }

    /// Verifies a proof from `Prover.prove`. See the type's documentation for what the
    /// result means.
    ///
    /// - Throws: `VerificationError.invalidProof` or `.invalidPublicSignals`.
    public func verify(_ proof: Proof) throws -> Bool {
        try verify(proofJSON: proof.proofJSON, publicSignals: proof.publicSignals)
    }

    /// Verifies a proof received from elsewhere: `proofJSON` is snarkjs `proof.json`,
    /// `publicSignals` the canonical decimal strings of `public.json`, in order.
    ///
    /// - Throws: `VerificationError.invalidProof` or `.invalidPublicSignals`.
    public func verify(proofJSON: String, publicSignals: [String]) throws -> Bool {
        do {
            return try engine.verify(proofJson: proofJSON, publicSignals: publicSignals)
        } catch {
            throw VerificationError(wrapping: error)
        }
    }
}

/// What `Verifier` throws. None of these is a proof that failed to verify (that is
/// `false`): each says the input could not be checked at all. A separate type from
/// `LaniakeaError`, so that adding verification did not add cases to an enum that apps
/// switch over. The `detail` and `reason` strings are for people, not for parsing.
public enum VerificationError: Error, Sendable, Equatable {
    /// The verification key file could not be read.
    case keyUnreadable(file: String, reason: String)
    /// The verification key is not a usable snarkjs Groth16 BN254 key (bad JSON, another
    /// protocol or curve, `nPublic` not matching `IC`, or an invalid point).
    case invalidVerificationKey(detail: String)
    /// The proof is not a well-formed Groth16 BN254 proof (bad JSON, a non-canonical
    /// coordinate, a point off the curve or outside the subgroup).
    case invalidProof(detail: String)
    /// The public signals do not fit the key: a different count, or a value that is not a
    /// canonical decimal below the BN254 scalar field modulus.
    case invalidPublicSignals(detail: String)
    /// A bug or a version mismatch inside Laniakea. Never caused by the caller's input.
    case internalFailure(detail: String)
}

extension VerificationError {
    /// Wraps whatever the generated bindings threw.
    init(wrapping error: any Error) {
        switch error {
        case let error as VerificationError: self = error
        case let error as VerifierError: self.init(error)
        default: self = .internalFailure(detail: String(describing: error))
        }
    }

    /// Exhaustive, with no `default`: a case added to the Rust `VerifierError` fails to
    /// compile here until it is mapped on purpose.
    init(_ error: VerifierError) {
        switch error {
        case .InvalidVerificationKey(let detail): self = .invalidVerificationKey(detail: detail)
        case .InvalidProof(let detail): self = .invalidProof(detail: detail)
        case .InvalidPublicSignals(let detail): self = .invalidPublicSignals(detail: detail)
        case .Internal(let detail): self = .internalFailure(detail: detail)
        }
    }
}

extension VerificationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyUnreadable(let file, _): "The verification key \(file) could not be read."
        case .invalidVerificationKey: "The verification key is not a usable Groth16 BN254 key."
        case .invalidProof: "The proof is malformed and could not be checked."
        case .invalidPublicSignals: "The public signals do not match the verification key."
        case .internalFailure: "An internal error occurred in the verifier."
        }
    }
}

extension VerificationError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .keyUnreadable(let file, let reason): "keyUnreadable: \(file): \(reason)"
        case .invalidVerificationKey(let detail): "invalidVerificationKey: \(detail)"
        case .invalidProof(let detail): "invalidProof: \(detail)"
        case .invalidPublicSignals(let detail): "invalidPublicSignals: \(detail)"
        case .internalFailure(let detail): "internalFailure: \(detail)"
        }
    }
}
