import SwiftUI

@main
struct AgeCheckApp: App {
    @StateObject private var model = AgeProofViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

enum LaunchOptions {
    /// Debug builds only: launching with `-AgeCheckAutoProveAge 25` enters that
    /// age and presses "Generate proof" once the prover has loaded, through the
    /// same validation and code path as the button. It exists so that
    /// scripts/run-ios-sim-app.sh can drive the simulator, which `simctl` cannot
    /// tap or type into. Always nil in release builds.
    static var autoProveAge: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "AgeCheckAutoProveAge")
        #else
        nil
        #endif
    }
}
