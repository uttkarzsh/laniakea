// Phase 6b smoke test. Calls the Rust prover through the generated UniFFI
// bindings. Synchronous on purpose: this validates the FFI boundary itself,
// independent of Swift concurrency.
//
// Usage: smoke <artifact> <wasm> <out-dir>   (writes proof.json and public.json)

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   " : "  FAIL ", what)
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: smoke <artifact> <wasm> <out-dir>")
    exit(64)
}
let artifact = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let wasm = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let outDir = args[3]

func age(_ a: String, _ t: String) -> [CircuitInput] {
    [CircuitInput(name: "age", values: [a]), CircuitInput(name: "threshold", values: [t])]
}

print("construct + prove")
let prover = try LaniakeaProver(artifactBytes: artifact, wasmBytes: wasm)
check(prover.numPublicSignals() == 2, "numPublicSignals == 2")

let result = try prover.prove(inputs: age("25", "18"))
check(result.publicSignals == ["1", "18"], "publicSignals == [\"1\", \"18\"]  (got \(result.publicSignals))")
// Structural check: parse the JSON, do not match its exact spelling.
do {
    let parsed = try JSONSerialization.jsonObject(with: Data(result.proofJson.utf8))
    guard let proof = parsed as? [String: Any] else {
        check(false, "proofJson is a JSON object")
        throw NSError(domain: "smoke", code: 1)
    }
    check(proof["protocol"] as? String == "groth16", "proofJson.protocol == \"groth16\" (got \(String(describing: proof["protocol"])))")
    check(proof["curve"] as? String == "bn128", "proofJson.curve == \"bn128\"")
    for key in ["pi_a", "pi_b", "pi_c"] {
        check((proof[key] as? [Any])?.isEmpty == false, "proofJson.\(key) is a non-empty array")
    }
} catch {
    check(false, "proofJson is valid JSON: \(error)")
}

let publicJson = String(data: try JSONSerialization.data(withJSONObject: result.publicSignals), encoding: .utf8)!
try result.proofJson.write(toFile: outDir + "/proof.json", atomically: true, encoding: .utf8)
try publicJson.write(toFile: outDir + "/public.json", atomically: true, encoding: .utf8)

// A valid proof with out = 0 is still a valid proof: callers must read signal 0.
let negative = try prover.prove(inputs: age("10", "18"))
check(negative.publicSignals == ["0", "18"], "age < threshold still proves, with out == \"0\"")

// Typed errors. Every case is matched by enum case and payload, never by text.
print("typed errors")

func expectError(_ name: String, _ body: () throws -> Void, _ matches: (ProverError) -> Bool) {
    do {
        try body()
        check(false, "\(name): expected an error, got success")
    } catch let e as ProverError {
        check(matches(e), "\(name): \(e)")
    } catch {
        check(false, "\(name): not a ProverError: \(error)")
    }
}

expectError("malformed decimal", { _ = try prover.prove(inputs: age("-1", "18")) }) {
    if case .InvalidInputValue(let signal, let index, let value) = $0 {
        return signal == "age" && index == 0 && value == "-1"
    }
    return false
}
expectError("value equal to the field modulus", {
    _ = try prover.prove(inputs: age("21888242871839275222246405745257275088548364400416034343698204186575808495617", "18"))
}) {
    if case .InvalidInputValue(let signal, _, _) = $0 { return signal == "age" }
    return false
}
expectError("missing input", { _ = try prover.prove(inputs: [CircuitInput(name: "age", values: ["25"])]) }) {
    if case .MissingInputs(let set, let expected) = $0 { return set == 1 && expected == 2 }
    return false
}
expectError("unknown signal", { _ = try prover.prove(inputs: age("25", "18") + [CircuitInput(name: "nope", values: ["1"])]) }) {
    if case .UnknownSignal(let name) = $0 { return name == "nope" }
    return false
}
expectError("circuit assertion (age does not fit in 8 bits)", { _ = try prover.prove(inputs: age("300", "18")) }) {
    if case .AssertionFailed = $0 { return true }
    return false
}
expectError("invalid circuit module", { _ = try LaniakeaProver(artifactBytes: artifact, wasmBytes: Data([1, 2, 3])) }) {
    if case .InvalidCircuitModule = $0 { return true }
    return false
}
expectError("invalid artifact (empty)", { _ = try LaniakeaProver(artifactBytes: Data(), wasmBytes: wasm) }) {
    if case .ArtifactLoad = $0 { return true }
    return false
}
expectError("invalid artifact (truncated)", { _ = try LaniakeaProver(artifactBytes: artifact.prefix(artifact.count / 2), wasmBytes: wasm) }) {
    if case .ArtifactLoad = $0 { return true }
    return false
}

print("recovery")
let again = try prover.prove(inputs: age("25", "18"))
check(again.publicSignals == ["1", "18"], "prover still works after the failures above")

print(failures == 0 ? "SWIFT SMOKE TEST: PASSED" : "SWIFT SMOKE TEST: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
