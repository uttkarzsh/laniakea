import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgeProofViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Age (0–\(AgeProofService.maxValue))", text: $model.ageText)
                        .keyboardType(.numberPad)
                        .disabled(model.isBusy)
                    if let message = model.inputMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Your age")
                } footer: {
                    Text("Threshold: \(AgeProofService.threshold) (fixed). The age is a private input: it is used only on this device.")
                }

                Section {
                    Button(action: model.submit) {
                        HStack {
                            Text("Generate proof")
                            Spacer()
                            if model.isBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canSubmit)
                }

                StatusSection(phase: model.phase)

                Section("About this demo") {
                    Text("""
                        Generates a Groth16 proof (BN254) on this device; the app makes no network \
                        requests. It does not verify the proof. The circuit outputs out = 1 if \
                        age ≥ \(AgeProofService.threshold) and out = 0 otherwise, and a valid proof \
                        exists for both, so the result is read from the public signals.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Age check")
        }
        .onAppear {
            model.load(autoSubmitAge: LaunchOptions.autoProveAge)
        }
    }
}

private struct StatusSection: View {
    let phase: AgeProofViewModel.Phase

    var body: some View {
        switch phase {
        case .notLoaded, .loading:
            Section("Status") {
                HStack {
                    ProgressView()
                    Text("Loading the prover…")
                }
            }
        case .unavailable(let error):
            Section("Status") {
                Label("Prover unavailable.", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Text(error.userMessage)
                DetailsDisclosure(text: error.debugDetail)
            }
        case .ready:
            Section("Status") {
                Text("Ready. Enter an age and generate a proof.")
            }
        case .proving(let age):
            Section("Status") {
                HStack {
                    ProgressView()
                    Text("Generating a proof for age \(age)…")
                }
            }
        case .proved(let age, let proof):
            Section("Result") {
                switch proof.eligibility {
                case .eligible:
                    Label("Proof generated — eligible.", systemImage: "checkmark.seal")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("The circuit computed \(age) ≥ \(AgeProofService.threshold) (out = 1).")
                case .notEligible:
                    Label("Proof generated — not eligible.", systemImage: "minus.circle")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("The circuit computed \(age) < \(AgeProofService.threshold) (out = 0). The proof is about that false condition.")
                }
                Text("Generated on this device in \(Self.duration(proof.seconds)). Not verified by this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DetailsDisclosure(text: "Public signals [out, threshold]: \(proof.publicSignals)\n\nproof.json:\n\(proof.proofJson)")
            }
        case .failed(let age, let error):
            Section("Result") {
                Label("Proof generation failed.", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(error.userMessage)
                Text("Attempted age: \(age). You can edit the age and try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DetailsDisclosure(text: error.debugDetail)
            }
        }
    }
}

extension StatusSection {
    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}

/// Collapsed by default: diagnostics for developers, not for the user.
private struct DetailsDisclosure: View {
    let text: String

    var body: some View {
        DisclosureGroup("Details") {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
