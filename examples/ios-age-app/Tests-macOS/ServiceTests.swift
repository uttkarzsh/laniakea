// Phase 6d logic tests for the age-check app, run on the macOS host by
// scripts/swift-app-logic-test.sh. Compiled together with the app's
// AgeProofService.swift, ProverError+Message.swift and AgeProofViewModel.swift,
// against the generated bindings built as a separate `Laniakea` module (as in the
// app). XCTest is not used; failures are counted and reported through the exit code.
//
// Usage: ServiceTests <resources-dir> <out-dir>
//   reads  <resources-dir>/age_check.artifact and age_check.wasm (the app's bundled copies)
//   writes <out-dir>/{eligible,ineligible}.{proof,public}.json for snarkjs

import Foundation
import Laniakea

// Everything here runs on the main actor, sequentially; the prover runs on the
// service's actor.
@MainActor var failures = 0

@MainActor
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   " : "  FAIL ", what)
    if !ok { failures += 1 }
}

/// Parse proof.json structurally (never by substring).
func proofObject(_ json: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
}

@MainActor
func checkProofJson(_ json: String, _ label: String) {
    guard let proof = proofObject(json) else {
        check(false, "\(label): proofJson is a JSON object")
        return
    }
    check(proof["protocol"] as? String == "groth16", "\(label): proofJson.protocol == \"groth16\"")
    check(proof["curve"] as? String == "bn128", "\(label): proofJson.curve == \"bn128\"")
    for key in ["pi_a", "pi_b", "pi_c"] {
        check((proof[key] as? [Any])?.count == 3, "\(label): proofJson.\(key) has 3 entries")
    }
}

func write(_ proof: AgeProof, to dir: URL, as name: String) throws {
    try Data(proof.proofJson.utf8).write(to: dir.appendingPathComponent("\(name).proof.json"))
    try JSONSerialization.data(withJSONObject: proof.publicSignals)
        .write(to: dir.appendingPathComponent("\(name).public.json"))
}

/// Expect `body` to throw an AgeProofError matching `matches`.
@MainActor
func expectFailure(
    _ name: String,
    _ body: () async throws -> Void,
    _ matches: (AgeProofError) -> Bool
) async {
    do {
        try await body()
        check(false, "\(name): expected an error, got success")
    } catch let error as AgeProofError {
        check(matches(error), "\(name): \(error.debugDetail)")
    } catch {
        check(false, "\(name): not an AgeProofError: \(error)")
    }
}

/// Every ProverError case, one value each. Keep in step with the generated enum:
/// the exhaustive switch in `caseName` fails to compile if a case is added.
let allProverErrors: [ProverError] = [
    .InvalidInputValue(signal: "age", index: 0, value: "x"),
    .UnknownSignal(name: "nope"),
    .DuplicateSignal(name: "age"),
    .InputSize(signal: "age", expected: 1, got: 2),
    .MissingInputs(set: 1, expected: 2),
    .AssertionFailed(detail: "d"),
    .ResourceExhausted(detail: "d"),
    .CircuitAbort(code: 7, reason: "r", detail: "d"),
    .WitnessEngine(detail: "d"),
    .ArtifactLoad(detail: "d"),
    .InvalidArtifact(detail: "d"),
    .InvalidCircuitModule(detail: "d"),
    .UnsupportedField(detail: "d"),
    .CircuitEngine(detail: "d"),
    .InvalidWitness(detail: "d"),
    .ProofGeneration(detail: "d"),
    .Internal(detail: "d"),
]

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
    case .InvalidCircuitModule: "InvalidCircuitModule"
    case .UnsupportedField: "UnsupportedField"
    case .CircuitEngine: "CircuitEngine"
    case .InvalidWitness: "InvalidWitness"
    case .ProofGeneration: "ProofGeneration"
    case .Internal: "Internal"
    }
}

