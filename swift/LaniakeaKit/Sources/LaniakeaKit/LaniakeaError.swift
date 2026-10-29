import Foundation
internal import _LaniakeaBindings

/// Everything Laniakea can throw. Every error from `Circuit`, `Prover` and `Proof`
/// is a `LaniakeaError`, except `CancellationError` when the calling task was
/// cancelled before proving started.
///
/// The cases are stable categories. Their `detail` and `reason` strings are
/// diagnostics for people (they come from the Rust prover or from Foundation):
/// show them, log them, but do not parse them.
///
/// Valid proof or not, a successful `prove` never means the application condition
/// holds. A circuit rejecting its inputs is `.circuitRejectedInputs`; a circuit that
/// accepts them and computes "false" still returns a valid proof (see `Proof`).
public enum LaniakeaError: Error, Sendable, Equatable {
    // MARK: Loading the circuit

    /// A circuit file could not be found or read. `file` is a path or, for a
    /// missing bundle resource, the resource's file name.
    case fileUnreadable(file: String, reason: String)
    /// The proving artifact is missing data, damaged, or internally inconsistent
    /// (including an artifact whose size does not fit the WASM circuit).
    case invalidArtifact(detail: String)
    /// The proving artifact has the Laniakea header but a format version this SDK
    /// does not read (`found`; this SDK reads `supported`). Typically the artifact is
    /// newer than the SDK: update the SDK, or re-export the artifact with a matching
    /// `export_artifact`. A file without the header at all (an artifact from before
    /// format 1) is `.invalidArtifact`.
    case unsupportedArtifactVersion(found: Int, supported: Int)
    /// The WASM is not a usable Circom circuit for this prover: not valid WASM,
    /// a field other than BN254, or a module the interpreter cannot load.
    case invalidCircuit(detail: String)

    // MARK: Inputs (the caller's names and values)

    /// An input value is not a canonical decimal below the BN254 scalar field
    /// modulus: negative, not a number, leading zeros, or too large. `signal` is the
    /// input's name, `index` the position within its values, `value` the offending
    /// text (truncated if long).
    case invalidInputValue(signal: String, index: Int, value: String)
    /// The circuit has no input signal with this name.
    case unknownInput(name: String)
    /// The same input name was supplied more than once.
    case duplicateInput(name: String)
    /// An input has the wrong number of values (an array signal's length).
    case wrongInputCount(signal: String, expected: Int, got: Int)
    /// Not every input value the circuit needs was supplied.
    case missingInputs(provided: Int, expected: Int)

    // MARK: Proving

    /// The circuit evaluated the inputs and rejected them: one of its `assert`s or
    /// `===` constraints failed. The inputs are outside what the circuit accepts.
    case circuitRejectedInputs(detail: String)
    /// The circuit's WASM could not get the memory it needed while computing the witness.
    /// Retrying the same circuit on the same device may well fail again. Only this failure is
    /// reported here: if the whole process runs out of memory, the system terminates the
    /// app (or Rust aborts) and no error can be thrown.
    case outOfMemory(detail: String)
    /// Witness generation or proof generation failed for a reason other than the
    /// circuit rejecting the inputs or running out of memory (a circuit abort, a witness
    /// that does not fit the artifact, the Groth16 prover).
    case provingFailed(detail: String)
    /// A bug or a version mismatch inside Laniakea, or an error from the bindings
    /// that is none of the above. Never caused by the caller's inputs.
    case internalFailure(detail: String)

    // MARK: Exporting

    /// `Proof.write(to:)` could not write a file, or was given an unusable file name.
    case exportFailed(file: String, reason: String)
}

// MARK: - Mapping from the generated bindings

extension LaniakeaError {
    /// Wraps whatever the generated bindings threw. A `ProverError` is mapped
    /// case by case; anything else (for example a panic surfaced by UniFFI) is an
    /// internal failure.
    init(wrapping error: any Error) {
        switch error {
        case let error as LaniakeaError: self = error
        case let error as ProverError: self.init(error)
        default: self = .internalFailure(detail: String(describing: error))
        }
    }

