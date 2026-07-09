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
        let strongPeakThreshold: Double
        let nearMatchSmoothedThreshold: Double
        let strictRulePassed: Bool
        let nearMatchRulePassed: Bool
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

    private var eventStatistics = DetectionEventStatistics(
        highestInstantaneousSinceLaunch: 0,
        highestSmoothedSinceLaunch: 0,
        candidateEventCount: 0,
        firedEventCount: 0,
        rejectedEventCount: 0,
        lastCandidateEvent: nil,
        recentCandidateEvents: []
    )

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
        strongPeakThreshold: Double,
        nearMatchSmoothedThreshold: Double,
        strictRulePassed: Bool,
        nearMatchRulePassed: Bool,
        eventActive: Bool,
        eventMaxInstantaneous: Double,
        eventMaxSmoothed: Double,
        eventStrictRulePassed: Bool,
        eventNearMatchRulePassed: Bool,
        qualifies: Bool,
        inCooldown: Bool,
        fired: Bool,
        eventStatistics: DetectionEventStatistics
    ) {
        let decision = LastDetectionDecision(
            recordedAt: Date(),
            instantaneous: instantaneous,
            smoothed: smoothed,
            threshold: threshold,
            strongPeakThreshold: strongPeakThreshold,
            nearMatchSmoothedThreshold: nearMatchSmoothedThreshold,
            strictRulePassed: strictRulePassed,
            nearMatchRulePassed: nearMatchRulePassed,
            fired: fired,
            inCooldown: inCooldown,
            qualifies: qualifies
        )

        lock.lock()
        lastDetectionDecision = decision
        self.eventStatistics = eventStatistics
        lock.unlock()

        log(
            category: "Detection",
            "decision instantaneous=\(formatScore(instantaneous)) "
                + "smoothed=\(formatScore(smoothed)) "
                + "threshold=\(formatScore(threshold)) "
                + "strongPeakThreshold=\(formatScore(strongPeakThreshold)) "
                + "nearMatchSmoothedThreshold=\(formatScore(nearMatchSmoothedThreshold)) "
                + "strictRulePassed=\(strictRulePassed) "
                + "nearMatchRulePassed=\(nearMatchRulePassed) "
                + "eventActive=\(eventActive) "
                + "eventMaxInstantaneous=\(formatScore(eventMaxInstantaneous)) "
                + "eventMaxSmoothed=\(formatScore(eventMaxSmoothed)) "
                + "eventStrictRulePassed=\(eventStrictRulePassed) "
                + "eventNearMatchRulePassed=\(eventNearMatchRulePassed) "
                + "qualifies=\(qualifies) "
                + "inCooldown=\(inCooldown) "
                + "fired=\(fired)"
        )
    }

    func updateDetectionEventStatistics(_ statistics: DetectionEventStatistics) {
        lock.lock()
        eventStatistics = statistics
        lock.unlock()
    }

    func recordDetectionEventEnded(_ event: DetectionCandidateEvent) {
        logDetectionEventEnded(event)
    }

    func finalizeActiveDetectionEvent(reason: DetectionEventRejectionReason) {
        // Retained for API compatibility; PanicDetector finalizes via its own engine.
        _ = reason
    }

    private func logDetectionEventEnded(_ event: DetectionCandidateEvent) {
        let rejection = event.rejectionReason?.rawValue ?? "none"
        log(
            category: "DetectionEvent",
            "ended duration=\(String(format: "%.2f", event.duration))s "
                + "maxInstantaneous=\(formatScore(event.maxInstantaneous)) "
                + "maxSmoothed=\(formatScore(event.maxSmoothed)) "
                + "strictEventRulePassed=\(event.strictRulePassed) "
                + "nearMatchEventRulePassed=\(event.nearMatchRulePassed) "
                + "fired=\(event.fired) "
                + "cooldownBlocked=\(event.cooldownBlocked) "
                + "rejectionReason=\(rejection)"
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
        let eventSection = detectionEventSection()
        let browserHideSection = lastBrowserHideSection()
        let logSection = recentLogSection()

        return """
        \(baseReport)

        \(fingerprintMetadata)

        \(detectionSection)

        \(eventSection)

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
        Main threshold: \(formatScore(decision.threshold))
        Strong peak threshold: \(formatScore(decision.strongPeakThreshold))
        Near-match smoothed threshold: \(formatScore(decision.nearMatchSmoothedThreshold))
        Strict rule passed: \(decision.strictRulePassed ? "true" : "false")
        Near-match rule passed: \(decision.nearMatchRulePassed ? "true" : "false")
        Qualifies: \(decision.qualifies ? "yes" : "no")
        In cooldown: \(decision.inCooldown ? "yes" : "no")
        Fired: \(decision.fired ? "true" : "false")
        """
    }

    private func detectionEventSection() -> String {
        lock.lock()
        let stats = eventStatistics
        lock.unlock()

        var sections: [String] = [
            """
            === Detection Event Statistics ===
            Highest instantaneous since launch: \(formatScore(stats.highestInstantaneousSinceLaunch))
            Highest smoothed since launch: \(formatScore(stats.highestSmoothedSinceLaunch))
            Candidate events observed: \(stats.candidateEventCount)
            Fired events: \(stats.firedEventCount)
            Rejected candidate events: \(stats.rejectedEventCount)
            """
        ]

        if let last = stats.lastCandidateEvent {
            sections.append(candidateEventSummary(last, title: "=== Last Detection Candidate Event ==="))
        } else {
            sections.append("""
            === Last Detection Candidate Event ===
            No candidate events recorded yet.
            """)
        }

        if stats.recentCandidateEvents.isEmpty {
            sections.append("""
            === Recent Candidate Events (last 3) ===
            (none)
            """)
        } else {
            let summaries = stats.recentCandidateEvents.enumerated().map { index, event in
                candidateEventSummary(event, title: "--- Event \(index + 1) ---")
            }
            sections.append("""
            === Recent Candidate Events (last 3) ===
            \(summaries.joined(separator: "\n\n"))
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    private func candidateEventSummary(
        _ event: DetectionCandidateEvent,
        title: String
    ) -> String {
        let rejection = event.rejectionReason?.rawValue ?? "none"
        return """
        \(title)
        Start: \(Self.lineTimestampFormatter.string(from: event.startTime))
        End: \(Self.lineTimestampFormatter.string(from: event.endTime))
        Duration: \(String(format: "%.2f", event.duration))s
        Max instantaneous: \(formatScore(event.maxInstantaneous)) at \(Self.lineTimestampFormatter.string(from: event.maxInstantaneousAt))
        Max smoothed: \(formatScore(event.maxSmoothed)) at \(Self.lineTimestampFormatter.string(from: event.maxSmoothedAt))
        Strict event rule passed: \(event.strictRulePassed ? "true" : "false")
        Near-match event rule passed: \(event.nearMatchRulePassed ? "true" : "false")
        Fired: \(event.fired ? "true" : "false")
        Cooldown blocked: \(event.cooldownBlocked ? "true" : "false")
        Rejection reason: \(rejection)
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
