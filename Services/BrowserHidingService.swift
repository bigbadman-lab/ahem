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
        DiagnosticsLog.shared.log(category: "BrowserHiding", "hide requested — checking frontmost application")

        #if DEBUG
        print("[BrowserHiding] Hide requested — checking frontmost application")
        #endif

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            DiagnosticsLog.shared.log(category: "BrowserHiding", "no frontmost application detected")
            #if DEBUG
            print("[BrowserHiding] No frontmost application")
            #endif
            return .noFrontmostApplication
        }

        let localizedName = frontmostApplication.localizedName ?? "Unknown"
        let bundleIdentifier = frontmostApplication.bundleIdentifier ?? "unknown"

        DiagnosticsLog.shared.log(
            category: "BrowserHiding",
            "active application detected — name=\(localizedName), bundleID=\(bundleIdentifier)"
        )

        #if DEBUG
        print(
            "[BrowserHiding] Frontmost app: \(localizedName) "
                + "(bundleID: \(bundleIdentifier))"
        )
        #endif

        let isSupportedBrowser = Self.supportedBrowserBundleIDs.contains(bundleIdentifier)
        DiagnosticsLog.shared.log(
            category: "BrowserHiding",
            "browser match result — matched=\(isSupportedBrowser)"
        )

        guard isSupportedBrowser else {
            #if DEBUG
            print(
                "[BrowserHiding] Not a supported browser — "
                    + "supported=\(Self.supportedBrowserBundleIDs.sorted().joined(separator: ", "))"
            )
            #endif
            return .notBrowser(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
        }

        DiagnosticsLog.shared.log(category: "BrowserHiding", "supported browser confirmed — sending hide() command")

        #if DEBUG
        print("[BrowserHiding] Supported browser confirmed — attempting hide()")
        #endif

        let processIdentifier = frontmostApplication.processIdentifier
        let hideReturnedTrue = frontmostApplication.hide()

        DiagnosticsLog.shared.log(
            category: "BrowserHiding",
            "hide command sent — hide() returned \(hideReturnedTrue)"
        )

        #if DEBUG
        print("[BrowserHiding] hide() returned \(hideReturnedTrue)")
        #endif

        if hideReturnedTrue {
            DiagnosticsLog.shared.log(category: "BrowserHiding", "hide command result — succeeded via hide() return value")
            #if DEBUG
            print("[BrowserHiding] Hide succeeded via hide() return value")
            #endif
            return .hidden(
                bundleIdentifier: bundleIdentifier,
                localizedName: localizedName,
                confirmation: .hideReturnedTrue
            )
        }

        if Self.isApplicationHidden(processIdentifier: processIdentifier) {
            DiagnosticsLog.shared.log(category: "BrowserHiding", "hide command result — succeeded, verified via isHidden")
            #if DEBUG
            print("[BrowserHiding] Hide succeeded — verified via isHidden")
            #endif
            return .hidden(
                bundleIdentifier: bundleIdentifier,
                localizedName: localizedName,
                confirmation: .isHiddenVerified
            )
        }

        for attempt in 0..<Self.postHideVerificationAttempts {
            Thread.sleep(forTimeInterval: Self.postHideVerificationInterval)
            if Self.isApplicationHidden(processIdentifier: processIdentifier) {
                DiagnosticsLog.shared.log(
                    category: "BrowserHiding",
                    "hide command result — succeeded, verified via isHidden after \(attempt + 1) poll(s)"
                )
                #if DEBUG
                print(
                    "[BrowserHiding] Hide succeeded — verified via isHidden "
                        + "after \(attempt + 1) polling attempt(s)"
                )
                #endif
                return .hidden(
                    bundleIdentifier: bundleIdentifier,
                    localizedName: localizedName,
                    confirmation: .isHiddenVerified
                )
            }
        }

        DiagnosticsLog.shared.log(category: "BrowserHiding", "hide command result — failed, browser still visible")
        #if DEBUG
        print("[BrowserHiding] Hide failed — browser still visible after verification")
        #endif
        return .failed(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
    }

    private static func isApplicationHidden(processIdentifier: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.isHidden == true
    }
}
