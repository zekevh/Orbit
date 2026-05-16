import SwiftUI

@main
struct orbitApp: App {
    @StateObject private var model = OrbitAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    model.start()
                }
        }
    }
}
