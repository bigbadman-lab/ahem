import AVFoundation
import Foundation

final class PanicDetector {
    struct Configuration {
        let threshold: Double
        /// Instantaneous score floor for the strong-peak near-match firing rule.
        let strongPeakThreshold: Double
        /// Smoothed score floor for the strong-peak near-match firing rule.
        let nearMatchSmoothedThreshold: Double
        let cooldownDuration: TimeInterval
        let windowDuration: TimeInterval
        let analysisInterval: TimeInterval
        let confidenceLogInterval: TimeInterval
        let confidenceHistorySize: Int
        let peakSanityMinimumSimilarity: Double
        let noiseFloorMultiplier: Double
        let noiseFloorHistorySize: Int

        static let defaultAnalysisIntervalSeconds: TimeInterval = 0.125
        /// At 16 kHz processing, `defaultAnalysisIntervalSeconds` equals 2,000 samples per hop.

        static let `default` = Configuration(
            threshold: 0.78,
            strongPeakThreshold: 0.79,
            nearMatchSmoothedThreshold: 0.72,
            cooldownDuration: 2.5,
            windowDuration: 0.75,
            analysisInterval: defaultAnalysisIntervalSeconds,
            confidenceLogInterval: 3.0,
            confidenceHistorySize: 4,
            peakSanityMinimumSimilarity: 0.40,
            noiseFloorMultiplier: 4.0,
            noiseFloorHistorySize: 20
        )
    }

    var onMatch: ((PanicDetectionResult) -> Void)?

    private let fingerprint: PanicFingerprint
    private let config: Configuration
    private let fingerprintService = PanicFingerprintService()
    private let eventEngine = DetectionEventEngine()
    private let stateLock = NSLock()

    private var rollingWindow: DetectionRollingWindow?
    private var lastDetectionTime: Date?
    private var lastConfidenceLogTime: Date?
    private var isActive = false
    private var confidenceHistory: [Double] = []
    private var noiseFloorRMS: Double = PanicFingerprintService.minimumRMS
    private var noiseFloorHistory: [Double] = []

    init(fingerprint: PanicFingerprint, configuration: Configuration = .default) {
        self.fingerprint = fingerprint
        self.config = configuration
    }

    func start(sampleRate: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard sampleRate.isFinite, sampleRate > 0 else {
            #if DEBUG
            print("[Detection] Start ignored — invalid sample rate")
            #endif
            return
        }

        if isActive {
            #if DEBUG
            print("[Detection] Already active — start ignored")
            #endif
            return
        }

        rollingWindow = DetectionRollingWindow(
            sampleRate: sampleRate,
            windowDuration: config.windowDuration,
            analysisInterval: config.analysisInterval
        ) { [weak self] features in
            self?.evaluate(features)
        }
        isActive = true
        lastDetectionTime = nil
        lastConfidenceLogTime = nil
        confidenceHistory.removeAll(keepingCapacity: true)
        noiseFloorRMS = PanicFingerprintService.minimumRMS
        noiseFloorHistory.removeAll(keepingCapacity: true)
        eventEngine.reset()

        #if DEBUG
        let analysisIntervalMs = Int(config.analysisInterval * 1000)
        let rollingWindowMs = Int(config.windowDuration * 1000)
        print("[Detection] Analysis interval: \(analysisIntervalMs) ms")
        print("[Detection] Rolling window: \(rollingWindowMs) ms")
        print("[Detection] Threshold: \(String(format: "%.2f", config.threshold))")
        print(
            "[Detection] Detection resumed "
                + "(version: \(fingerprint.version), "
                + "fingerprintRate=\(String(format: "%.0f", fingerprint.processingSampleRate)), "
                + "processingRate=\(String(format: "%.0f", sampleRate)), "
                + "threshold: \(config.threshold), "
                + "cooldown: \(config.cooldownDuration)s, smoothing: \(config.confidenceHistorySize))"
        )
        #endif
    }

