// A third-party app's use of LaniakeaKit. Only `import LaniakeaKit`: no generated
// bindings, no Rust, no build outputs of the SDK repository.

import Foundation
import LaniakeaKit

@MainActor
final class ProofModel: ObservableObject {
    enum Phase {
        case loading
        case ready
        case proving
        case failed(String)
    }

    /// The statement this app proves: age >= 18. Fixed, the user only enters an age.
    static let threshold = 18

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var proof: Proof?
    @Published private(set) var exportMessage: String?
    @Published var ageText = ""

    private var prover: Prover?

    /// What the public signals say: `out` is `publicSignals[0]`. A *valid* proof exists
    /// for both answers, so this is read from the signals, never from "proving worked".
    var outcome: String? {
        guard let signals = proof?.publicSignals, signals.count == 2 else { return nil }
        guard signals[1] == String(Self.threshold) else { return "Unexpected threshold \(signals[1])" }
        switch signals[0] {
        case "1": return "out = 1: the circuit computed age >= \(Self.threshold)"
        case "0": return "out = 0: the circuit computed age < \(Self.threshold)"
        default: return "Unexpected output \(signals[0])"
        }
    }

    func load() async {
        // Reading the two bundled files and building the prover (artifact validation,
        // WASM compilation) are both off the main thread: `Prover` is an actor whose
        // synchronous Rust work runs on the cooperative pool, and the file reads go in
        // a detached task.
        do {
            let circuit = try await Task.detached { try Circuit(name: "age_check") }.value
            prover = try await Prover(circuit: circuit)
            phase = .ready
        } catch {
            phase = .failed(describe(error))
        }
    }

    func prove() async {
        guard let prover, let age = Int(ageText.trimmingCharacters(in: .whitespaces)), age >= 0, age <= 255 else {
            phase = .failed("Enter a whole number from 0 to 255 (the circuit compares 8-bit numbers).")
            return
        }
        phase = .proving
        proof = nil
        exportMessage = nil
        do {
            proof = try await prover.prove(["age": .integer(age), "threshold": .integer(Self.threshold)])
            phase = .ready
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// Writes proof.json and public.json into the app's Documents directory.
    func export() {
        guard let proof else { return }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let urls = try proof.write(to: documents)
            exportMessage = "Wrote \(urls.proof.path) and \(urls.publicSignals.path)"
        } catch {
            exportMessage = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        if let error = error as? LaniakeaError {
            return "\(error.localizedDescription)\n\(error.debugDescription)"
        }
        return String(describing: error)
    }

    #if DEBUG
    /// Automation for the simulator (`-ConsumerAutoAge 25 -ConsumerAutoExport 1`): the
    /// same code path as the buttons. The outcome is written to Documents/consumer.log
    /// (stdout of a launched simulator app is not reliably captured).
    func autoRun() async {
        let defaults = UserDefaults.standard
        guard let age = defaults.string(forKey: "ConsumerAutoAge") else { return }
        await load()
        ageText = age
        await prove()
        var lines = ["age=\(age) signals=\(proof?.publicSignals ?? []) phase=\(phase) outcome=\(outcome ?? "-")"]
        if defaults.bool(forKey: "ConsumerAutoExport") {
            export()
            lines.append("export: \(exportMessage ?? "-")")
        }
        if let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? (lines.joined(separator: "\n") + "\n").write(to: documents.appendingPathComponent("consumer.log"), atomically: true, encoding: .utf8)
        }
    }
    #endif
}
