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
    let eventAgeMs: Double
    let belowEndThreshold: Bool
    let forcedEndDueToDuration: Bool
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
    let activeEventCount: Int
    let lastCandidateEvent: DetectionCandidateEvent?
    let recentCandidateEvents: [DetectionCandidateEvent]
}

/// Tracks candidate cough/AHEM score events and decides event-level qualification.
final class DetectionEventEngine: @unchecked Sendable {
    // Used for noise-floor updating gates (kept at 0.50 to preserve existing detection behaviour).
    static let scoreObservationFloor: Double = 0.50

    // Event segmentation thresholds (hysteresis).
    static let eventStartInstantaneousThreshold: Double = 0.68
    static let eventStartSmoothedThreshold: Double = 0.62
    static let eventEndInstantaneousThreshold: Double = 0.55
    static let eventEndSmoothedThreshold: Double = 0.55

    static let eventEndGraceMs: Double = 700
    static let maxEventDurationMs: Double = 2500

    struct ProcessResult: Equatable {
        let snapshot: DetectionEventSnapshot
        let shouldFire: Bool
        let endedEvent: DetectionCandidateEvent?
    }

    private struct InProgressEvent {
        let startTime: Date
        let mainThreshold: Double
        let strongPeakThreshold: Double
        let nearMatchSmoothedThreshold: Double

        var maxInstantaneous: Double
        var maxSmoothed: Double
        var maxInstantaneousAt: Date
        var maxSmoothedAt: Date

        var hasFired: Bool
        var cooldownBlocked: Bool
    }

