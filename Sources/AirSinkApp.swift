import SwiftUI

@main
struct AirSinkApp: App {
    @StateObject private var uxplay = UxPlayManager()
    @StateObject private var windows = DeviceWindowsCoordinator()

    var body: some Scene {
        WindowGroup("AirSink") {
            ContentView()
                .environmentObject(uxplay)
                .environmentObject(windows)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
