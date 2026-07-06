import AppKit

enum BrowserHidingResult: Equatable {
    case hidden(bundleIdentifier: String, localizedName: String)
    case notBrowser(bundleIdentifier: String, localizedName: String)
    case noFrontmostApplication
    case failed(bundleIdentifier: String, localizedName: String)
}

struct BrowserHidingService {
    static let supportedBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
    ]

    func hideActiveBrowserIfSupported() -> BrowserHidingResult {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return .noFrontmostApplication
        }

        let localizedName = frontmostApplication.localizedName ?? "Unknown"
        let bundleIdentifier = frontmostApplication.bundleIdentifier ?? "unknown"

        guard Self.supportedBrowserBundleIDs.contains(bundleIdentifier) else {
            return .notBrowser(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
        }

        if frontmostApplication.hide() {
            return .hidden(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
        }

        return .failed(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
    }
}
