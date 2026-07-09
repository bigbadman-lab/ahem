import AppKit
import Foundation

// TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.

/// Thread-safe in-memory diagnostic log for local debugging of notarized builds.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    struct LastDetectionDecision: Equatable {
        let recordedAt: Date
        let instantaneous: Double
        let smoothed: Double
        let threshold: Double
        let fired: Bool
        let inCooldown: Bool
        let qualifies: Bool
    }

    struct LastBrowserHideAttempt: Equatable {
        let recordedAt: Date
        let activeAppName: String
        let bundleIdentifier: String
        let matchedSupportedBrowser: Bool
        let hideCommandAttempted: Bool
        let hideCommandReturnedTrue: Bool?
        let hideSucceeded: Bool?
        let resultSummary: String
    }

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 300

    private(set) var lastDetectionDecision: LastDetectionDecision?
    private(set) var lastBrowserHideAttempt: LastBrowserHideAttempt?

    private static let lineTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    func log(_ message: String) {
        let timestamp = Self.lineTimestampFormatter.string(from: Date())
        let line = "\(timestamp) \(message)"

        lock.lock()
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()

        #if DEBUG
        print("[Diagnostics] \(message)")
        #endif
    }

    func log(category: String, _ message: String) {
        log("[\(category)] \(message)")
    }

    func recordDetectionDecision(
        instantaneous: Double,
        smoothed: Double,
        threshold: Double,
        fired: Bool,
        inCooldown: Bool,
        qualifies: Bool
    ) {
        let decision = LastDetectionDecision(
            recordedAt: Date(),
            instantaneous: instantaneous,
            smoothed: smoothed,
            threshold: threshold,
            fired: fired,
            inCooldown: inCooldown,
            qualifies: qualifies
        )

        lock.lock()
        lastDetectionDecision = decision
        lock.unlock()

        let firedLabel = fired ? "true" : "false"
        log(
            category: "Detection",
            "decision instantaneous=\(formatScore(instantaneous)) "
                + "smoothed=\(formatScore(smoothed)) "
                + "threshold=\(formatScore(threshold)) "
                + "qualifies=\(qualifies) "
                + "inCooldown=\(inCooldown) "
                + "fired=\(firedLabel)"
        )
    }

    func recordBrowserHideAttempt(_ attempt: LastBrowserHideAttempt) {
        lock.lock()
        lastBrowserHideAttempt = attempt
        lock.unlock()

        log(
            category: "BrowserHiding",
            "activeApp=\(attempt.activeAppName) "
                + "bundleID=\(attempt.bundleIdentifier) "
                + "matchedBrowser=\(attempt.matchedSupportedBrowser) "
                + "hideAttempted=\(attempt.hideCommandAttempted) "
                + "hideReturnedTrue=\(attempt.hideCommandReturnedTrue.map(String.init(describing:)) ?? "n/a") "
                + "hideSucceeded=\(attempt.hideSucceeded.map(String.init(describing:)) ?? "n/a") "
                + "result=\(attempt.resultSummary)"
        )
    }

    func recentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    @discardableResult
    func copyReportToClipboard(snapshot: DiagnosticsSnapshot, fingerprint: PanicFingerprint?) -> Bool {
        let report = makeReport(snapshot: snapshot, fingerprint: fingerprint)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(report, forType: .string)
    }

    private func makeReport(snapshot: DiagnosticsSnapshot, fingerprint: PanicFingerprint?) -> String {
        let baseReport = DiagnosticsReportService.makeReport(snapshot: snapshot)

        let fingerprintMetadata = fingerprintMetadataSection(fingerprint: fingerprint, snapshot: snapshot)
        let detectionSection = lastDetectionSection()
        let browserHideSection = lastBrowserHideSection()
        let logSection = recentLogSection()

        return """
        \(baseReport)

        \(fingerprintMetadata)

        \(detectionSection)

        \(browserHideSection)

        \(logSection)
        """
        .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func fingerprintMetadataSection(
        fingerprint: PanicFingerprint?,
        snapshot: DiagnosticsSnapshot
    ) -> String {
        guard let fingerprint else {
            return """
            === Fingerprint Metadata ===
            Exists: \(snapshot.fingerprintStored ? "yes" : "no")
            """
        }

        let created = ISO8601DateFormatter().string(from: fingerprint.createdAt)
        let featureCount = fingerprint.profileSample.envelopeBuckets.count
            + fingerprint.profileSample.bandEnergies.count
            + fingerprint.profileSample.mfccSummary.count

        return """
        === Fingerprint Metadata ===
        Exists: yes
        Version: \(fingerprint.version)
        Sample rate: \(String(format: "%.0f", fingerprint.processingSampleRate)) Hz
        Created: \(created)
        Training samples: \(fingerprint.sampleCount)
        Feature count: \(featureCount)
        Training consistency: \(String(format: "%.2f", fingerprint.trainingConsistency))
        """
    }

    private func lastDetectionSection() -> String {
        lock.lock()
        let decision = lastDetectionDecision
        lock.unlock()

        guard let decision else {
            return """
            === Last Detection Decision ===
            No detection decisions recorded yet.
            """
        }

        let recordedAt = Self.lineTimestampFormatter.string(from: decision.recordedAt)
        return """
        === Last Detection Decision ===
        Recorded: \(recordedAt)
        Instantaneous score: \(formatScore(decision.instantaneous))
        Smoothed score: \(formatScore(decision.smoothed))
        Threshold: \(formatScore(decision.threshold))
        Qualifies: \(decision.qualifies ? "yes" : "no")
        In cooldown: \(decision.inCooldown ? "yes" : "no")
        Fired: \(decision.fired ? "true" : "false")
        """
    }

    private func lastBrowserHideSection() -> String {
        lock.lock()
        let attempt = lastBrowserHideAttempt
        lock.unlock()

        guard let attempt else {
            return """
            === Last Browser Hide Attempt ===
            No browser hide attempts recorded yet.
            """
        }

        let recordedAt = Self.lineTimestampFormatter.string(from: attempt.recordedAt)
        return """
        === Last Browser Hide Attempt ===
        Recorded: \(recordedAt)
        Active app: \(attempt.activeAppName)
        Bundle ID: \(attempt.bundleIdentifier)
        Matched supported browser: \(attempt.matchedSupportedBrowser ? "yes" : "no")
        Hide command attempted: \(attempt.hideCommandAttempted ? "yes" : "no")
        hide() returned true: \(attempt.hideCommandReturnedTrue.map { $0 ? "yes" : "no" } ?? "n/a")
        Hide succeeded: \(attempt.hideSucceeded.map { $0 ? "yes" : "no" } ?? "n/a")
        Result: \(attempt.resultSummary)
        """
    }

    private func recentLogSection() -> String {
        let recent = recentLines()
        if recent.isEmpty {
            return """
            === Recent Diagnostic Log ===
            (empty)
            """
        }

        let body = recent.joined(separator: "\n")
        return """
        === Recent Diagnostic Log (\(recent.count) lines) ===
        \(body)
        """
    }

    private func formatScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
