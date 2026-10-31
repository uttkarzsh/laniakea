// Host tests for the LaniakeaKit Swift layer (Circuit, Prover, Verifier, Proof, Input,
// LaniakeaError), run on macOS by scripts/swift-sdk-test.sh. The layer is built as
// the module `LaniakeaKit` with testing enabled, on top of the generated bindings
// built as module `Laniakea`, as the Swift package arranges them. XCTest is not
// used; failures are counted and reported through the exit code.
//
// Usage: SDKTests <resources-dir> <out-dir> <other-circuit.wasm> <verification_key.json> <snarkjs-fixtures-dir>
//   reads  <resources-dir>/age_check.artifact and age_check.wasm (the demo's copies),
//          age_check's verification_key.json, and a proof made by snarkjs
//          (<fixtures>/age_check_snarkjs_{proof,public}.json)
//   writes <out-dir>/{eligible,ineligible}.{proof,public}.json for snarkjs, through
//          Proof.write, so the exported files are what an independent verifier checks.

import Foundation
import _LaniakeaBindings
@testable import LaniakeaKit

@MainActor var failures = 0

@MainActor
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   " : "  FAIL ", what)
    if !ok { failures += 1 }
}

/// Runs `body`, expecting it to throw a `LaniakeaError` for which `matches` holds.
@MainActor
func expectError(_ name: String, _ body: () async throws -> Void, _ matches: (LaniakeaError) -> Bool) async {
    do {
        try await body()
        check(false, "\(name): expected an error, got success")
    } catch let error as LaniakeaError {
        check(matches(error), "\(name): \(error.debugDescription)")
    } catch {
        check(false, "\(name): not a LaniakeaError: \(error)")
    }
}

@MainActor
func expectVerificationError(_ name: String, _ body: () async throws -> Void, _ matches: (VerificationError) -> Bool) async {
    do {
        try await body()
        check(false, "\(name): expected an error, got success")
    } catch let error as VerificationError {
        check(matches(error), "\(name): \(error.debugDescription)")
    } catch {
        check(false, "\(name): not a VerificationError: \(error)")
    }
}

let fieldModulus = "21888242871839275222246405745257275088548364400416034343698204186575808495617"

/// Every ProverError case, with the LaniakeaError it must map to.
let mappings: [(ProverError, LaniakeaError)] = [
    (.InvalidInputValue(signal: "age", index: 2, value: "x"), .invalidInputValue(signal: "age", index: 2, value: "x")),
    (.UnknownSignal(name: "nope"), .unknownInput(name: "nope")),
    (.DuplicateSignal(name: "age"), .duplicateInput(name: "age")),
    (.InputSize(signal: "v", expected: 3, got: 2), .wrongInputCount(signal: "v", expected: 3, got: 2)),
    (.MissingInputs(set: 1, expected: 2), .missingInputs(provided: 1, expected: 2)),
    (.AssertionFailed(detail: "d"), .circuitRejectedInputs(detail: "d")),
    (.ResourceExhausted(detail: "d"), .outOfMemory(detail: "d")),
    (.CircuitAbort(code: 7, reason: "r", detail: "d"), .provingFailed(detail: "circuit aborted: r (code 7): d")),
    (.WitnessEngine(detail: "d"), .provingFailed(detail: "witness engine: d")),
    (.ArtifactLoad(detail: "d"), .invalidArtifact(detail: "loading: d")),
    (.InvalidArtifact(detail: "d"), .invalidArtifact(detail: "d")),
    (.UnsupportedArtifactVersion(found: 2, supported: 1), .unsupportedArtifactVersion(found: 2, supported: 1)),
    (.InvalidCircuitModule(detail: "d"), .invalidCircuit(detail: "d")),
    (.UnsupportedField(detail: "d"), .invalidCircuit(detail: "unsupported field: d")),
    (.CircuitEngine(detail: "d"), .invalidCircuit(detail: "circuit engine: d")),
    (.InvalidWitness(detail: "d"), .provingFailed(detail: "invalid witness: d")),
    (.ProofGeneration(detail: "d"), .provingFailed(detail: "proof generation: d")),
    (.Internal(detail: "d"), .internalFailure(detail: "d")),
]

/// Exhaustive: fails to compile if ProverError gains a case this file does not list.
func caseName(_ e: ProverError) -> String {
    switch e {
    case .InvalidInputValue: "InvalidInputValue"
    case .UnknownSignal: "UnknownSignal"
    case .DuplicateSignal: "DuplicateSignal"
    case .InputSize: "InputSize"
    case .MissingInputs: "MissingInputs"
    case .AssertionFailed: "AssertionFailed"
    case .ResourceExhausted: "ResourceExhausted"
    case .CircuitAbort: "CircuitAbort"
    case .WitnessEngine: "WitnessEngine"
    case .ArtifactLoad: "ArtifactLoad"
    case .InvalidArtifact: "InvalidArtifact"
    case .UnsupportedArtifactVersion: "UnsupportedArtifactVersion"
    case .InvalidCircuitModule: "InvalidCircuitModule"
    case .UnsupportedField: "UnsupportedField"
    case .CircuitEngine: "CircuitEngine"
    case .InvalidWitness: "InvalidWitness"
    case .ProofGeneration: "ProofGeneration"
    case .Internal: "Internal"
    }
}