@main
@MainActor
struct ServiceTests {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            print("usage: ServiceTests <resources-dir> <out-dir>")
            exit(64)
        }
        let resourcesDir = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2])
        let artifact = try Data(contentsOf: resourcesDir.appendingPathComponent("age_check.artifact"))
        let wasm = try Data(contentsOf: resourcesDir.appendingPathComponent("age_check.wasm"))
        let resources = CircuitResources(artifact: artifact, wasm: wasm)

        try await serviceTests(resources, outDir)
        await classificationTests()
        inputTests()
        await resourceErrorTests(resources)
        messageTests()
        await viewModelTests(resources)

        print(failures == 0 ? "APP LOGIC TESTS: PASSED" : "APP LOGIC TESTS: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: proving through the service

    static func serviceTests(_ resources: CircuitResources, _ outDir: URL) async throws {
        print("service: construct + prove (threshold \(AgeProofService.threshold))")
        let service = try AgeProofService(resources: resources)

        let eligible = try await service.prove(age: 25)
        check(eligible.eligibility == .eligible, "age 25 is classified eligible")
        check(eligible.publicSignals == ["1", "18"], "age 25: publicSignals == [\"1\", \"18\"] (got \(eligible.publicSignals))")
        checkProofJson(eligible.proofJson, "age 25")
        try write(eligible, to: outDir, as: "eligible")

        // The circuit does not constrain out == 1: an ineligible age still proves.
        let ineligible = try await service.prove(age: 10)
        check(ineligible.eligibility == .notEligible, "age 10 is classified not eligible (a proof, not an error)")
        check(ineligible.publicSignals == ["0", "18"], "age 10: publicSignals == [\"0\", \"18\"] (got \(ineligible.publicSignals))")
        checkProofJson(ineligible.proofJson, "age 10")
        try write(ineligible, to: outDir, as: "ineligible")

        let boundary = try await service.prove(age: 18)
        check(boundary.eligibility == .eligible && boundary.publicSignals == ["1", "18"], "age 18 (boundary) is eligible")
        let below = try await service.prove(age: 17)
        check(below.eligibility == .notEligible && below.publicSignals == ["0", "18"], "age 17 is not eligible")
        let edges = (try await service.prove(age: 0), try await service.prove(age: 255))
        check(edges.0.publicSignals == ["0", "18"] && edges.1.publicSignals == ["1", "18"], "ages 0 and 255 (range edges) prove")

        print("service: what the circuit itself does with out-of-range ages (raw path)")
        await expectFailure("age 300 (raw path) reaches the circuit and fails its assertion", {
            _ = try await service.prove(ageDecimal: "300")
        }) {
            guard case .prover(let e) = $0, case .AssertionFailed = e else { return false }
            return e.category == .circuitRejected
        }
        // Characterization: the circuit does NOT range-check its inputs to 8 bits.
        // GreaterEqThan(8) bit-decomposes threshold + 256 - (age + 1) into 9 bits,
        // so its assertion fires only when that leaves [0, 511]. With threshold 18,
        // ages 0...273 prove (256...273 with out = 1) and 274 is the first to fail.
        // A field element near p (a "negative" age) proves with out = 0. Only the
        // app's own validation (parseAge, 0...255) keeps such values away.
        let p256 = try await service.prove(ageDecimal: "256")
        check(p256.publicSignals == ["1", "18"], "age 256 (raw path) is NOT rejected by the circuit: proves with out = 1 (got \(p256.publicSignals))")
        let p273 = try await service.prove(ageDecimal: "273")
        check(p273.publicSignals == ["1", "18"], "age 273 (raw path) proves: the circuit's last accepted value for threshold 18")
        await expectFailure("age 274 (raw path) is the first to fail the circuit assertion", {
            _ = try await service.prove(ageDecimal: "274")
        }) {
            if case .prover(.AssertionFailed) = $0 { return true }
            return false
        }
        let pMinus1 = "21888242871839275222246405745257275088548364400416034343698204186575808495616"
        let negative = try await service.prove(ageDecimal: pMinus1)
        check(negative.publicSignals == ["0", "18"], "age p - 1 (a field element, \"-1\") proves with out = 0 (got \(negative.publicSignals))")
        await expectFailure("a malformed decimal (raw path) is rejected by the bindings", {
            _ = try await service.prove(ageDecimal: "-1")
        }) {
            if case .prover(.InvalidInputValue(let signal, 0, "-1")) = $0 { return signal == "age" }
            return false
        }
        let again = try await service.prove(age: 25)
        check(again.publicSignals == ["1", "18"], "the service still proves after the failures above")
    }

    // MARK: public-signal classification

    static func classificationTests() async {
        print("classification of public signals")
        func classify(_ s: [String]) -> Result<Eligibility, SignalError> {
            AgeProofService.classify(publicSignals: s)
        }
        check(classify(["1", "18"]) == .success(.eligible), "[\"1\", \"18\"] -> eligible")
        check(classify(["0", "18"]) == .success(.notEligible), "[\"0\", \"18\"] -> not eligible")
        check(classify(["1", "19"]) == .failure(.thresholdMismatch(expected: "18", got: "19")), "[\"1\", \"19\"] -> rejected (threshold mismatch)")
        check(classify(["0", "17"]) == .failure(.thresholdMismatch(expected: "18", got: "17")), "[\"0\", \"17\"] -> rejected (threshold mismatch)")
        check(classify(["2", "18"]) == .failure(.unexpectedOutput("2")), "[\"2\", \"18\"] -> rejected (out not 0/1)")
        check(classify(["01", "18"]) == .failure(.unexpectedOutput("01")), "[\"01\", \"18\"] -> rejected (non-canonical out)")
        check(classify(["1", "018"]) == .failure(.thresholdMismatch(expected: "18", got: "018")), "[\"1\", \"018\"] -> rejected (non-canonical threshold)")
        check(classify(["1"]) == .failure(.wrongCount(expected: 2, got: 1)), "[\"1\"] -> rejected (count)")
        check(classify(["1", "18", "0"]) == .failure(.wrongCount(expected: 2, got: 3)), "[\"1\", \"18\", \"0\"] -> rejected (count)")
        check(classify([]) == .failure(.wrongCount(expected: 2, got: 0)), "[] -> rejected (count)")
        check(AgeProofService.classify(publicSignals: ["1", "21"], threshold: 21) == .success(.eligible), "the threshold parameter is honoured")
    }

    // MARK: input validation before Rust

    static func inputTests() {
        print("input validation (never reaches the prover)")
        let cases: [(String, Result<UInt8, AgeInputError>)] = [
            ("", .failure(.empty)), ("   ", .failure(.empty)),
            ("abc", .failure(.notANumber)), ("12a", .failure(.notANumber)), ("1.5", .failure(.notANumber)),
            ("+25", .failure(.notANumber)), ("2 5", .failure(.notANumber)), ("-", .failure(.notANumber)),
            ("٢٥", .failure(.notANumber)), ("２５", .failure(.notANumber)), ("0x19", .failure(.notANumber)),
            ("-1", .failure(.negative)), ("-0", .failure(.negative)), ("-300", .failure(.negative)),
            ("256", .failure(.outOfRange)), ("300", .failure(.outOfRange)), ("1000", .failure(.outOfRange)),
            ("99999999999999999999999999999999", .failure(.outOfRange)),
            ("0", .success(0)), ("000", .success(0)), ("18", .success(18)), (" 25\n", .success(25)),
            ("0025", .success(25)), ("255", .success(255)), ("00000000000000000255", .success(255)),
        ]
        for (text, expected) in cases {
            let got = AgeProofService.parseAge(text)
            check(got == expected, "parseAge(\(text.debugDescription)) == \(expected) (got \(got))")
        }
    }

    // MARK: bad bundled resources

    static func resourceErrorTests(_ good: CircuitResources) async {
        print("bad resources are classified")
        await expectFailure("invalid WASM", {
            _ = try AgeProofService(resources: CircuitResources(artifact: good.artifact, wasm: Data([0, 1, 2, 3])))
        }) {
            guard case .prover(let e) = $0, case .InvalidCircuitModule = e else { return false }
            return e.category == .bundledResources
        }
        await expectFailure("empty artifact", {
            _ = try AgeProofService(resources: CircuitResources(artifact: Data(), wasm: good.wasm))
        }) {
            guard case .prover(let e) = $0, case .ArtifactLoad = e else { return false }
            return e.category == .bundledResources
        }
        await expectFailure("truncated artifact", {
            _ = try AgeProofService(resources: CircuitResources(artifact: good.artifact.prefix(good.artifact.count / 2), wasm: good.wasm))
        }) {
            if case .prover(.ArtifactLoad) = $0 { return true }
            return false
        }
        // The WASM bytes in place of the artifact, and vice versa.
        await expectFailure("swapped files", {
            _ = try AgeProofService(resources: CircuitResources(artifact: good.wasm, wasm: good.artifact))
        }) {
            guard case .prover(let e) = $0 else { return false }
            return e.category == .bundledResources
        }
    }

    // MARK: messages

    static func messageTests() {
        print("user-facing messages")
        check(allProverErrors.count == 17, "all 17 ProverError cases are listed")
        check(Set(allProverErrors.map(caseName)).count == allProverErrors.count, "the listed cases are distinct")
        var messages = Set<String>()
        for e in allProverErrors {
            let message = e.userMessage
            let ok = !message.isEmpty && message.hasSuffix(".") && !message.contains("ProverError")
            check(ok, "\(caseName(e)) [\(e.category)]: \(message)")
            check(e.debugDetail.hasPrefix(caseName(e)), "\(caseName(e)): debugDetail names the case")
            messages.insert(message)
        }
        check(messages.count == allProverErrors.count, "every ProverError case has its own message")

        let appErrors: [AgeProofError] = [
            .resourceUnavailable(name: "age_check.wasm", detail: "not found"),
            .prover(.Internal(detail: "x")), .unexpectedSignalCount(3),
            .unexpectedSignals(.unexpectedOutput("2"), ["2", "18"]), .bindingFailure("panic"),
        ]
        for e in appErrors {
            check(!e.userMessage.isEmpty && !e.debugDetail.isEmpty, "AgeProofError message: \(e.userMessage)")
        }
        for e in [AgeInputError.empty, .notANumber, .negative, .outOfRange] {
            check(!e.userMessage.isEmpty, "AgeInputError.\(e): \(e.userMessage)")
        }
    }

    // MARK: view model

    static func viewModelTests(_ resources: CircuitResources) async {
        print("view model")
        let model = AgeProofViewModel(loadResources: { resources })
        check(model.phase == .notLoaded && !model.canSubmit, "starts not loaded; cannot submit")
        model.ageText = "25"
        model.submit()
        check(model.phase == .notLoaded && model.work == nil, "submit before load is ignored")

        model.load()
        check(model.phase == .loading && model.isBusy, "load() moves to loading")
        await model.work?.value
        check(model.phase == .ready, "loads the prover (phase \(model.phase))")
        model.load()
        check(model.phase == .ready && model.work == nil, "a second load() is ignored")

        for (text, expected) in [("", AgeInputError.empty), ("abc", .notANumber), ("-3", .negative), ("256", .outOfRange)] {
            model.ageText = text
            model.submit()
            check(model.phase == .ready && model.work == nil && !model.canSubmit,
                  "\(text.debugDescription) is rejected before proving (\(expected))")
            check((model.inputMessage == nil) == (expected == .empty), "\(text.debugDescription): input message shown only for non-empty input")
        }

        // One submission at a time, and the main actor keeps running meanwhile.
        model.ageText = "25"
        check(model.canSubmit, "a valid age can be submitted")
        model.submit()
        let first = model.work
        check(model.phase == .proving(age: 25) && model.isBusy && !model.canSubmit, "submit() moves to proving")
        model.ageText = "10"
        model.submit()
        check(model.work == first && model.phase == .proving(age: 25), "a second submit while proving is ignored")
        // Counted only after a sleep resumes with the proof still in flight: if
        // proving blocked the main actor, the first resumption would come after it.
        var turnsWhileProving = 0
        while true {
            try? await Task.sleep(nanoseconds: 500_000)
            guard model.isBusy else { break }
            turnsWhileProving += 1
        }
        check(turnsWhileProving > 0, "the main actor ran \(turnsWhileProving) time(s) while the proof was in flight")
        guard case .proved(25, let proof) = model.phase else {
            check(false, "proof for age 25 (phase \(model.phase))")
            return
        }
        check(proof.eligibility == .eligible && proof.publicSignals == ["1", "18"], "view model: age 25 -> eligible, [\"1\", \"18\"]")

        // The ignored second submission left "10" in the field: submit it now.
        model.submit()
        await model.work?.value
        if case .proved(10, let p) = model.phase {
            check(p.eligibility == .notEligible && p.publicSignals == ["0", "18"], "view model: age 10 -> not eligible, [\"0\", \"18\"]")
        } else {
            check(false, "proof for age 10 (phase \(model.phase))")
        }

        let broken = AgeProofViewModel(loadResources: { () throws(AgeProofError) -> CircuitResources in
            throw .resourceUnavailable(name: "age_check.wasm", detail: "not found in the app bundle")
        })
        broken.load()
        await broken.work?.value
        check(broken.phase == .unavailable(.resourceUnavailable(name: "age_check.wasm", detail: "not found in the app bundle")),
              "a missing resource makes the prover unavailable")
        broken.ageText = "25"
        broken.submit()
        check(!broken.canSubmit && broken.work == nil, "nothing can be submitted without a prover")

        let badWasm = AgeProofViewModel(loadResources: { CircuitResources(artifact: resources.artifact, wasm: Data([1, 2, 3])) })
        badWasm.load()
        await badWasm.work?.value
        if case .unavailable(.prover(.InvalidCircuitModule)) = badWasm.phase {
            check(true, "invalid WASM -> unavailable(InvalidCircuitModule)")
        } else {
            check(false, "invalid WASM -> unavailable(InvalidCircuitModule) (phase \(badWasm.phase))")
        }
    }
}
