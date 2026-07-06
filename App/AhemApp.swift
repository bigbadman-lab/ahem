import SwiftUI

@main
struct AhemApp: App {
    @StateObject private var appState: AppState
    @StateObject private var coordinator: AppCoordinator

    init() {
        let appState = AppState()
        let coordinator = AppCoordinator(appState: appState)

        _appState = StateObject(wrappedValue: appState)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        MenuBarExtra("Ahem", systemImage: "waveform") {
            MenuBarView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Window("Train your panic cough", id: TrainingWindowID.value) {
            TrainingView(coordinator: coordinator)
        }
        .defaultSize(width: 400, height: 460)
    }
}
