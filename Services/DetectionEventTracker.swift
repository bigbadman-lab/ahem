import Foundation

// TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.

enum DetectionEventRejectionReason: String, Equatable {
    case scoreBelowThreshold = "score_below_threshold"
    case cooldownActive = "cooldown_active"
    case detectionPaused = "detection_paused"
    case noFingerprint = "no_fingerprint"
    case alreadyFiredThisEvent = "already_fired_this_event"
    case unknown = "unknown"
}

struct DetectionCandidateEvent: Equatable {
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
    let rejectionReason: DetectionEventRejectionReason?

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

struct DetectionEventSnapshot: Equatable {
    let active: Bool
    let maxInstantaneous: Double
    let maxSmoothed: Double
    let strictRulePassed: Bool
    let nearMatchRulePassed: Bool
    let qualifies: Bool
}

struct DetectionEventStatistics: Equatable {
    let highestInstantaneousSinceLaunch: Double
    let highestSmoothedSinceLaunch: Double
    let candidateEventCount: Int
    let firedEventCount: Int
    let rejectedEventCount: Int
    let lastCandidateEvent: DetectionCandidateEvent?
    let recentCandidateEvents: [DetectionCandidateEvent]
}

/// Tracks candidate cough/AHEM score events and decides event-level qualification.
final class DetectionEventEngine: @unchecked Sendable {
    static let eventFloor = 0.50
    static let gracePeriod: TimeInterval = 0.60

    struct ProcessResult: Equatable {
        let snapshot: DetectionEventSnapshot
        let shouldFire: Bool
        let endedEvent: DetectionCandidateEvent?
    }

    private struct InProgressEvent {
        let startTime: Date
        let threshold: Double
        let strongPeakThreshold: Double
        let nearMatchSmoothedThreshold: Double
        var lastAboveFloorTime: Date
        var maxInstantaneous: Double
        var maxSmoothed: Double
        var latestInstantaneous: Double
        var latestSmoothed: Double
        var maxInstantaneousAt: Date
        var maxSmoothedAt: Date
        var hasFired: Bool
        var cooldownBlocked: Bool
    }

    private let lock = NSLock()
    private var activeEvent: InProgressEvent?
    private var belowFloorSince: Date?

    private var highestInstantaneousSinceLaunch: Double = 0
    private var highestSmoothedSinceLaunch: Double = 0
    private var candidateEventCount = 0
    private var firedEventCount = 0
    private var rejectedEventCount = 0
    private var lastCandidateEvent: DetectionCandidateEvent?
    private var recentCandidateEvents: [DetectionCandidateEvent] = []

    private let maxRecentEvents = 3

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        activeEvent = nil
        belowFloorSince = nil
    }

    func statistics() -> DetectionEventStatistics {
        lock.lock()
        defer { lock.unlock() }
        return DetectionEventStatistics(
            highestInstantaneousSinceLaunch: highestInstantaneousSinceLaunch,
            highestSmoothedSinceLaunch: highestSmoothedSinceLaunch,
            candidateEventCount: candidateEventCount,
            firedEventCount: firedEventCount,
            rejectedEventCount: rejectedEventCount,
            lastCandidateEvent: lastCandidateEvent,
            recentCandidateEvents: recentCandidateEvents
        )
    }

