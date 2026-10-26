// UI state for the age-check screen. Imports Combine (ObservableObject,
// @Published), not SwiftUI, so the macOS logic test can drive it.

import Combine
import Foundation

@MainActor
final class AgeProofViewModel: ObservableObject {
    enum Phase: Equatable {
        case notLoaded
        /// Reading the bundled resources and constructing the prover.
        case loading
        /// The prover could not be constructed; proving is impossible.
        case unavailable(AgeProofError)
        case ready
        case proving(age: UInt8)
        /// A proof was generated (not verified) and its public signals classified.
        case proved(age: UInt8, AgeProof)
        /// This attempt failed; the prover is still usable.
        case failed(age: UInt8, AgeProofError)
    }

    @Published var ageText = ""
    @Published private(set) var phase: Phase = .notLoaded

    private let loadResources: @Sendable () throws(AgeProofError) -> CircuitResources
    private var service: AgeProofService?
    /// The load or proof in flight, if any. Internal so tests can await it.
    private(set) var work: Task<Void, Never>?

    /// `loadResources` is called once, off the main actor. Tests inject their own.
    init(
        loadResources: @escaping @Sendable () throws(AgeProofError) -> CircuitResources = {
            () throws(AgeProofError) -> CircuitResources in try AgeProofViewModel.bundledResources()
        }
    ) {
        self.loadResources = loadResources
    }

    var ageInput: Result<UInt8, AgeInputError> { AgeProofService.parseAge(ageText) }

    /// Shown under the field. Nothing while the field is empty: the disabled
    /// button is enough until the user has typed something.
    var inputMessage: String? {
        guard case .failure(let error) = ageInput, error != .empty else { return nil }
        return error.userMessage
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .proving: true
        default: false
        }
    }

    var canSubmit: Bool {
        guard service != nil, !isBusy, case .success = ageInput else { return false }
        return true
    }

    /// Construct the prover, once. Reading the files, validating the artifact and
    /// compiling the WASM all happen on a detached task, off the main actor.
    /// `autoSubmitAge` (debug automation, see `LaunchOptions`) is entered and
    /// submitted once the prover is ready.
    func load(autoSubmitAge: String? = nil) {
        guard phase == .notLoaded else { return }
        phase = .loading
        let loadResources = self.loadResources
        work = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<AgeProofService, AgeProofError> in
                do throws(AgeProofError) {
                    return .success(try AgeProofService(resources: loadResources()))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let service):
                self.service = service
                phase = .ready
                debugTrace("ready")
            case .failure(let error):
                phase = .unavailable(error)
                debugTrace("unavailable \(error.debugDetail)")
            }
            work = nil
            if let autoSubmitAge, service != nil {
                ageText = autoSubmitAge
                submit()
            }
        }
    }

    /// Generate a proof for the age in the field. Ignored while loading or proving
    /// (no duplicate submissions) and for input that does not parse: invalid input
    /// never reaches the prover.
    func submit() {
        guard let service, !isBusy else { return }
        let age: UInt8
        switch ageInput {
        case .success(let value):
            age = value
        case .failure(let error):
            debugTrace("input-rejected \(error)")
            return
        }
        phase = .proving(age: age)
        debugTrace("proving")
        work = Task {
            #if DEBUG
            let probe = MainActorProbe()
            probe.enqueue()
            #endif
            let next: Phase
            do throws(AgeProofError) {
                // Runs on the service's actor, off the main actor; this task only
                // resumes here when the proof is done.
                next = .proved(age: age, try await service.prove(age: age))
            } catch {
                next = .failed(age: age, error)
            }
            #if DEBUG
            probe.proofFinished()
            let responsiveness = " mainActorReleased=\(probe.mainActorReleased) mainActorWaitMs=\(probe.waitMs)"
            #else
            let responsiveness = ""
            #endif
            phase = next
            work = nil
            switch next {
            case .proved(_, let proof):
                debugTrace("result \(proof.eligibility) signals=\(proof.publicSignals) seconds=\(proof.seconds)\(responsiveness)")
            case .failed(_, let error):
                debugTrace("failed \(error.debugDetail)\(responsiveness)")
            default:
                break
            }
        }
    }

    /// The production resource loader: both files from the app bundle.
    nonisolated static func bundledResources() throws(AgeProofError) -> CircuitResources {
        func read(_ name: String, _ ext: String) throws(AgeProofError) -> Data {
            let file = "\(name).\(ext)"
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw .resourceUnavailable(name: file, detail: "not found in the app bundle")
            }
            do {
                return try Data(contentsOf: url)
            } catch {
                throw .resourceUnavailable(name: file, detail: error.localizedDescription)
            }
        }
        return CircuitResources(artifact: try read("age_check", "artifact"), wasm: try read("age_check", "wasm"))
    }
}

/// Debug builds: one line on stderr per state change, read by
/// scripts/run-ios-sim-app.sh. Never logs the age itself. No-op in release.
nonisolated func debugTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    FileHandle.standardError.write(Data("AGECHECK \(message())\n".utf8))
    #endif
}

#if DEBUG
/// Debug builds: evidence that proving does not hold the main actor.
///
/// `enqueue()` is called just before the proving task awaits the service; it
/// queues one main-actor job. That job can run before the proving task resumes
/// only if the `await` gave up the main actor, i.e. the proof ran elsewhere (the
/// service's actor; the service traces `prover-call mainThread=false`). Had the
/// proof run on the main actor, the task would not have suspended and
/// `proofFinished()` would come first. The answer does not depend on how long the
/// proof takes. `waitMs` is how long the job waited for the main actor (which is
/// busy rendering meanwhile); it is not the proof time.
@MainActor
final class MainActorProbe {
    private(set) var mainActorReleased = false
    private(set) var waitMs = -1.0
    private var proofInFlight = true

    func enqueue() {
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
            self.mainActorReleased = self.proofInFlight
            self.waitMs = Double(DispatchTime.now().uptimeNanoseconds - enqueuedAt) / 1e6
        }
    }

    func proofFinished() {
        proofInFlight = false
    }
}
#endif
