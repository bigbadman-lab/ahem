import AppKit
import AVFoundation
import Foundation
import Security

// TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.

struct DiagnosticsSnapshot {
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let executablePath: String
    let bundlePath: String
    let installLocation: String
    let buildConfiguration: String
    let entitlementAudioInput: String
    let entitlementAppSandbox: String
    let entitlementGetTaskAllow: String
    let microphonePermission: String
    let microphoneUsageDescriptionPresent: Bool
    let microphoneUsageDescription: String?
    let fingerprintStored: Bool
    let fingerprintVersion: String
    let fingerprintConsistency: String
    let appStatus: String
    let audioCaptureActive: Bool
    let panicDetectorAttached: Bool
    let detectionPaused: Bool
    let frontmostAppName: String
    let frontmostAppBundleID: String
    let frontmostIsSupportedBrowser: Bool
    let supportedBrowserBundleIDs: [String]
}

enum DiagnosticsReportService {
    static func makeReport(snapshot: DiagnosticsSnapshot) -> String {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let usageDescriptionLine: String
        if snapshot.microphoneUsageDescriptionPresent,
           let value = snapshot.microphoneUsageDescription {
            usageDescriptionLine = "NSMicrophoneUsageDescription: \"\(value)\""
        } else {
            usageDescriptionLine = "NSMicrophoneUsageDescription: MISSING"
        }

        let supportedBrowsers = snapshot.supportedBrowserBundleIDs.joined(separator: "\n  ")

        return """
        Ahem Diagnostics Report
        Generated: \(generatedAt)

        === App ===
        Version: \(snapshot.appVersion) (\(snapshot.buildNumber))
        Bundle identifier: \(snapshot.bundleIdentifier)
        Build configuration: \(snapshot.buildConfiguration)
        Bundle path: \(snapshot.bundlePath)
        Executable path: \(snapshot.executablePath)
        Install location: \(snapshot.installLocation)

        === Entitlements (runtime codesign) ===
        com.apple.security.device.audio-input: \(snapshot.entitlementAudioInput)
        com.apple.security.app-sandbox: \(snapshot.entitlementAppSandbox)
        com.apple.security.get-task-allow: \(snapshot.entitlementGetTaskAllow)

        === Microphone ===
        AVAudioApplication.recordPermission: \(snapshot.microphonePermission)
        NSMicrophoneUsageDescription present: \(snapshot.microphoneUsageDescriptionPresent ? "yes" : "no")
        \(usageDescriptionLine)

        === Fingerprint ===
        Stored: \(snapshot.fingerprintStored ? "yes" : "no")
        Version: \(snapshot.fingerprintVersion)
        Consistency: \(snapshot.fingerprintConsistency)

        === Runtime State ===
        App status: \(snapshot.appStatus)
        Audio capture active: \(snapshot.audioCaptureActive ? "yes" : "no")
        Panic detector attached: \(snapshot.panicDetectorAttached ? "yes" : "no")
        Detection paused: \(snapshot.detectionPaused ? "yes" : "no")

        === Frontmost App ===
        Name: \(snapshot.frontmostAppName)
        Bundle ID: \(snapshot.frontmostAppBundleID)
        Recognised supported browser: \(snapshot.frontmostIsSupportedBrowser ? "yes" : "no")

        === Supported Browser Bundle IDs ===
          \(supportedBrowsers)
        """
    }

    @discardableResult
    static func copyToClipboard(_ report: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(report, forType: .string)
    }

    static func buildConfigurationLabel() -> String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    static func installLocationLabel(bundlePath: String) -> String {
        if bundlePath.contains("/DerivedData/") {
            return "DerivedData"
        }
        if bundlePath.hasPrefix("/Applications/") {
            return "/Applications"
        }
        return "other"
    }

    static func microphonePermissionLabel() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            return "undetermined"
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        @unknown default:
            return "unknown"
        }
    }

    static func entitlementValue(_ entitlements: [String: Any]?, key: String) -> String {
        guard let entitlements else { return "unavailable" }
        guard let value = entitlements[key] else { return "absent" }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        return String(describing: value)
    }

    static func currentProcessEntitlements() -> [String: Any]? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return nil }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess,
              let information = information as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return nil
        }
        return entitlements
    }

    static func appStatusLabel(_ status: AppStatus) -> String {
        switch status {
        case .starting:
            return "starting"
        case .microphonePermissionNeeded:
            return "microphonePermissionNeeded"
        case .listening:
            return "listening"
        case .paused:
            return "paused"
        case .microphonePermissionDenied:
            return "microphonePermissionDenied"
        case .audioError(let message):
            return "audioError(\(message))"
        case .needsTraining:
            return "needsTraining"
        case .training(let sample, let total):
            return "training(sample: \(sample)/\(total))"
        case .trainingComplete:
            return "trainingComplete"
        case .trainingFailed(let message):
            return "trainingFailed(\(message))"
        case .panicDetected:
            return "panicDetected"
        }
    }
}
