// User-facing text for the Rust prover's errors.
//
// The generated `ProverError.errorDescription` is only `String(reflecting:)`, and
// the Rust `#[error]` messages do not cross the FFI boundary, so the app writes its
// own. Both switches are exhaustive with no `default`: a case added to the Rust
// enum fails to compile here until it has been given a message on purpose.

import Laniakea

/// What kind of problem a `ProverError` is, for deciding what to tell the user.
nonisolated enum ProverErrorCategory: Equatable, Sendable {
    /// The app sent inputs the circuit does not accept by name, count or format.
    /// The UI validates first, so this means the app and circuit do not match.
    case appInput
    /// The circuit evaluated the inputs and rejected them (a failed assertion).
    case circuitRejected
    /// The bundled artifact or WASM could not be loaded, or they do not match.
    case bundledResources
    /// Witness generation or proving failed at run time.
    case proving
    /// A bug or version mismatch inside the prover.
    case `internal`
}

nonisolated extension ProverError {
    var category: ProverErrorCategory {
        switch self {
        case .InvalidInputValue, .UnknownSignal, .DuplicateSignal, .InputSize, .MissingInputs:
            .appInput
        case .AssertionFailed:
            .circuitRejected
        case .ArtifactLoad, .InvalidArtifact, .InvalidCircuitModule, .UnsupportedField, .CircuitEngine:
            .bundledResources
        case .ResourceExhausted, .CircuitAbort, .WitnessEngine, .InvalidWitness, .ProofGeneration:
            .proving
        case .Internal:
            .internal
        }
    }

    var userMessage: String {
        switch self {
        case .InvalidInputValue:
            "The prover rejected an input value: it must be a non-negative whole number."
        case .UnknownSignal(let name):
            "The app sent an input (\(name)) that this circuit does not have."
        case .DuplicateSignal(let name):
            "The app sent the input \(name) more than once."
        case .InputSize(let signal, let expected, let got):
            "The input \(signal) needs \(expected) value(s), but the app sent \(got)."
        case .MissingInputs:
            "The app did not provide all of the circuit's inputs."
        case .AssertionFailed:
            "The circuit rejected these inputs: one of its internal checks failed. Use an age from 0 to 255."
        case .ResourceExhausted:
            "The circuit ran out of memory while computing the witness."
        case .CircuitAbort(let code, _, _):
            "The circuit stopped with an unexpected error (Circom code \(code))."
        case .WitnessEngine:
            "The witness engine failed while running the circuit."
        case .ArtifactLoad:
            "The bundled proving artifact could not be read. It may be missing or damaged."
        case .InvalidArtifact:
            "The bundled proving artifact is inconsistent or does not match the circuit."
        case .InvalidCircuitModule:
            "The bundled circuit file (WASM) is not a usable Circom circuit."
        case .UnsupportedField:
            "The bundled circuit uses a field other than BN254, which this prover does not support."
        case .CircuitEngine:
            "The witness engine could not load the bundled circuit."
        case .InvalidWitness:
            "The computed witness does not fit the proving artifact."
        case .ProofGeneration:
            "The Groth16 prover failed to generate a proof."
        case .Internal:
            "An internal error occurred in the prover."
        }
    }

    /// The case name and its payload, for the details section. Diagnostic text from
    /// Rust is for people, not for parsing.
    var debugDetail: String {
        switch self {
        case .InvalidInputValue(let signal, let index, let value):
            "InvalidInputValue: \(signal)[\(index)] = \"\(value)\""
        case .UnknownSignal(let name):
            "UnknownSignal: \(name)"
        case .DuplicateSignal(let name):
            "DuplicateSignal: \(name)"
        case .InputSize(let signal, let expected, let got):
            "InputSize: \(signal) expected \(expected), got \(got)"
        case .MissingInputs(let set, let expected):
            "MissingInputs: \(set) of \(expected) set"
        case .AssertionFailed(let detail):
            "AssertionFailed: \(detail)"
        case .ResourceExhausted(let detail):
            "ResourceExhausted: \(detail)"
        case .CircuitAbort(let code, let reason, let detail):
            "CircuitAbort: \(reason) (code \(code)): \(detail)"
        case .WitnessEngine(let detail):
            "WitnessEngine: \(detail)"
        case .ArtifactLoad(let detail):
            "ArtifactLoad: \(detail)"
        case .InvalidArtifact(let detail):
            "InvalidArtifact: \(detail)"
        case .InvalidCircuitModule(let detail):
            "InvalidCircuitModule: \(detail)"
        case .UnsupportedField(let detail):
            "UnsupportedField: \(detail)"
        case .CircuitEngine(let detail):
            "CircuitEngine: \(detail)"
        case .InvalidWitness(let detail):
            "InvalidWitness: \(detail)"
        case .ProofGeneration(let detail):
            "ProofGeneration: \(detail)"
        case .Internal(let detail):
            "Internal: \(detail)"
        }
    }
}
