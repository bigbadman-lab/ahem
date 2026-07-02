import SwiftUI

@main
struct AhemApp: App {
    private let coordinator = AppCoordinator()

    init() {
        coordinator.start()
    }

    var body: some Scene {
        MenuBarExtra("Ahem", systemImage: "waveform") {
            MenuBarView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)
    }
}
