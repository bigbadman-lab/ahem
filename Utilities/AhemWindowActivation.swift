import AppKit
import SwiftUI

/// Brings Ahem's own windows forward without introducing a Dock icon.
///
/// Menu-bar (`LSUIElement` / `.accessory`) apps lose frontmost status unless we
/// explicitly activate and order windows after SwiftUI creates them.
enum AhemWindowActivation {
    /// Preferred titles for app-owned setup windows (partial, case-insensitive match).
    static let setupWindowTitleHints = [
        "Welcome to Ahem",
        "Train your cough",
        "Preferences",
        "About Ahem"
    ]

    @MainActor
    static func bringAppWindowsForward(preferredTitleHint: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        // SwiftUI `openWindow` may create the NSWindow on a later run-loop turn.
        DispatchQueue.main.async {
            orderMatchingWindowsFront(preferredTitleHint: preferredTitleHint)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            orderMatchingWindowsFront(preferredTitleHint: preferredTitleHint)
        }
    }

    @MainActor
    private static func orderMatchingWindowsFront(preferredTitleHint: String?) {
        let visible = NSApp.windows.filter { window in
            window.isVisible
                && !window.isSheet
                && window.frame.width > 1
                && window.frame.height > 1
        }

        let hints: [String]
        if let preferredTitleHint, !preferredTitleHint.isEmpty {
            hints = [preferredTitleHint] + setupWindowTitleHints
        } else {
            hints = setupWindowTitleHints
        }

        let preferred = visible.first { window in
            hints.contains { window.title.localizedCaseInsensitiveContains($0) }
        }

        let targets = preferred.map { [$0] } ?? visible.filter { window in
            setupWindowTitleHints.contains { window.title.localizedCaseInsensitiveContains($0) }
        }

        for window in targets {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        if targets.isEmpty, let fallback = visible.last {
            fallback.makeKeyAndOrderFront(nil)
            fallback.orderFrontRegardless()
        }
    }
}

extension View {
    /// Activates Ahem and keeps this window in front after it appears (menu-bar apps).
    func keepAhemWindowInFront(titleHint: String) -> some View {
        onAppear {
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: titleHint)
        }
    }
}