    func processFrame(
        timestamp: Date,
        instantaneous: Double,
        smoothed: Double,
        threshold: Double,
        strongPeakThreshold: Double,
        nearMatchSmoothedThreshold: Double,
        passesPeakSanity: Bool,
        passesNoiseFloor: Bool,
        inCooldown: Bool,
        detectorActive: Bool
    ) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }

        if instantaneous > highestInstantaneousSinceLaunch {
            highestInstantaneousSinceLaunch = instantaneous
        }
        if smoothed > highestSmoothedSinceLaunch {
            highestSmoothedSinceLaunch = smoothed
        }

        let aboveFloor = Self.isAboveFloor(instantaneous: instantaneous, smoothed: smoothed)
        var endedEvent: DetectionCandidateEvent?

        if var event = activeEvent {
            if aboveFloor {
                belowFloorSince = nil
                updateEventPeaks(
                    &event,
                    timestamp: timestamp,
                    instantaneous: instantaneous,
                    smoothed: smoothed
                )

                let shouldFire = evaluateFire(
                    for: &event,
                    threshold: threshold,
                    strongPeakThreshold: strongPeakThreshold,
                    nearMatchSmoothedThreshold: nearMatchSmoothedThreshold,
                    passesPeakSanity: passesPeakSanity,
                    passesNoiseFloor: passesNoiseFloor,
                    inCooldown: inCooldown,
                    detectorActive: detectorActive
                )

                activeEvent = event

                return ProcessResult(
                    snapshot: snapshot(for: event),
                    shouldFire: shouldFire,
                    endedEvent: nil
                )
            }

            if belowFloorSince == nil {
                belowFloorSince = timestamp
            }

            if let belowSince = belowFloorSince,
               timestamp.timeIntervalSince(belowSince) >= Self.gracePeriod {
                endedEvent = endActiveEventLocked(event, endTime: timestamp)
                activeEvent = nil
                belowFloorSince = nil

                return ProcessResult(
                    snapshot: inactiveSnapshot(),
                    shouldFire: false,
                    endedEvent: endedEvent
                )
            }

            return ProcessResult(
                snapshot: snapshot(for: event),
                shouldFire: false,
                endedEvent: nil
            )
        }

        guard aboveFloor else {
            return ProcessResult(
                snapshot: inactiveSnapshot(),
                shouldFire: false,
                endedEvent: nil
            )
        }

        belowFloorSince = nil
        candidateEventCount += 1

        var event = InProgressEvent(
            startTime: timestamp,
            threshold: threshold,
            strongPeakThreshold: strongPeakThreshold,
            nearMatchSmoothedThreshold: nearMatchSmoothedThreshold,
            lastAboveFloorTime: timestamp,
            maxInstantaneous: instantaneous,
            maxSmoothed: smoothed,
            latestInstantaneous: instantaneous,
            latestSmoothed: smoothed,
            maxInstantaneousAt: timestamp,
            maxSmoothedAt: timestamp,
            hasFired: false,
            cooldownBlocked: false
        )

        let shouldFire = evaluateFire(
            for: &event,
            threshold: threshold,
            strongPeakThreshold: strongPeakThreshold,
            nearMatchSmoothedThreshold: nearMatchSmoothedThreshold,
            passesPeakSanity: passesPeakSanity,
            passesNoiseFloor: passesNoiseFloor,
            inCooldown: inCooldown,
            detectorActive: detectorActive
        )

        activeEvent = event

        return ProcessResult(
            snapshot: snapshot(for: event),
            shouldFire: shouldFire,
            endedEvent: nil
        )
    }

    private func evaluateFire(
        for event: inout InProgressEvent,
        threshold: Double,
        strongPeakThreshold: Double,
        nearMatchSmoothedThreshold: Double,
        passesPeakSanity: Bool,
        passesNoiseFloor: Bool,
        inCooldown: Bool,
        detectorActive: Bool
    ) -> Bool {
        let eventRules = Self.eventRules(
            for: event,
            threshold: threshold,
            strongPeakThreshold: strongPeakThreshold,
            nearMatchSmoothedThreshold: nearMatchSmoothedThreshold
        )

        if eventRules.qualifies && inCooldown && !event.hasFired {
            event.cooldownBlocked = true
        }

        let shouldFire = detectorActive
            && eventRules.qualifies
            && passesPeakSanity
            && passesNoiseFloor
            && !inCooldown
            && !event.hasFired

        if shouldFire {
            event.hasFired = true
            firedEventCount += 1
        }

        return shouldFire
    }

    func finalizeActiveEvent(reason: DetectionEventRejectionReason) -> DetectionCandidateEvent? {
        lock.lock()
        defer { lock.unlock() }

        guard let event = activeEvent else { return nil }
        let ended = endActiveEventLocked(event, endTime: Date(), forcedReason: reason)
        activeEvent = nil
        belowFloorSince = nil
        return ended
    }

    private func snapshot(for event: InProgressEvent) -> DetectionEventSnapshot {
        let rules = Self.eventRules(
            for: event,
            threshold: event.threshold,
            strongPeakThreshold: event.strongPeakThreshold,
            nearMatchSmoothedThreshold: event.nearMatchSmoothedThreshold
        )
        return DetectionEventSnapshot(
            active: true,
            maxInstantaneous: event.maxInstantaneous,
            maxSmoothed: event.maxSmoothed,
            strictRulePassed: rules.strictPassed,
            nearMatchRulePassed: rules.nearMatchPassed,
            qualifies: rules.qualifies
        )
    }

    private func inactiveSnapshot() -> DetectionEventSnapshot {
        DetectionEventSnapshot(
            active: false,
            maxInstantaneous: 0,
            maxSmoothed: 0,
            strictRulePassed: false,
            nearMatchRulePassed: false,
            qualifies: false
        )
    }

    @discardableResult
    private func endActiveEventLocked(
        _ event: InProgressEvent,
        endTime: Date,
        forcedReason: DetectionEventRejectionReason? = nil
    ) -> DetectionCandidateEvent {
        let rules = Self.eventRules(
            for: event,
            threshold: event.threshold,
            strongPeakThreshold: event.strongPeakThreshold,
            nearMatchSmoothedThreshold: event.nearMatchSmoothedThreshold
        )

        let rejection: DetectionEventRejectionReason?
        if event.hasFired {
            rejection = nil
        } else if let forcedReason {
            rejection = forcedReason
        } else if event.cooldownBlocked {
            rejection = .cooldownActive
        } else if !rules.qualifies {
            rejection = .scoreBelowThreshold
        } else {
            rejection = .unknown
        }

        let candidate = DetectionCandidateEvent(
            startTime: event.startTime,
            endTime: endTime,
            maxInstantaneous: event.maxInstantaneous,
            maxSmoothed: event.maxSmoothed,
            maxInstantaneousAt: event.maxInstantaneousAt,
            maxSmoothedAt: event.maxSmoothedAt,
            strictRulePassed: rules.strictPassed,
            nearMatchRulePassed: rules.nearMatchPassed,
            fired: event.hasFired,
            cooldownBlocked: event.cooldownBlocked,
            rejectionReason: rejection
        )

        if !event.hasFired {
            rejectedEventCount += 1
        }

        lastCandidateEvent = candidate
        recentCandidateEvents.append(candidate)
        if recentCandidateEvents.count > maxRecentEvents {
            recentCandidateEvents.removeFirst(recentCandidateEvents.count - maxRecentEvents)
        }

        return candidate
    }

    private func updateEventPeaks(
        _ event: inout InProgressEvent,
        timestamp: Date,
        instantaneous: Double,
        smoothed: Double
    ) {
        event.lastAboveFloorTime = timestamp
        event.latestInstantaneous = instantaneous
        event.latestSmoothed = smoothed

        if instantaneous > event.maxInstantaneous {
            event.maxInstantaneous = instantaneous
            event.maxInstantaneousAt = timestamp
        }
        if smoothed > event.maxSmoothed {
            event.maxSmoothed = smoothed
            event.maxSmoothedAt = timestamp
        }
    }

    private static func isAboveFloor(instantaneous: Double, smoothed: Double) -> Bool {
        instantaneous >= eventFloor || smoothed >= eventFloor
    }

    private static func isBelowFloor(instantaneous: Double, smoothed: Double) -> Bool {
        instantaneous < eventFloor && smoothed < eventFloor
    }

    private static func eventRules(
        for event: InProgressEvent,
        threshold: Double,
        strongPeakThreshold: Double,
        nearMatchSmoothedThreshold: Double
    ) -> (strictPassed: Bool, nearMatchPassed: Bool, qualifies: Bool) {
        let strictPassed = event.maxSmoothed >= threshold
        let nearMatchPassed = event.maxInstantaneous >= strongPeakThreshold
            && event.maxSmoothed >= nearMatchSmoothedThreshold
        return (strictPassed, nearMatchPassed, strictPassed || nearMatchPassed)
    }
}