    func stop() {
        let windowToReset: DetectionRollingWindow?

        stateLock.lock()
        guard isActive || rollingWindow != nil else {
            stateLock.unlock()
            #if DEBUG
            print("[Detection] Already stopped — stop ignored")
            #endif
            return
        }

        windowToReset = rollingWindow
        rollingWindow = nil
        isActive = false
        confidenceHistory.removeAll(keepingCapacity: true)
        noiseFloorHistory.removeAll(keepingCapacity: true)
        noiseFloorRMS = PanicFingerprintService.minimumRMS
        stateLock.unlock()

        windowToReset?.reset()

        _ = eventEngine.finalizeActiveEvent(reason: .detectionPaused)

        #if DEBUG
        print("[Detection] Detection paused")
        #endif
    }

    func process(buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let window = rollingWindow
        let active = isActive
        stateLock.unlock()

        guard active, let window else { return }
        window.append(buffer: buffer)
    }

    private func evaluate(_ live: SampleFeatures) {
        guard fingerprintService.isUsableSample(live) else {
            stateLock.lock()
            confidenceHistory.removeAll(keepingCapacity: true)
            stateLock.unlock()
            return
        }

        guard let breakdown = fingerprintService.computeBlendedConfidence(live: live, fingerprint: fingerprint) else {
            stateLock.lock()
            confidenceHistory.removeAll(keepingCapacity: true)
            stateLock.unlock()
            return
        }

        stateLock.lock()
        confidenceHistory.append(breakdown.final)
        if confidenceHistory.count > config.confidenceHistorySize {
            confidenceHistory.removeFirst(confidenceHistory.count - config.confidenceHistorySize)
        }
        let smoothedConfidence = PanicFingerprintService.clampScore(
            confidenceHistory.reduce(0, +) / Double(confidenceHistory.count)
        )
        let currentNoiseFloor = noiseFloorRMS
        let detectorActive = isActive
        let inCooldown: Bool
        if let lastDetectionTime {
            inCooldown = Date().timeIntervalSince(lastDetectionTime) < config.cooldownDuration
        } else {
            inCooldown = false
        }
        stateLock.unlock()

        let passesPeakSanity = fingerprintService.passesPeakSanityCheck(
            live: live,
            fingerprint: fingerprint,
            minimumSimilarity: config.peakSanityMinimumSimilarity
        )
        let passesNoiseFloor = live.rms >= currentNoiseFloor * config.noiseFloorMultiplier

        let aboveEventFloor = breakdown.final >= DetectionEventEngine.scoreObservationFloor
            || smoothedConfidence >= DetectionEventEngine.scoreObservationFloor
        if !aboveEventFloor {
            updateNoiseFloor(with: live.rms)
        }

        let now = Date()
        let eventResult = eventEngine.processFrame(
            timestamp: now,
            instantaneous: breakdown.final,
            smoothed: smoothedConfidence,
            threshold: config.threshold,
            strongPeakThreshold: config.strongPeakThreshold,
            nearMatchSmoothedThreshold: config.nearMatchSmoothedThreshold,
            passesPeakSanity: passesPeakSanity,
            passesNoiseFloor: passesNoiseFloor,
            inCooldown: inCooldown,
            detectorActive: detectorActive,
            fingerprintUsable: true
        )

        let eventSnapshot = eventResult.snapshot
        let eventQualifiesWithGates = eventSnapshot.qualifies
            && passesPeakSanity
            && passesNoiseFloor
        let fired = eventResult.shouldFire

        logAnalysisIfNeeded(
            breakdown: breakdown,
            smoothed: smoothedConfidence,
            threshold: config.threshold,
            noiseFloor: currentNoiseFloor,
            passesPeakSanity: passesPeakSanity,
            passesNoiseFloor: passesNoiseFloor,
            qualifies: eventQualifiesWithGates,
            fired: fired
        )

        if inCooldown, eventQualifiesWithGates, !fired {
            #if DEBUG
            print(
                "[Detection] Cooldown active — suppressing event match "
                    + formatDetectionSummary(
                        breakdown: breakdown,
                        smoothed: smoothedConfidence,
                        threshold: config.threshold,
                        fired: false
                    )
            )
            #endif
        }

        guard fired else { return }

        stateLock.lock()
        lastDetectionTime = Date()
        confidenceHistory.removeAll(keepingCapacity: true)
        stateLock.unlock()

        let firedVia = eventSnapshot.firedVia ?? .none
        let ruleLabel: String
        switch firedVia {
        case .strictEvent:
            ruleLabel = "strict event"
        case .nearMatchEvent:
            ruleLabel = "near-match event"
        case .peakFingerprint:
            ruleLabel = "peak fingerprint"
        case .none:
            ruleLabel = "unknown"
        }

        #if DEBUG
        let analysisIntervalMs = Int(config.analysisInterval * 1000)
        print("[Detection] Fired")
        print("score: \(String(format: "%.3f", breakdown.final))")
        print("threshold: \(String(format: "%.3f", config.threshold))")
        print("analysisIntervalMs: \(analysisIntervalMs)")
        print(
            "[Detection] Detection event emitted via \(ruleLabel) (firedVia=\(firedVia.rawValue)) "
                + formatDetectionSummary(
                    breakdown: breakdown,
                    smoothed: smoothedConfidence,
                    threshold: config.threshold,
                    fired: true
                )
                + " eventMaxInstantaneous=\(formatConfidence(eventSnapshot.maxInstantaneous))"
                + " eventMaxSmoothed=\(formatConfidence(eventSnapshot.maxSmoothed))"
        )
        #endif

        let result = PanicDetectionResult(
            confidence: breakdown.final,
            isMatch: true,
            timestamp: now
        )

        DispatchQueue.main.async { [weak self] in
            self?.onMatch?(result)
        }
    }

