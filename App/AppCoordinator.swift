import AppKit
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let appState: AppState
    private var didStart = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