func proofObject(_ json: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
}

@main
@MainActor
struct SDKTests {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else {
            print("usage: SDKTests <resources-dir> <out-dir> <other-circuit.wasm> <verification_key.json> <snarkjs-fixtures-dir>")
            exit(64)
        }
        let resources = URL(fileURLWithPath: args[1])
        let out = URL(fileURLWithPath: args[2])
        let otherWasm = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        let verificationKey = URL(fileURLWithPath: args[4])
        let fixtures = URL(fileURLWithPath: args[5])
        let artifactURL = resources.appendingPathComponent("age_check.artifact")
        let wasmURL = resources.appendingPathComponent("age_check.wasm")

        inputConversionTests()
        errorMappingTests()
        let circuit = try await circuitTests(resources, artifactURL, wasmURL)
        let prover = try await Prover(circuit: circuit)
        try await proofTests(prover, out)
        await proofErrorTests(prover)
        try await verifierTests(prover, verificationKey, fixtures)
        await badCircuitTests(circuit, otherWasm: otherWasm)
        await concurrencyTests(circuit, prover)
        await mainThreadTests(circuit, prover)
        try exportTests(out)

        print(failures == 0 ? "SDK TESTS: PASSED" : "SDK TESTS: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: input conversion

    static func inputConversionTests() {
        print("input conversion")
        check(Input.integer(25).values == ["25"], ".integer(25) -> [\"25\"]")
        check(Input.integer(0).values == ["0"], ".integer(0) -> [\"0\"]")
        check(Input.integer(Int.max).values == [String(Int.max)], ".integer(Int.max) is exact")
        check(Input.integer(-1).values == ["-1"], ".integer(-1) is passed on unchanged (the prover rejects it)")
        check(Input.decimal(fieldModulus).values == [fieldModulus], ".decimal keeps the text as is, whatever it is")
        check(Input.decimal("018").values == ["018"], ".decimal does not normalise (the prover rejects it)")
        check(Input.integers([1, 2, 3]).values == ["1", "2", "3"], ".integers([1, 2, 3])")
        check(Input.decimals(["7", "8"]).values == ["7", "8"], ".decimals([\"7\", \"8\"])")
        check(Input.integers([]).values.isEmpty, ".integers([]) is an empty array signal")

        let ffi = Input.ffiInputs(["threshold": .integer(18), "age": .integer(25), "v": .integers([4, 5])])
        check(ffi.map(\.name) == ["age", "threshold", "v"], "inputs are sent in name order (got \(ffi.map(\.name)))")
        check(ffi.map(\.values) == [["25"], ["18"], ["4", "5"]], "values follow their names (got \(ffi.map(\.values)))")
        check(Input.ffiInputs([:]).isEmpty, "no inputs -> no FFI inputs")
        check(Input.integer(3) == Input.decimal("3"), "equal values compare equal")
    }

    // MARK: error mapping

    static func errorMappingTests() {
        print("error mapping")
        check(mappings.count == 18, "all 18 ProverError cases are listed")
        check(Set(mappings.map { caseName($0.0) }).count == 18, "the listed cases are distinct")
        for (source, expected) in mappings {
            let mapped = LaniakeaError(source)
            check(mapped == expected, "\(caseName(source)) -> \(mapped.debugDescription)")
            check(LaniakeaError(wrapping: source) == expected, "\(caseName(source)): wrapping(any Error) maps the same way")
        }
        check(LaniakeaError(wrapping: LaniakeaError.unknownInput(name: "a")) == .unknownInput(name: "a"),
              "a LaniakeaError is passed through unchanged")
        struct Foreign: Error {}
        if case .internalFailure(let detail) = LaniakeaError(wrapping: Foreign()) {
            check(detail.contains("Foreign"), "an unrelated error becomes internalFailure (\(detail))")
        } else {
            check(false, "an unrelated error becomes internalFailure")
        }
        check(LaniakeaError(.InputSize(signal: "v", expected: .max, got: .max)) == .wrongInputCount(signal: "v", expected: Int.max, got: Int.max),
              "UInt64 counts above Int.max saturate instead of trapping")

        let all: [LaniakeaError] = mappings.map(\.1) + [
            .fileUnreadable(file: "a.wasm", reason: "gone"), .exportFailed(file: "proof.json", reason: "full"),
        ]
        var descriptions = Set<String>()
        for error in all {
            let text = error.errorDescription ?? ""
            check(!text.isEmpty && text.hasSuffix(".") && !text.contains("ProverError"), "message: \(text)")
            check(error.localizedDescription == text, "\(error): localizedDescription is errorDescription")
            check(!error.debugDescription.isEmpty, "debugDescription of \(error)")
            descriptions.insert(text)
        }
        // Categories share a generic sentence only where the cases carry no payload to show.
        check(Set(all.map { $0.debugDescription }).count == all.count, "every case (and payload) has its own debugDescription")
        check(descriptions.count >= 12, "the generic messages tell the categories apart (\(descriptions.count) distinct)")
        check(LaniakeaError.outOfMemory(detail: "x").errorDescription == "The circuit ran out of memory while computing the witness.",
              "outOfMemory has its own localized description")
        check(LaniakeaError(.ResourceExhausted(detail: "memory.grow failed")) == .outOfMemory(detail: "memory.grow failed"),
              "ResourceExhausted is outOfMemory, not provingFailed, with the detail kept")
        let sample = LaniakeaError.invalidInputValue(signal: "age", index: 0, value: "-1")
        check(sample.debugDescription == "invalidInputValue: age[0] = \"-1\"", "debugDescription names the case and the value")
        check((sample as any Error) is any LocalizedError, "LaniakeaError conforms to LocalizedError")
    }

    // MARK: circuit loading

    static func circuitTests(_ resources: URL, _ artifactURL: URL, _ wasmURL: URL) async throws -> Circuit {
        print("circuit loading")
        let circuit = try Circuit(artifactURL: artifactURL, wasmURL: wasmURL)
        let artifactBytes = try Data(contentsOf: artifactURL)
        let wasmBytes = try Data(contentsOf: wasmURL)
        check(circuit.artifact == artifactBytes && circuit.wasm == wasmBytes, "Circuit(artifactURL:wasmURL:) holds both files' bytes")
        let fromData = Circuit(artifact: artifactBytes, wasm: wasmBytes)
        check(fromData.artifact == artifactBytes && fromData.wasm == wasmBytes, "Circuit(artifact:wasm:) holds the bytes it is given")

        // A directory is a (flat) bundle: the same lookup the app does in Bundle.main.
        if let bundle = Bundle(path: resources.path) {
            let fromBundle = try Circuit(name: "age_check", bundle: bundle)
            check(fromBundle.artifact == artifactBytes && fromBundle.wasm == wasmBytes, "Circuit(name:bundle:) finds <name>.artifact and <name>.wasm")
            await expectError("a bundle without the resource", {
                _ = try Circuit(name: "nope", bundle: bundle)
            }) {
                if case .fileUnreadable(let file, _) = $0 { return file == "nope.artifact" }
                return false
            }
        } else {
            check(false, "could not open \(resources.path) as a bundle")
        }

        let missing = resources.appendingPathComponent("missing.wasm")
        await expectError("a missing WASM file", {
            _ = try Circuit(artifactURL: artifactURL, wasmURL: missing)
        }) {
            if case .fileUnreadable(let file, let reason) = $0 { return file == missing.path && !reason.isEmpty }
            return false
        }
        await expectError("a missing artifact file", {
            _ = try Circuit(artifactURL: missing, wasmURL: wasmURL)
        }) {
            if case .fileUnreadable(let file, _) = $0 { return file == missing.path }
            return false
        }
        await expectError("a directory instead of a file", {
            _ = try Circuit(artifactURL: resources, wasmURL: wasmURL)
        }) {
            if case .fileUnreadable = $0 { return true }
            return false
        }
        return circuit
    }

    // MARK: verifying

    static func verifierTests(_ prover: Prover, _ keyURL: URL, _ fixtures: URL) async throws {
        print("verifying")
        // VerifierError -> LaniakeaError, every case.
        let verifierMappings: [(VerifierError, VerificationError)] = [
            (.InvalidVerificationKey(detail: "k"), .invalidVerificationKey(detail: "k")),
            (.InvalidProof(detail: "p"), .invalidProof(detail: "p")),
            (.InvalidPublicSignals(detail: "s"), .invalidPublicSignals(detail: "s")),
            (.Internal(detail: "i"), .internalFailure(detail: "i")),
        ]
        for (source, expected) in verifierMappings {
            check(VerificationError(wrapping: source) == expected, "\(source) -> \(expected.debugDescription)")
        }
        let verificationErrors: [VerificationError] = verifierMappings.map(\.1) + [.keyUnreadable(file: "k.json", reason: "gone")]
        for error in verificationErrors {
            let text = error.errorDescription ?? ""
            check(!text.isEmpty && text.hasSuffix(".") && error.localizedDescription == text, "message: \(text)")
        }
        check(Set(verificationErrors.map(\.debugDescription)).count == verificationErrors.count, "every VerificationError has its own debugDescription")

        let verifier = try Verifier(verificationKeyAt: keyURL)
        check(verifier.publicSignalCount == 2, "Verifier.publicSignalCount == 2")
        let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        let fromText = try Verifier(verificationKeyJSON: keyText)

        let eligible = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        let ineligible = try await prover.prove(["age": .integer(10), "threshold": .integer(18)])
        check(try await verifier.verify(eligible), "a fresh proof (out = 1) verifies")
        check(try await verifier.verify(ineligible), "a fresh proof with out = 0 also verifies: validity is not the condition")
        check(try await fromText.verify(eligible), "Verifier(verificationKeyJSON:) verifies the same proof")
        check(try await !verifier.verify(proofJSON: eligible.proofJSON, publicSignals: ["0", "18"]), "changed public signals -> false")
        check(try await !verifier.verify(proofJSON: ineligible.proofJSON, publicSignals: eligible.publicSignals), "a proof with another proof's signals -> false")

        let snarkjsProof = try String(contentsOf: fixtures.appendingPathComponent("age_check_snarkjs_proof.json"), encoding: .utf8)
        let snarkjsSignals = try JSONDecoder().decode([String].self, from: Data(contentsOf: fixtures.appendingPathComponent("age_check_snarkjs_public.json")))
        check(try await verifier.verify(proofJSON: snarkjsProof, publicSignals: snarkjsSignals), "a proof made by snarkjs verifies")

        await expectVerificationError("a proof that is not JSON", { _ = try await verifier.verify(proofJSON: "nope", publicSignals: ["1", "18"]) }) {
            if case .invalidProof = $0 { return true }
            return false
        }
        await expectVerificationError("too few public signals", { _ = try await verifier.verify(proofJSON: eligible.proofJSON, publicSignals: ["1"]) }) {
            if case .invalidPublicSignals = $0 { return true }
            return false
        }
        await expectVerificationError("a public signal equal to the field modulus", {
            _ = try await verifier.verify(proofJSON: eligible.proofJSON, publicSignals: ["1", fieldModulus])
        }) {
            if case .invalidPublicSignals = $0 { return true }
            return false
        }
        await expectVerificationError("a key that is not JSON", { _ = try Verifier(verificationKeyJSON: "{") }) {
            if case .invalidVerificationKey = $0 { return true }
            return false
        }
        await expectVerificationError("a key for another protocol", {
            _ = try Verifier(verificationKeyJSON: keyText.replacingOccurrences(of: "\"groth16\"", with: "\"plonk\""))
        }) {
            if case .invalidVerificationKey = $0 { return true }
            return false
        }
        let missing = keyURL.deletingLastPathComponent().appendingPathComponent("missing_key.json")
        await expectVerificationError("a missing key file", { _ = try Verifier(verificationKeyAt: missing) }) {
            if case .keyUnreadable(let file, _) = $0 { return file == missing.path }
            return false
        }
    }

    // MARK: proving and the proof

    static func proofTests(_ prover: Prover, _ out: URL) async throws {
        print("proving")
        check(prover.publicSignalCount == 2, "publicSignalCount == 2 (age_check: [out, threshold])")

        let eligible = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        check(eligible.publicSignals == ["1", "18"], "age 25: publicSignals == [\"1\", \"18\"] (got \(eligible.publicSignals))")
        check(eligible.publicSignalsJSON == "[\"1\",\"18\"]", "age 25: publicSignalsJSON == [\"1\",\"18\"] (got \(eligible.publicSignalsJSON))")
        guard let object = proofObject(eligible.proofJSON) else {
            check(false, "proofJSON is a JSON object")
            return
        }
        check(object["protocol"] as? String == "groth16" && object["curve"] as? String == "bn128", "proofJSON: protocol groth16, curve bn128")
        for key in ["pi_a", "pi_b", "pi_c"] {
            check((object[key] as? [Any])?.count == 3, "proofJSON.\(key) has 3 entries")
        }

        // A proof for a false statement is still a proof: read the public signals.
        let ineligible = try await prover.prove(["threshold": .decimal("18"), "age": .decimal("10")])
        check(ineligible.publicSignals == ["0", "18"], "age 10: publicSignals == [\"0\", \"18\"] (got \(ineligible.publicSignals))")
        check(ineligible != eligible, "different inputs give different proofs")
        let boundary = try await prover.prove(["age": .integer(18), "threshold": .integer(18)])
        check(boundary.publicSignals == ["1", "18"], "age 18 (boundary) -> out 1")

        // The exported files are what snarkjs verifies in scripts/swift-sdk-test.sh.
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, proof) in [("eligible", eligible), ("ineligible", ineligible)] {
            try proof.write(to: out, proofFileName: "\(name).proof.json", publicSignalsFileName: "\(name).public.json")
        }
    }

