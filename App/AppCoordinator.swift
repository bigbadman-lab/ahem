import AppKit

@MainActor
final class AppCoordinator {
    func start() {
        NSApp.setActivationPolicy(.accessory)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
