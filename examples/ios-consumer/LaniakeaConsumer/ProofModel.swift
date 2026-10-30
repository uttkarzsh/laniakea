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
    /// Wall-clock times and process memory of the last load and proof, for reading on a device.
    @Published private(set) var measurements: String?
    @Published var ageText = ""

    private var prover: Prover?
    private var loadSeconds: Double?

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
        let start = ContinuousClock.now
        do {
            let circuit = try await Task.detached { try Circuit(name: "age_check") }.value
            prover = try await Prover(circuit: circuit)
            loadSeconds = start.duration(to: .now).seconds
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
        let start = ContinuousClock.now
        do {
            proof = try await prover.prove(["age": .integer(age), "threshold": .integer(Self.threshold)])
            measurements = Self.describe(loadSeconds: loadSeconds, proveSeconds: start.duration(to: .now).seconds)
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

    private static func describe(loadSeconds: Double?, proveSeconds: Double) -> String {
        var parts = [String(format: "prove %.3f s", proveSeconds)]
        if let loadSeconds { parts.insert(String(format: "load %.3f s", loadSeconds), at: 0) }
        if let memory = Memory.footprintMB() {
            parts.append(String(format: "memory now %.0f MB, peak %.0f MB", memory.current, memory.peak))
        }
        return parts.joined(separator: ", ")
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
        var lines = ["age=\(age) signals=\(proof?.publicSignals ?? []) phase=\(phase) outcome=\(outcome ?? "-") measurements=\(measurements ?? "-")"]
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

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Physical memory footprint of this process (what iOS counts against the app's limit).
enum Memory {
    static func footprintMB() -> (current: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
