import SwiftUI

@main
struct LaniakeaConsumerApp: App {
    @StateObject private var model = ProofModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