    static func proofErrorTests(_ prover: Prover) async {
        print("proving errors (the real prover)")
        await expectError("a missing input", {
            _ = try await prover.prove(["age": .integer(25)])
        }) {
            if case .missingInputs(let provided, let expected) = $0 { return provided < expected }
            return false
        }
        await expectError("no inputs at all", { _ = try await prover.prove([:]) }) {
            if case .missingInputs = $0 { return true }
            return false
        }
        await expectError("an unknown input", {
            _ = try await prover.prove(["age": .integer(25), "threshold": .integer(18), "nope": .integer(1)])
        }) { $0 == .unknownInput(name: "nope") }
        await expectError("two values for a scalar signal", {
            _ = try await prover.prove(["age": .integers([25, 26]), "threshold": .integer(18)])
        }) { $0 == .wrongInputCount(signal: "age", expected: 1, got: 2) }
        await expectError("zero values for a scalar signal", {
            _ = try await prover.prove(["age": .integers([]), "threshold": .integer(18)])
        }) {
            if case .wrongInputCount(let signal, _, 0) = $0 { return signal == "age" }
            return false
        }

        // Canonical-decimal validation is the prover's, with the detail preserved.
        let bad: [(String, Input, String)] = [
            ("a negative integer", .integer(-1), "-1"),
            ("a negative decimal", .decimal("-5"), "-5"),
            ("leading zeros", .decimal("018"), "018"),
            ("a plus sign", .decimal("+18"), "+18"),
            ("not a number", .decimal("abc"), "abc"),
            ("a fraction", .decimal("1.5"), "1.5"),
            ("hexadecimal", .decimal("0x12"), "0x12"),
            ("whitespace", .decimal(" 18"), " 18"),
            ("empty text", .decimal(""), ""),
        ]
        for (what, input, text) in bad {
            await expectError(what, {
                _ = try await prover.prove(["age": input, "threshold": .integer(18)])
            }) { $0 == .invalidInputValue(signal: "age", index: 0, value: text) }
        }
        await expectError("the field modulus itself (long values are truncated in the diagnostic)", {
            _ = try await prover.prove(["age": .decimal(fieldModulus), "threshold": .integer(18)])
        }) {
            if case .invalidInputValue("age", 0, let value) = $0 { return value.hasPrefix(String(fieldModulus.prefix(20))) }
            return false
        }
        await expectError("a bad value at a later position names the position", {
            _ = try await prover.prove(["age": .decimals(["25", "x"]), "threshold": .integer(18)])
        }) {
            if case .invalidInputValue("age", 1, "x") = $0 { return true }
            return false
        }
        let long = String(repeating: "9", count: 500)
        await expectError("a very long number", {
            _ = try await prover.prove(["age": .decimal(long), "threshold": .integer(18)])
        }) {
            if case .invalidInputValue("age", 0, let value) = $0 { return value.count < long.count }
            return false
        }
        // p - 1 is a valid field element; the circuit decides what it means.
        let pMinus1 = "21888242871839275222246405745257275088548364400416034343698204186575808495616"
        let negative = try? await prover.prove(["age": .decimal(pMinus1), "threshold": .integer(18)])
        check(negative?.publicSignals == ["0", "18"], "p - 1 passes input validation and proves with out = 0 (the circuit does not range-check)")

        await expectError("the circuit rejecting its inputs (age 274, threshold 18)", {
            _ = try await prover.prove(["age": .integer(274), "threshold": .integer(18)])
        }) {
            if case .circuitRejectedInputs = $0 { return true }
            return false
        }

        let after = try? await prover.prove(["age": .integer(30), "threshold": .integer(18)])
        check(after?.publicSignals == ["1", "18"], "the prover still works after all of those failures")
    }