    /// Exhaustive, with no `default`: a case added to the Rust `ProverError` fails to
    /// compile here until it is mapped on purpose.
    init(_ error: ProverError) {
        switch error {
        case .InvalidInputValue(let signal, let index, let value):
            self = .invalidInputValue(signal: signal, index: Int(index), value: value)
        case .UnknownSignal(let name):
            self = .unknownInput(name: name)
        case .DuplicateSignal(let name):
            self = .duplicateInput(name: name)
        case .InputSize(let signal, let expected, let got):
            self = .wrongInputCount(signal: signal, expected: Int(clamping: expected), got: Int(clamping: got))
        case .MissingInputs(let set, let expected):
            self = .missingInputs(provided: Int(clamping: set), expected: Int(clamping: expected))
        case .AssertionFailed(let detail):
            self = .circuitRejectedInputs(detail: detail)
        case .ResourceExhausted(let detail):
            self = .outOfMemory(detail: detail)
        case .CircuitAbort(let code, let reason, let detail):
            self = .provingFailed(detail: "circuit aborted: \(reason) (code \(code)): \(detail)")
        case .WitnessEngine(let detail):
            self = .provingFailed(detail: "witness engine: \(detail)")
        case .InvalidWitness(let detail):
            self = .provingFailed(detail: "invalid witness: \(detail)")
        case .ProofGeneration(let detail):
            self = .provingFailed(detail: "proof generation: \(detail)")
        case .ArtifactLoad(let detail):
            self = .invalidArtifact(detail: "loading: \(detail)")
        case .InvalidArtifact(let detail):
            self = .invalidArtifact(detail: detail)
        case .UnsupportedArtifactVersion(let found, let supported):
            self = .unsupportedArtifactVersion(found: Int(clamping: found), supported: Int(clamping: supported))
        case .InvalidCircuitModule(let detail):
            self = .invalidCircuit(detail: detail)
        case .UnsupportedField(let detail):
            self = .invalidCircuit(detail: "unsupported field: \(detail)")
        case .CircuitEngine(let detail):
            self = .invalidCircuit(detail: "circuit engine: \(detail)")
        case .Internal(let detail):
            self = .internalFailure(detail: detail)
        }
    }
}

// MARK: - Messages

extension LaniakeaError: LocalizedError {
    /// A short, generic sentence. Apps with their own wording should switch on the
    /// case instead; `debugDescription` carries the details.
    public var errorDescription: String? {
        switch self {
        case .fileUnreadable(let file, _):
            "The circuit file \(file) could not be read."
        case .invalidArtifact:
            "The proving artifact is damaged, incomplete or does not match the circuit."
        case .unsupportedArtifactVersion:
            "The proving artifact was made in a format this version of the SDK does not read."
        case .invalidCircuit:
            "The circuit WASM is not a usable BN254 Circom circuit."
        case .invalidInputValue(let signal, let index, _):
            "The value at position \(index) of input \(signal) must be a non-negative whole number below the field modulus."
        case .unknownInput(let name):
            "The circuit has no input named \(name)."
        case .duplicateInput(let name):
            "The input \(name) was provided more than once."
        case .wrongInputCount(let signal, let expected, let got):
            "The input \(signal) needs \(expected) value(s), but \(got) were provided."
        case .missingInputs(let provided, let expected):
            "Only \(provided) of the circuit's \(expected) input values were provided."
        case .circuitRejectedInputs:
            "The circuit rejected these inputs: one of its internal checks failed."
        case .outOfMemory:
            "The circuit ran out of memory while computing the witness."
        case .provingFailed:
            "The proof could not be generated."
        case .internalFailure:
            "An internal error occurred in the prover."
        case .exportFailed(let file, _):
            "The proof file \(file) could not be written."
        }
    }
}

extension LaniakeaError: CustomDebugStringConvertible {
    /// The case name and its payload, for logs and a "details" view. For people, not
    /// for parsing.
    public var debugDescription: String {
        switch self {
        case .fileUnreadable(let file, let reason): "fileUnreadable: \(file): \(reason)"
        case .invalidArtifact(let detail): "invalidArtifact: \(detail)"
        case .unsupportedArtifactVersion(let found, let supported): "unsupportedArtifactVersion: found \(found), supported \(supported)"
        case .invalidCircuit(let detail): "invalidCircuit: \(detail)"
        case .invalidInputValue(let signal, let index, let value): "invalidInputValue: \(signal)[\(index)] = \"\(value)\""
        case .unknownInput(let name): "unknownInput: \(name)"
        case .duplicateInput(let name): "duplicateInput: \(name)"
        case .wrongInputCount(let signal, let expected, let got): "wrongInputCount: \(signal) expected \(expected), got \(got)"
        case .missingInputs(let provided, let expected): "missingInputs: \(provided) of \(expected) provided"
        case .circuitRejectedInputs(let detail): "circuitRejectedInputs: \(detail)"
        case .outOfMemory(let detail): "outOfMemory: \(detail)"
        case .provingFailed(let detail): "provingFailed: \(detail)"
        case .internalFailure(let detail): "internalFailure: \(detail)"
        case .exportFailed(let file, let reason): "exportFailed: \(file): \(reason)"
        }
    }
}
