import Foundation

// TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.

/// Diagnostic-only tracker for candidate cough/AHEM score events. Does not affect detection.
final class DetectionEventTracker: @unchecked Sendable {
    enum RejectionReason: String, Equatable {
        case scoreBelowThreshold = "score_below_threshold"
        case strongPeakMissing = "strong_peak_missing"
        case smoothedScoreTooLow = "smoothed_score_too_low"
        case cooldownActive = "cooldown_active"
        case detectionPaused = "detection_paused"
        case noFingerprint = "no_fingerprint"
        case unknown = "unknown"
    }

    struct CandidateEvent: Equatable {
        let startTime: Date
        let endTime: Date
        let maxInstantaneous: Double
        let maxSmoothed: Double
        let maxInstantaneousAt: Date
        let maxSmoothedAt: Date
        let strictRulePassed: Bool
        let nearMatchRulePassed: Bool
        let fired: Bool
        let cooldownBlocked: Bool
        let rejectionReason: RejectionReason?

        var duration: TimeInterval {
            endTime.timeIntervalSince(startTime)
        }
    }

    struct Observation {
        let timestamp: Date
        let instantaneous: Double
        let smoothed: Double
        let threshold: Double
        let strongPeakThreshold: Double
        let nearMatchSmoothedThreshold: Double
        let strictRulePassed: Bool
        let nearMatchRulePassed: Bool
        let qualifies: Bool
        let inCooldown: Bool
        let fired: Bool
    }

    static let observationFloor = 0.50
    static let gracePeriod: TimeInterval = 0.65

    private struct InProgressEvent {
        let startTime: Date
        let threshold: Double
        let strongPeakThreshold: Double
        let nearMatchSmoothedThreshold: Double
        var lastAboveFloorAt: Date
        var maxInstantaneous: Double
        var maxSmoothed: Double
        var maxInstantaneousAt: Date
        var maxSmoothedAt: Date
        var strictRulePassed: Bool
        var nearMatchRulePassed: Bool
        var everQualified: Bool
        var everFired: Bool
        var cooldownBlocked: Bool
    }

    private let lock = NSLock()
    private var activeEvent: InProgressEvent?
    private var belowFloorSince: Date?

    private(set) var highestInstantaneousSinceLaunch: Double = 0
    private(set) var highestSmoothedSinceLaunch: Double = 0
    private(set) var candidateEventCount = 0
    private(set) var firedEventCount = 0
    private(set) var rejectedEventCount = 0
    private(set) var lastCandidateEvent: CandidateEvent?
    private var recentCandidateEvents: [CandidateEvent] = []

    private let maxRecentEvents = 3

    @discardableResult
    func observe(_ observation: Observation) -> CandidateEvent? {
        lock.lock()
        defer { lock.unlock() }

        if observation.instantaneous > highestInstantaneousSinceLaunch {
            highestInstantaneousSinceLaunch = observation.instantaneous
        }
        if observation.smoothed > highestSmoothedSinceLaunch {
            highestSmoothedSinceLaunch = observation.smoothed
        }

        let aboveFloor = observation.instantaneous >= Self.observationFloor

        if var event = activeEvent {
            if aboveFloor {
                belowFloorSince = nil
                event.lastAboveFloorAt = observation.timestamp
                updateEventPeaks(&event, with: observation)

                if observation.strictRulePassed { event.strictRulePassed = true }
                if observation.nearMatchRulePassed { event.nearMatchRulePassed = true }
                if observation.qualifies { event.everQualified = true }
                if observation.fired { event.everFired = true }
                if observation.inCooldown && observation.qualifies { event.cooldownBlocked = true }

                activeEvent = event
                return nil
            }

            if belowFloorSince == nil {
                belowFloorSince = observation.timestamp
            }

            if let belowSince = belowFloorSince,
               observation.timestamp.timeIntervalSince(belowSince) >= Self.gracePeriod {
                return endActiveEventLocked(event, endTime: observation.timestamp)
            }
            return nil
        }

        guard aboveFloor else { return nil }

        belowFloorSince = nil
        activeEvent = InProgressEvent(
            startTime: observation.timestamp,
            threshold: observation.threshold,
            strongPeakThreshold: observation.strongPeakThreshold,
            nearMatchSmoothedThreshold: observation.nearMatchSmoothedThreshold,
            lastAboveFloorAt: observation.timestamp,
            maxInstantaneous: observation.instantaneous,
            maxSmoothed: observation.smoothed,
            maxInstantaneousAt: observation.timestamp,
            maxSmoothedAt: observation.timestamp,
            strictRulePassed: observation.strictRulePassed,
            nearMatchRulePassed: observation.nearMatchRulePassed,
            everQualified: observation.qualifies,
            everFired: observation.fired,
            cooldownBlocked: observation.inCooldown && observation.qualifies
        )
        return nil
    }