    static func badCircuitTests(_ good: Circuit, otherWasm: Data) async {
        print("bad circuits")
        await expectError("an empty artifact", {
            _ = try await Prover(circuit: Circuit(artifact: Data(), wasm: good.wasm))
        }) {
            if case .invalidArtifact = $0 { return true }
            return false
        }
        await expectError("a truncated artifact", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact.prefix(good.artifact.count / 2), wasm: good.wasm))
        }) {
            if case .invalidArtifact = $0 { return true }
            return false
        }
        // The artifact file format: header, version, declared length.
        await expectError("an artifact of an unsupported format version", {
            var newer = good.artifact
            newer.replaceSubrange(8..<10, with: [2, 0])
            _ = try await Prover(circuit: Circuit(artifact: newer, wasm: good.wasm))
        }) {
            if case .unsupportedArtifactVersion(found: 2, supported: 1) = $0 { return true }
            return false
        }
        await expectError("a legacy artifact without the header", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact.dropFirst(18), wasm: good.wasm))
        }) {
            if case .invalidArtifact(let detail) = $0 { return detail.contains("re-export") }
            return false
        }
        await expectError("an artifact with trailing bytes", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact + Data([0]), wasm: good.wasm))
        }) {
            if case .invalidArtifact(let detail) = $0 { return detail.contains("trailing") }
            return false
        }
        await expectError("an artifact error is reported before the WASM is loaded", {
            _ = try await Prover(circuit: Circuit(artifact: Data([1, 2, 3]), wasm: Data([0, 1, 2, 3])))
        }) {
            if case .invalidArtifact = $0 { return true }
            return false
        }
        await expectError("invalid WASM", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact, wasm: Data([0, 1, 2, 3])))
        }) {
            if case .invalidCircuit = $0 { return true }
            return false
        }
        await expectError("empty WASM", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact, wasm: Data()))
        }) {
            if case .invalidCircuit = $0 { return true }
            return false
        }
        await expectError("the two files swapped", {
            _ = try await Prover(circuit: Circuit(artifact: good.wasm, wasm: good.artifact))
        }) {
            switch $0 {
            case .invalidArtifact, .invalidCircuit: true
            default: false
            }
        }
        // A well-formed WASM from a different circuit: the wire counts disagree.
        await expectError("an artifact paired with another circuit's WASM", {
            _ = try await Prover(circuit: Circuit(artifact: good.artifact, wasm: otherWasm))
        }) {
            if case .invalidArtifact(let detail) = $0 { return detail.contains("wires") }
            return false
        }
        // Lifecycle: provers come and go.
        for round in 1...5 {
            do {
                let transient = try await Prover(circuit: good)
                let proof = try await transient.prove(["age": .integer(round), "threshold": .integer(18)])
                check(proof.publicSignals == ["0", "18"], "transient prover \(round) proved, then is released")
            } catch {
                check(false, "transient prover \(round): \(error)")
            }
        }
    }

    // MARK: concurrency

    static func concurrencyTests(_ circuit: Circuit, _ prover: Prover) async {
        print("concurrency")
        // Many callers, one prover: serialised by the actor, every result its own.
        let ages = [5, 10, 17, 18, 19, 25, 40, 90]
        let results = await withTaskGroup(of: (Int, Result<[String], LaniakeaError>).self) { group in
            for age in ages {
                group.addTask {
                    do {
                        let proof = try await prover.prove(["age": .integer(age), "threshold": .integer(18)])
                        return (age, .success(proof.publicSignals))
                    } catch {
                        return (age, .failure(LaniakeaError(wrapping: error)))
                    }
                }
            }
            var all: [Int: Result<[String], LaniakeaError>] = [:]
            for await (age, result) in group { all[age] = result }
            return all
        }
        for age in ages {
            let expected = [age >= 18 ? "1" : "0", "18"]
            if case .success(let signals)? = results[age] {
                check(signals == expected, "concurrent call, age \(age): \(signals)")
            } else {
                check(false, "concurrent call, age \(age): \(String(describing: results[age]))")
            }
        }

        // Concurrent failures and successes do not disturb each other.
        let mixed = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<6 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return (try? await prover.prove(["age": .integer(25), "threshold": .integer(18)]))?.publicSignals == ["1", "18"]
                    } else {
                        do {
                            _ = try await prover.prove(["age": .integer(274), "threshold": .integer(18)])
                            return false
                        } catch let error as LaniakeaError {
                            if case .circuitRejectedInputs = error { return true }
                            return false
                        } catch { return false }
                    }
                }
            }
            var outcomes: [Bool] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        check(mixed.count == 6 && mixed.allSatisfy { $0 }, "interleaved proofs and circuit rejections each get their own outcome")

        // Two provers in parallel.
        do {
            let second = try await Prover(circuit: circuit)
            async let a = prover.prove(["age": .integer(20), "threshold": .integer(18)])
            async let b = second.prove(["age": .integer(3), "threshold": .integer(18)])
            let (first, other) = try await (a, b)
            check(first.publicSignals == ["1", "18"] && other.publicSignals == ["0", "18"], "two provers prove in parallel")
        } catch {
            check(false, "two provers in parallel: \(error)")
        }

        // A task cancelled before proving starts is declined, and the prover is unharmed.
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        }
        cancelled.cancel()
        switch await cancelled.result {
        case .failure(let error): check(error is CancellationError, "a cancelled task gets CancellationError (got \(error))")
        case .success: check(false, "a cancelled task should not prove")
        }
        let afterCancel = try? await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        check(afterCancel?.publicSignals == ["1", "18"], "the prover works after a cancelled call")

        // Calls cancelled while the prover is busy. The actor is held with a test seam.
        // Each call runs in a detached task (so it does not inherit the main actor, which
        // this function blocks on) and signals before calling `prove`, so the cancellation
        // below happens after every task body has started. What cannot be observed from
        // outside is the moment a call enters the actor's queue: a task may be cancelled
        // just before or just after it queues. Both are declined by the same check at the
        // start of `prove`, so the assertions hold either way; this test establishes that
        // cancelled calls are declined and an uncancelled one is unaffected, not which
        // of the two orderings occurred.
        do {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let bodyStarted = DispatchSemaphore(value: 0)
            let holder = Task.detached { await prover.occupyForTesting(started: started, release: release) }
            let held = waitForSignal(started)
            check(held, "the test seam holds the prover busy")
            let doomed = (0..<3).map { _ in
                Task.detached { () async throws -> Proof in
                    bodyStarted.signal()
                    return try await prover.prove(["age": .integer(25), "threshold": .integer(18)])
                }
            }
            let survivor = Task.detached { () async throws -> Proof in
                bodyStarted.signal()
                return try await prover.prove(["age": .integer(30), "threshold": .integer(18)])
            }
            var allStarted = held
            for _ in 0..<4 where allStarted { allStarted = waitForSignal(bodyStarted) }
            check(allStarted, "every call's task body started before the cancellation")
            for task in doomed { task.cancel() }
            release.signal()
            await holder.value
            var allCancelled = true
            for task in doomed {
                if case .failure(let error) = await task.result, error is CancellationError { continue }
                allCancelled = false
            }
            check(allCancelled, "three calls cancelled while the prover was busy all get CancellationError")
            check((try? await survivor.value)?.publicSignals == ["1", "18"], "an uncancelled call issued with them still proves")
        }

        // Values cross task boundaries (this file is compiled with complete concurrency
        // checking, so Circuit, Proof, Input and Prover are checked to be Sendable).
        let proof = try? await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        let sent = await Task.detached { proof?.publicSignals }.value
        check(sent == ["1", "18"], "a Proof can be sent to another task")
    }

    /// Blocking wait with a timeout, kept out of async code (the actor thread being held
    /// is the point). True if the signal arrived.
    static func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 30) == .success
    }

    // MARK: the main thread stays free

    /// The probe used by the demo: a main-actor job is queued just before the `await`.
    /// It can run before the call returns only if the call gave up the main actor, i.e.
    /// the CPU-bound work ran elsewhere. The outcome does not depend on how long it takes.
    @MainActor
    final class MainActorProbe {
        private(set) var releasedDuringCall = false
        private var inFlight = true
        func enqueue() {
            Task { @MainActor in self.releasedDuringCall = self.inFlight }
        }
        func finished() { inFlight = false }
    }

    static func mainThreadTests(_ circuit: Circuit, _ prover: Prover) async {
        print("the main thread is not blocked")

        let constructionProbe = MainActorProbe()
        constructionProbe.enqueue()
        let built = try? await Prover(circuit: circuit)
        constructionProbe.finished()
        check(built != nil, "Prover(circuit:) succeeded from the main actor")
        check(constructionProbe.releasedDuringCall, "Prover(circuit:) gave up the main actor while it worked")

        let proveProbe = MainActorProbe()
        proveProbe.enqueue()
        let proof = try? await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        proveProbe.finished()
        check(proof?.publicSignals == ["1", "18"], "prove succeeded from the main actor")
        check(proveProbe.releasedDuringCall, "prove gave up the main actor while it worked")

        // A heartbeat on the main actor keeps ticking through a proof.
        var ticks = 0
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        _ = try? await prover.prove(["age": .integer(25), "threshold": .integer(18)])
        beat.cancel()
        check(ticks > 1, "the main actor ran \(ticks) time(s) during a proof")
    }

    // MARK: export

    static func exportTests(_ out: URL) throws {
        print("export")
        let proof = Proof(proofJSON: "{\"protocol\":\"groth16\"}", publicSignals: ["1", "18"])
        let dir = out.appendingPathComponent("export-test/nested/deeper")
        try? FileManager.default.removeItem(at: out.appendingPathComponent("export-test"))

        let urls = try proof.write(to: dir)
        check(urls.proof.lastPathComponent == "proof.json" && urls.publicSignals.lastPathComponent == "public.json", "default file names are proof.json and public.json")
        check((try? String(contentsOf: urls.proof, encoding: .utf8)) == proof.proofJSON, "proof.json holds proofJSON exactly")
        check((try? String(contentsOf: urls.publicSignals, encoding: .utf8)) == "[\"1\",\"18\"]", "public.json is a JSON array of decimal strings")
        check(urls.proof.deletingLastPathComponent().resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path, "the missing directories were created")

        let other = Proof(proofJSON: "{\"x\":1}", publicSignals: ["0", "18"])
        try other.write(to: dir)
        check((try? String(contentsOf: urls.proof, encoding: .utf8)) == "{\"x\":1}", "writing again replaces the files")

        let named = try proof.write(to: dir, proofFileName: "a.json", publicSignalsFileName: "b.json")
        check(named.proof.lastPathComponent == "a.json" && named.publicSignals.lastPathComponent == "b.json", "file names can be chosen")

        let slashes = Proof(proofJSON: "{}", publicSignals: ["1/2"])
        check(slashes.publicSignalsJSON == "[\"1/2\"]", "publicSignalsJSON does not escape slashes")
        check(Proof(proofJSON: "{}", publicSignals: []).publicSignalsJSON == "[]", "no signals -> []")

        for (what, proofName, publicName) in [
            ("an empty name", "", "public.json"),
            ("a path in a name", "../proof.json", "public.json"),
            ("a subdirectory in a name", "x/proof.json", "public.json"),
            ("the same name twice", "same.json", "same.json"),
            ("a dot name", "proof.json", ".."),
        ] {
            do {
                try proof.write(to: dir, proofFileName: proofName, publicSignalsFileName: publicName)
                check(false, "\(what): expected exportFailed")
            } catch let error as LaniakeaError {
                if case .exportFailed = error { check(true, "\(what) -> \(error.debugDescription)") } else { check(false, "\(what): \(error)") }
            }
        }
        try exportFailureTests(out)

        // A file where the directory should be.
        let blocker = out.appendingPathComponent("export-test/blocker")
        try Data("x".utf8).write(to: blocker)
        do {
            try proof.write(to: blocker.appendingPathComponent("sub"))
            check(false, "writing below a file: expected exportFailed")
        } catch let error as LaniakeaError {
            if case .exportFailed = error { check(true, "writing below a regular file -> \(error.debugDescription)") } else { check(false, "writing below a file: \(error)") }
        }
        try? FileManager.default.removeItem(at: out.appendingPathComponent("export-test"))
    }

    static func exportFailureTests(_ out: URL) throws {
        print("export: existing files and failures")
        let manager = FileManager.default
        let dir = out.appendingPathComponent("export-failure-test")
        try? manager.removeItem(at: dir)
        defer { try? manager.removeItem(at: dir) }
        func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        func leftovers() -> [String] {
            ((try? manager.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".") }
        }
        struct Injected: Error {}

        let old = Proof(proofJSON: "{\"old\":true}", publicSignals: ["0", "18"])
        let new = Proof(proofJSON: "{\"new\":true}", publicSignals: ["1", "18"])

        // Existing destination files are replaced (documented overwrite behaviour).
        try old.write(to: dir)
        try new.write(to: dir)
        check(text("proof.json") == new.proofJSON && text("public.json") == "[\"1\",\"18\"]", "existing files are replaced by a new export")
        check(leftovers().isEmpty, "no temporary files are left after a successful export")

        // The second move fails: the first destination is restored to its old contents.
        try old.write(to: dir)
        var moves = 0
        do {
            _ = try new.write(to: dir, proofFileName: "proof.json", publicSignalsFileName: "public.json") { staged, destination in
                moves += 1
                if moves == 2 { throw Injected() }
                try Proof.install(staged, at: destination)
            }
            check(false, "a failing second move should throw")
        } catch let error as LaniakeaError {
            if case .exportFailed(let file, _) = error { check(file.hasSuffix("public.json"), "the failing file is named: \(file)") } else { check(false, "\(error)") }
        }
        check(text("proof.json") == old.proofJSON && text("public.json") == "[\"0\",\"18\"]", "after a failed second move the previous valid pair is unchanged")
        check(leftovers().isEmpty, "no temporary or backup files are left after the failure")

        // The second move fails and so does the rollback: the backup is kept and named.
        try old.write(to: dir)
        moves = 0
        do {
            _ = try new.write(to: dir, proofFileName: "proof.json", publicSignalsFileName: "public.json") { staged, destination in
                moves += 1
                if moves >= 2 { throw Injected() }
                try Proof.install(staged, at: destination)
            }
            check(false, "a failing second move and rollback should throw")
        } catch let error as LaniakeaError {
            if case .exportFailed(let file, let reason) = error {
                let backups = leftovers().filter { $0.hasSuffix(".bak") }
                check(file.hasSuffix("public.json"), "rollback failure: the failing file is named: \(file)")
                check(backups.count == 1, "rollback failure: exactly one backup is kept (\(backups))")
                if let backup = backups.first {
                    let path = dir.appendingPathComponent(backup).path
                    check(reason.contains(path), "rollback failure: the error names the backup path")
                    check((try? String(contentsOfFile: path, encoding: .utf8)) == old.proofJSON, "rollback failure: the backup holds the previous proof")
                }
                check(reason.contains("Restoring") && reason.contains("failed"), "rollback failure: the error says the rollback failed (\(reason))")
            } else { check(false, "\(error)") }
        }
        check(text("proof.json") == new.proofJSON && text("public.json") == "[\"0\",\"18\"]", "rollback failure: the destinations are left as the failed export made them (new proof.json, old public.json)")
        for name in leftovers() { try? manager.removeItem(at: dir.appendingPathComponent(name)) }

        // Same, when nothing existed before: no new proof.json is left alone.
        try manager.removeItem(at: dir)
        moves = 0
        do {
            _ = try new.write(to: dir, proofFileName: "proof.json", publicSignalsFileName: "public.json") { staged, destination in
                moves += 1
                if moves == 2 { throw Injected() }
                try Proof.install(staged, at: destination)
            }
            check(false, "a failing second move should throw")
        } catch is LaniakeaError {
            check(text("proof.json") == nil && text("public.json") == nil, "a failed first-time export leaves neither file")
            check(leftovers().isEmpty, "no temporary files are left after a failed first-time export")
        }

        // The first move fails: nothing was changed.
        try old.write(to: dir)
        do {
            _ = try new.write(to: dir, proofFileName: "proof.json", publicSignalsFileName: "public.json") { _, _ in throw Injected() }
            check(false, "a failing first move should throw")
        } catch is LaniakeaError {
            check(text("proof.json") == old.proofJSON && text("public.json") == "[\"0\",\"18\"]", "after a failed first move the previous pair is unchanged")
            check(leftovers().isEmpty, "no temporary files are left after a failed first move")
        }

        // A directory where public.json should go is refused before anything is changed.
        try manager.removeItem(at: dir.appendingPathComponent("public.json"))
        try manager.createDirectory(at: dir.appendingPathComponent("public.json"), withIntermediateDirectories: false)
        do {
            try new.write(to: dir)
            check(false, "a directory in the way should be refused")
        } catch is LaniakeaError {
            check(text("proof.json") == old.proofJSON, "a directory in the way: the existing proof.json is untouched")
            check(leftovers().isEmpty, "a directory in the way: no temporary files")
        }
        try manager.removeItem(at: dir.appendingPathComponent("public.json"))

        // Staging fails (the first staged file cannot be written in a read-only directory):
        // destinations untouched. Skipped when running as root.
        if geteuid() != 0 {
            try old.write(to: dir)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            do {
                try new.write(to: dir)
                check(false, "an unwritable directory should fail")
            } catch let error as LaniakeaError {
                if case .exportFailed = error { check(true, "an unwritable directory -> \(error.debugDescription)") } else { check(false, "\(error)") }
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            check(text("proof.json") == old.proofJSON && text("public.json") == "[\"0\",\"18\"]", "an unwritable directory: the previous pair is unchanged")
            check(leftovers().isEmpty, "an unwritable directory: no temporary files")
        }
    }
}