    private let lock = NSLock()
    private var activeEvent: InProgressEvent?
    private var belowEndSince: Date?

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
        belowEndSince = nil
    }

    func statistics() -> DetectionEventStatistics {
        lock.lock()
        defer { lock.unlock() }

        let activeEventCount = activeEvent == nil ? 0 : 1
        return DetectionEventStatistics(
            highestInstantaneousSinceLaunch: highestInstantaneousSinceLaunch,
            highestSmoothedSinceLaunch: highestSmoothedSinceLaunch,
            candidateEventCount: candidateEventCount,
            firedEventCount: firedEventCount,
            rejectedEventCount: rejectedEventCount,
            activeEventCount: activeEventCount,
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
        detectorActive: Bool,
        fingerprintUsable: Bool
    ) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }

        let shouldProcess = detectorActive && fingerprintUsable
        guard shouldProcess else {
            return ProcessResult(
                snapshot: inactiveSnapshot(
                    forcedEndDueToDuration: false,
                    belowEndThreshold: false
                ),
                shouldFire: false,
                endedEvent: nil
            )
        }

        if instantaneous > highestInstantaneousSinceLaunch {
            highestInstantaneousSinceLaunch = instantaneous
        }
        if smoothed > highestSmoothedSinceLaunch {
            highestSmoothedSinceLaunch = smoothed
        }

        let startCandidate = instantaneous >= Self.eventStartInstantaneousThreshold
            || smoothed >= Self.eventStartSmoothedThreshold

        let belowEndThreshold = instantaneous < Self.eventEndInstantaneousThreshold
            && smoothed < Self.eventEndSmoothedThreshold

        if var event = activeEvent {
            let ageMs = timestamp.timeIntervalSince(event.startTime) * 1000
            let forcedEndDueToDuration = ageMs >= Self.maxEventDurationMs

            updatePeaks(
                &event,
                instantaneous: instantaneous,
                smoothed: smoothed,
                timestamp: timestamp
            )

            let rules = eventRules(
                maxSmoothed: event.maxSmoothed,
                maxInstantaneous: event.maxInstantaneous,
                mainThreshold: event.mainThreshold,
                strongPeakThreshold: event.strongPeakThreshold,
                nearMatchSmoothedThreshold: event.nearMatchSmoothedThreshold
            )

            if rules.qualifies && inCooldown && !event.hasFired {
                event.cooldownBlocked = true
            }

            let shouldFire = rules.qualifies
                && passesPeakSanity
                && passesNoiseFloor
                && !inCooldown
                && !event.hasFired

            if shouldFire {
                event.hasFired = true
                firedEventCount += 1
            }

            var endedEvent: DetectionCandidateEvent?
            var snapshotForcedEnd = false
            var snapshotActive = true
            var snapshotAgeMs = ageMs

            if forcedEndDueToDuration {
                endedEvent = endActiveEventLocked(
                    event,
                    endTime: timestamp,
                    forcedReason: nil
                )
                snapshotForcedEnd = true
                snapshotActive = false
            } else if belowEndThreshold {
                if belowEndSince == nil {
                    belowEndSince = timestamp
                }

                let belowAgeMs = timestamp.timeIntervalSince(belowEndSince!) * 1000
                if belowAgeMs >= Self.eventEndGraceMs {
                    endedEvent = endActiveEventLocked(
                        event,
                        endTime: timestamp,
                        forcedReason: nil
                    )
                    snapshotForcedEnd = false
                    snapshotActive = false
                } else {
                    activeEvent = event
                }
            } else {
                belowEndSince = nil
                activeEvent = event
            }

            // If we ended, activeEvent is cleared in endActiveEventLocked.
            if endedEvent == nil {
                activeEvent = event
                snapshotForcedEnd = false
            } else {
                activeEvent = nil
                belowEndSince = nil
            }

            let snapshot = DetectionEventSnapshot(
                active: snapshotActive && endedEvent == nil,
                eventAgeMs: snapshotAgeMs,
                belowEndThreshold: belowEndThreshold,
                forcedEndDueToDuration: snapshotForcedEnd,
                maxInstantaneous: event.maxInstantaneous,
                maxSmoothed: event.maxSmoothed,
                strictRulePassed: rules.strictRulePassed,
                nearMatchRulePassed: rules.nearMatchRulePassed,
                qualifies: rules.qualifies
            )

            return ProcessResult(
                snapshot: snapshot,
                shouldFire: shouldFire,
                endedEvent: endedEvent
            )
        }

        // No active event.
        guard startCandidate else {
            return ProcessResult(
                snapshot: inactiveSnapshot(
                    forcedEndDueToDuration: false,
                    belowEndThreshold: belowEndThreshold
                ),
                shouldFire: false,
                endedEvent: nil
            )
        }

        candidateEventCount += 1

        let event = InProgressEvent(
            startTime: timestamp,
            mainThreshold: threshold,
            strongPeakThreshold: strongPeakThreshold,
            nearMatchSmoothedThreshold: nearMatchSmoothedThreshold,
            maxInstantaneous: instantaneous,
            maxSmoothed: smoothed,
            maxInstantaneousAt: timestamp,
            maxSmoothedAt: timestamp,
            hasFired: false,
            cooldownBlocked: false
        )

        let rules = eventRules(
            maxSmoothed: event.maxSmoothed,
            maxInstantaneous: event.maxInstantaneous,
            mainThreshold: event.mainThreshold,
            strongPeakThreshold: event.strongPeakThreshold,
            nearMatchSmoothedThreshold: event.nearMatchSmoothedThreshold
        )

        let shouldFire = rules.qualifies
            && passesPeakSanity
            && passesNoiseFloor
            && !inCooldown
            && !event.hasFired

        var storedEvent = event
        if rules.qualifies && inCooldown && !storedEvent.hasFired {
            storedEvent.cooldownBlocked = true
        }
        if shouldFire {
            storedEvent.hasFired = true
            firedEventCount += 1
        }

        activeEvent = storedEvent

        let snapshot = DetectionEventSnapshot(
            active: true,
            eventAgeMs: 0,
            belowEndThreshold: belowEndThreshold,
            forcedEndDueToDuration: false,
            maxInstantaneous: storedEvent.maxInstantaneous,
            maxSmoothed: storedEvent.maxSmoothed,
            strictRulePassed: rules.strictRulePassed,
            nearMatchRulePassed: rules.nearMatchRulePassed,
            qualifies: rules.qualifies
        )

        return ProcessResult(
            snapshot: snapshot,
            shouldFire: shouldFire,
            endedEvent: nil
        )
    }

    func finalizeActiveEvent(reason: DetectionEventRejectionReason) -> DetectionCandidateEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard let event = activeEvent else { return nil }

        // Force-close with explicit reason.
        let ended = endActiveEventLocked(event, endTime: Date(), forcedReason: reason)
        activeEvent = nil
        belowEndSince = nil
        return ended
    }

    private func updatePeaks(
        _ event: inout InProgressEvent,
        instantaneous: Double,
        smoothed: Double,
        timestamp: Date
    ) {
        if instantaneous > event.maxInstantaneous {
            event.maxInstantaneous = instantaneous
            event.maxInstantaneousAt = timestamp
        }
        if smoothed > event.maxSmoothed {
            event.maxSmoothed = smoothed
            event.maxSmoothedAt = timestamp
        }
    }

    private func eventRules(
        maxSmoothed: Double,
        maxInstantaneous: Double,
        mainThreshold: Double,
        strongPeakThreshold: Double,
        nearMatchSmoothedThreshold: Double
    ) -> (strictRulePassed: Bool, nearMatchRulePassed: Bool, qualifies: Bool) {
        let strictRulePassed = maxSmoothed >= mainThreshold
        let nearMatchRulePassed = maxInstantaneous >= strongPeakThreshold
            && maxSmoothed >= nearMatchSmoothedThreshold
        return (strictRulePassed, nearMatchRulePassed, strictRulePassed || nearMatchRulePassed)
    }

    private func inactiveSnapshot(
        forcedEndDueToDuration: Bool,
        belowEndThreshold: Bool
    ) -> DetectionEventSnapshot {
        DetectionEventSnapshot(
            active: false,
            eventAgeMs: 0,
            belowEndThreshold: belowEndThreshold,
            forcedEndDueToDuration: forcedEndDueToDuration,
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
        forcedReason: DetectionEventRejectionReason?
    ) -> DetectionCandidateEvent {
        let rules = eventRules(
            maxSmoothed: event.maxSmoothed,
            maxInstantaneous: event.maxInstantaneous,
            mainThreshold: event.mainThreshold,
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
            strictRulePassed: rules.strictRulePassed,
            nearMatchRulePassed: rules.nearMatchRulePassed,
            fired: event.hasFired,
            cooldownBlocked: event.cooldownBlocked,
            rejectionReason: event.hasFired ? nil : rejection
        )

        candidateEventCount += 0 // explicit: already incremented on start
        if event.hasFired {
            // keep fired counters already incremented on fire
        } else {
            rejectedEventCount += 1
        }

        lastCandidateEvent = candidate
        recentCandidateEvents.append(candidate)
        if recentCandidateEvents.count > maxRecentEvents {
            recentCandidateEvents.removeFirst(recentCandidateEvents.count - maxRecentEvents)
        }

        activeEvent = nil
        belowEndSince = nil

        return candidate
    }
}

