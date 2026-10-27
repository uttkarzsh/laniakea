// User-facing text for the SDK's errors. (The file keeps its old name: it is
// referenced by the Xcode project. It now extends `LaniakeaError`.)
//
// `LaniakeaError` has generic `errorDescription`s of its own; this app writes its
// own, in the voice of the demo ("the bundled file", "use an age from 0 to 255").
// The switches are exhaustive with no `default`: a case added to the SDK's enum fails
// to compile here until it has been given a message on purpose.

import LaniakeaKit

/// What kind of problem a `LaniakeaError` is, for deciding what to tell the user.
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
    /// A bug or version mismatch inside the prover, or something the demo never does.
    case `internal`
}

nonisolated extension LaniakeaError {
    var category: ProverErrorCategory {
        switch self {
        case .invalidInputValue, .unknownInput, .duplicateInput, .wrongInputCount, .missingInputs:
            .appInput
        case .circuitRejectedInputs:
            .circuitRejected
        case .fileUnreadable, .invalidArtifact, .invalidCircuit:
            .bundledResources
        case .outOfMemory, .provingFailed:
            .proving
        case .internalFailure, .exportFailed:
            .internal
        }
    }

    var userMessage: String {
        switch self {
        case .fileUnreadable(let file, _):
            "The bundled file \(file) is missing or unreadable. Rebuild the app with its resources."
        case .invalidArtifact:
            "The bundled proving artifact is damaged, inconsistent or does not match the circuit."
        case .invalidCircuit:
            "The bundled circuit file (WASM) is not a usable BN254 Circom circuit."
        case .invalidInputValue:
            "The prover rejected an input value: it must be a non-negative whole number."
        case .unknownInput(let name):
            "The app sent an input (\(name)) that this circuit does not have."
        case .duplicateInput(let name):
            "The app sent the input \(name) more than once."
        case .wrongInputCount(let signal, let expected, let got):
            "The input \(signal) needs \(expected) value(s), but the app sent \(got)."
        case .missingInputs:
            "The app did not provide all of the circuit's inputs."
        case .circuitRejectedInputs:
            "The circuit rejected these inputs: one of its internal checks failed. Use an age from 0 to 255."
        case .outOfMemory:
            "The circuit ran out of memory while computing the witness."
        case .provingFailed:
            "The prover failed while computing the witness or generating the proof."
        case .internalFailure:
            "An internal error occurred in the prover."
        case .exportFailed:
            "A proof file could not be written."
        }
    }
}
