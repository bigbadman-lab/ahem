import AppKit

enum BrowserHideConfirmation: Equatable {
    case hideReturnedTrue
    case isHiddenVerified
}

enum BrowserHidingResult: Equatable {
    case hidden(bundleIdentifier: String, localizedName: String, confirmation: BrowserHideConfirmation)
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

    private static let postHideVerificationInterval: TimeInterval = 0.02
    private static let postHideVerificationAttempts = 5

    func hideActiveBrowserIfSupported() -> BrowserHidingResult {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return .noFrontmostApplication
        }

        let localizedName = frontmostApplication.localizedName ?? "Unknown"
        let bundleIdentifier = frontmostApplication.bundleIdentifier ?? "unknown"

        guard Self.supportedBrowserBundleIDs.contains(bundleIdentifier) else {
            return .notBrowser(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
        }

        let processIdentifier = frontmostApplication.processIdentifier
        let hideReturnedTrue = frontmostApplication.hide()

        if hideReturnedTrue {
            return .hidden(
                bundleIdentifier: bundleIdentifier,
                localizedName: localizedName,
                confirmation: .hideReturnedTrue
            )
        }

        if Self.isApplicationHidden(processIdentifier: processIdentifier) {
            return .hidden(
                bundleIdentifier: bundleIdentifier,
                localizedName: localizedName,
                confirmation: .isHiddenVerified
            )
        }

        for _ in 0..<Self.postHideVerificationAttempts {
            Thread.sleep(forTimeInterval: Self.postHideVerificationInterval)
            if Self.isApplicationHidden(processIdentifier: processIdentifier) {
                return .hidden(
                    bundleIdentifier: bundleIdentifier,
                    localizedName: localizedName,
                    confirmation: .isHiddenVerified
                )
            }
        }

        return .failed(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
    }

    private static func isApplicationHidden(processIdentifier: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.isHidden == true
    }
}