    func finalizeActiveEvent(reason: RejectionReason) -> CandidateEvent? {
        lock.lock()
        defer { lock.unlock() }

        guard let event = activeEvent else { return nil }
        return endActiveEventLocked(event, endTime: Date(), forcedReason: reason)
    }

    func snapshot() -> (
        highestInstantaneous: Double,
        highestSmoothed: Double,
        candidateEventCount: Int,
        firedEventCount: Int,
        rejectedEventCount: Int,
        lastCandidateEvent: CandidateEvent?,
        recentCandidateEvents: [CandidateEvent]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            highestInstantaneousSinceLaunch,
            highestSmoothedSinceLaunch,
            candidateEventCount,
            firedEventCount,
            rejectedEventCount,
            lastCandidateEvent,
            recentCandidateEvents
        )
    }

    @discardableResult
    private func endActiveEventLocked(
        _ event: InProgressEvent,
        endTime: Date,
        forcedReason: RejectionReason? = nil
    ) -> CandidateEvent {
        activeEvent = nil
        belowFloorSince = nil

        let rejection = forcedReason ?? rejectionReason(for: event)
        let candidate = CandidateEvent(
            startTime: event.startTime,
            endTime: endTime,
            maxInstantaneous: event.maxInstantaneous,
            maxSmoothed: event.maxSmoothed,
            maxInstantaneousAt: event.maxInstantaneousAt,
            maxSmoothedAt: event.maxSmoothedAt,
            strictRulePassed: event.strictRulePassed,
            nearMatchRulePassed: event.nearMatchRulePassed,
            fired: event.everFired,
            cooldownBlocked: event.cooldownBlocked,
            rejectionReason: event.everFired ? nil : rejection
        )

        candidateEventCount += 1
        if candidate.fired {
            firedEventCount += 1
        } else {
            rejectedEventCount += 1
        }

        lastCandidateEvent = candidate
        recentCandidateEvents.append(candidate)
        if recentCandidateEvents.count > maxRecentEvents {
            recentCandidateEvents.removeFirst(recentCandidateEvents.count - maxRecentEvents)
        }

        return candidate
    }

    private func updateEventPeaks(_ event: inout InProgressEvent, with observation: Observation) {
        if observation.instantaneous > event.maxInstantaneous {
            event.maxInstantaneous = observation.instantaneous
            event.maxInstantaneousAt = observation.timestamp
        }
        if observation.smoothed > event.maxSmoothed {
            event.maxSmoothed = observation.smoothed
            event.maxSmoothedAt = observation.timestamp
        }
    }

    private func rejectionReason(for event: InProgressEvent) -> RejectionReason {
        if event.everFired {
            return .unknown
        }

        if event.cooldownBlocked && (event.strictRulePassed || event.nearMatchRulePassed || event.everQualified) {
            return .cooldownActive
        }

        if event.everQualified {
            return .unknown
        }

        if !event.strictRulePassed && !event.nearMatchRulePassed {
            if event.maxInstantaneous < event.strongPeakThreshold
                && event.maxSmoothed < event.nearMatchSmoothedThreshold
                && event.maxSmoothed < event.threshold {
                return .scoreBelowThreshold
            }
            if event.maxInstantaneous < event.strongPeakThreshold {
                return .strongPeakMissing
            }
            if event.maxSmoothed < event.nearMatchSmoothedThreshold {
                return .smoothedScoreTooLow
            }
            if event.maxSmoothed < event.threshold {
                return .scoreBelowThreshold
            }
        }

        return .unknown
    }
}
