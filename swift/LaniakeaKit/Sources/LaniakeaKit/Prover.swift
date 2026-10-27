import Foundation
import Laniakea

/// Generates Groth16 proofs for one Circom circuit, on the device, with Wasmi
/// executing the circuit's WASM. The SDK itself makes no network calls: what happens to
/// a proof, and to anything derived from the inputs, once `prove` returns is up to the
/// integrating app.
///
/// ```swift
/// let circuit = try Circuit(name: "age_check")            // age_check.artifact + .wasm in the bundle
/// let prover = try await Prover(circuit: circuit)
/// let proof = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])
/// proof.publicSignals                                      // ["1", "18"]
/// try proof.write(to: directory)                           // proof.json + public.json
/// ```
///
/// **Concurrency contract.**
/// - `Prover` is an actor. Actor isolation by itself does not give a dedicated thread:
///   its work runs on a thread of Swift's cooperative pool, and never on the main thread
///   (the caller just `await`s, so the main actor stays free).
/// - Building a prover (validating the artifact, compiling the WASM) and proving are
///   synchronous, CPU-bound Rust calls that cannot yield. While one runs it occupies a
///   cooperative-pool thread until it finishes, and other Swift-concurrency work
///   competes for the remaining threads.
/// - Calls on one `Prover` are serialized (their relative order is not guaranteed). Queued calls hold no thread.
/// - Different `Prover`s can run at the same time, which adds CPU, memory and
///   scheduling pressure. Do not launch large numbers of concurrent proofs; keep them
///   well below the device's core count.
/// - Cancellation is checked once, when the actor starts handling a `prove` call: a task
///   cancelled before that gets `CancellationError`, including a call that was queued
///   behind another. A proof that is already executing cannot be interrupted; it runs
///   to completion and returns its result even if the task has been cancelled meanwhile.
/// - No `@unchecked Sendable` is used: the generated UniFFI class is not `Sendable`, so
///   the actor owns it and it never leaves. (The Rust object itself is `Send + Sync`, but
///   nothing here depends on that.)
///
/// **Memory.** A prover keeps the proving key and constraint matrices in memory for its
/// lifetime; build it once and reuse it, release it when the circuit is not needed.
public actor Prover {
    /// How many public signals a proof from this circuit carries. Use it to check that
    /// the circuit you loaded is the one you expect.
    public nonisolated let publicSignalCount: Int

    private let engine: LaniakeaProver

    /// Validates the artifact and compiles the circuit's WASM.
    ///
    /// - Throws: `LaniakeaError.invalidArtifact` or `.invalidCircuit` if the files are not
    ///   usable.
    public init(circuit: Circuit) async throws {
        do {
            engine = try LaniakeaProver(artifactBytes: circuit.artifact, wasmBytes: circuit.wasm)
        } catch {
            throw LaniakeaError(wrapping: error)
        }
        publicSignalCount = Int(engine.numPublicSignals())
    }

    /// Generates a proof for `inputs`, keyed by the circuit's input signal names.
    ///
    /// A proof that was generated is **not verified**, and it does not mean the
    /// application condition holds; see `Proof`.
    ///
    /// - Throws: `LaniakeaError` (`.invalidInputValue`, `.unknownInput`,
    ///   `.missingInputs`, `.circuitRejectedInputs`, ...), or `CancellationError` if the
    ///   task was already cancelled. A failed call leaves the prover usable.
    public func prove(_ inputs: [String: Input]) async throws -> Proof {
        try Task.checkCancellation()
        let result: ProofResult
        do {
            result = try engine.prove(inputs: Input.ffiInputs(inputs))
        } catch {
            throw LaniakeaError(wrapping: error)
        }
        return Proof(proofJSON: result.proofJson, publicSignals: result.publicSignals)
    }

    #if LANIAKEA_TESTING
    /// Test seam, not API (compiled only with `-D LANIAKEA_TESTING`, which only
    /// scripts/swift-sdk-test.sh sets): occupies the actor like a running proof does, so
    /// that a test can issue other calls while it is busy. Signals `started` once it
    /// holds the actor and returns after `release` is signalled.
    func occupyForTesting(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal()
        release.wait()
    }
    #endif
}
