import SwiftUI

@main
struct MoDiConnectApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .task { appState.startDiscovery() }
        }
    }
}