    private func updateNoiseFloor(with rms: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }

        noiseFloorHistory.append(rms)
        if noiseFloorHistory.count > config.noiseFloorHistorySize {
            noiseFloorHistory.removeFirst(noiseFloorHistory.count - config.noiseFloorHistorySize)
        }

        let average = noiseFloorHistory.reduce(0, +) / Double(noiseFloorHistory.count)
        noiseFloorRMS = max(PanicFingerprintService.minimumRMS, average)
    }

    private func logAnalysisIfNeeded(
        breakdown: DetectionConfidenceBreakdown,
        smoothed: Double,
        threshold: Double,
        noiseFloor: Double,
        passesPeakSanity: Bool,
        passesNoiseFloor: Bool,
        qualifies: Bool,
        fired: Bool
    ) {
        #if DEBUG
        let now = Date()
        if let lastConfidenceLogTime,
           now.timeIntervalSince(lastConfidenceLogTime) < config.confidenceLogInterval {
            return
        }

        stateLock.lock()
        lastConfidenceLogTime = now
        stateLock.unlock()

        print(
            "[Detection] instantaneous: \(formatConfidence(breakdown.final)), "
                + "smoothed: \(formatConfidence(smoothed)), "
                + "threshold: \(formatConfidence(threshold)), "
                + "heuristic: \(formatConfidence(breakdown.heuristic)), "
                + "spectral: \(formatConfidence(breakdown.spectral)), "
                + "peakSanity: \(passesPeakSanity), "
                + "noiseFloorPass: \(passesNoiseFloor), "
                + "qualifies: \(qualifies), "
                + "fired: \(fired), "
                + "noiseFloorRMS: \(String(format: "%.4f", noiseFloor))"
        )

        if breakdown.spectralRaw != breakdown.spectral {
            print(
                "[Detection] spectral raw: \(formatConfidence(breakdown.spectralRaw)), "
                    + "calibrated: \(formatConfidence(breakdown.spectral))"
            )
        }
        #endif
    }

    private func formatDetectionSummary(
        breakdown: DetectionConfidenceBreakdown,
        smoothed: Double,
        threshold: Double,
        fired: Bool
    ) -> String {
        "(heuristic: \(formatConfidence(breakdown.heuristic)), "
            + "spectral: \(formatConfidence(breakdown.spectral)), "
            + "final: \(formatConfidence(breakdown.final)), "
            + "smoothed: \(formatConfidence(smoothed)), "
            + "threshold: \(formatConfidence(threshold)), "
            + "fired: \(fired))"
    }

    private func formatConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", PanicFingerprintService.clampScore(confidence))
    }
}
