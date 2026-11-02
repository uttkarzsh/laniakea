import SwiftUI
import LaniakeaKit

struct ContentView: View {
    @ObservedObject var model: ProofModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Prove that age ≥ \(ProofModel.threshold)") {
                    TextField("Age (0–255)", text: $model.ageText)
                        .keyboardType(.numberPad)
                    Button("Generate proof") { Task { await model.prove() } }
                        .disabled(!canProve)
                    status
                }
                if let proof = model.proof {
                    Section("Result") {
                        LabeledContent("Public signals", value: proof.publicSignals.joined(separator: ", "))
                        if let outcome = model.outcome { Text(outcome) }
                        if let measurements = model.measurements {
                            Text(measurements).font(.footnote).monospacedDigit()
                        }
                        Button("Verify on this device") { Task { await model.verify() } }
                            .disabled(!model.canVerify)
                        if let verification = model.verification {
                            Text(verification).font(.footnote).textSelection(.enabled)
                        }
                        Text("Two separate questions. Is the proof valid? The button checks it here, against the verification key bundled with this app; that only checks this device's prover, so anyone relying on the proof must verify it themselves, with a key they trust. Is the person eligible? Only the public signal out says so (1 = yes), and a valid proof also exists when out = 0.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Export proof.json and public.json") { model.export() }
                        if let message = model.exportMessage {
                            Text(message).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Text("Development example: the age_check artifact comes from a development trusted setup and is not production material.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("LaniakeaKit consumer")
        }
        .task {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "ConsumerAutoAge") != nil {
                await model.autoRun()
                return
            }
            #endif
            await model.load()
        }
    }

    private var canProve: Bool {
        switch model.phase {
        case .ready, .failed: true
        case .loading, .proving: false
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .loading: ProgressView("Loading circuit…")
        case .proving: ProgressView("Proving…")
        case .failed(let message): Text(message).foregroundStyle(.red).textSelection(.enabled)
        case .ready: EmptyView()
        }
    }
}
