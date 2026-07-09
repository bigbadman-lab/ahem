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

        static let `default` = Configuration(
            threshold: 0.78,
            strongPeakThreshold: 0.79,
            nearMatchSmoothedThreshold: 0.72,
            cooldownDuration: 2.5,
            windowDuration: 0.75,
            analysisInterval: 0.25,
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

        DiagnosticsLog.shared.log(
            category: "Detection",
            "started — v\(fingerprint.version), threshold=\(config.threshold), sampleRate=\(String(format: "%.0f", sampleRate))"
        )

        #if DEBUG
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

        DiagnosticsLog.shared.finalizeActiveDetectionEvent(reason: .detectionPaused)
        DiagnosticsLog.shared.log(category: "Detection", "stopped")

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
        stateLock.unlock()

        let passesPeakSanity = fingerprintService.passesPeakSanityCheck(
            live: live,
            fingerprint: fingerprint,
            minimumSimilarity: config.peakSanityMinimumSimilarity
        )
        let passesNoiseFloor = live.rms >= currentNoiseFloor * config.noiseFloorMultiplier

        let strictRulePassed = smoothedConfidence >= config.threshold
        let nearMatchRulePassed = breakdown.final >= config.strongPeakThreshold
            && smoothedConfidence >= config.nearMatchSmoothedThreshold
        let scoreQualifies = strictRulePassed || nearMatchRulePassed

        let qualifies = passesPeakSanity
            && passesNoiseFloor
            && scoreQualifies

        if !scoreQualifies {
            updateNoiseFloor(with: live.rms)
        }

        stateLock.lock()
        let inCooldown: Bool
        if let lastDetectionTime {
            inCooldown = Date().timeIntervalSince(lastDetectionTime) < config.cooldownDuration
        } else {
            inCooldown = false
        }
        stateLock.unlock()

        let fired = qualifies && !inCooldown

        DiagnosticsLog.shared.recordDetectionDecision(
            instantaneous: breakdown.final,
            smoothed: smoothedConfidence,
            threshold: config.threshold,
            strongPeakThreshold: config.strongPeakThreshold,
            nearMatchSmoothedThreshold: config.nearMatchSmoothedThreshold,
            strictRulePassed: strictRulePassed,
            nearMatchRulePassed: nearMatchRulePassed,
            fired: fired,
            inCooldown: inCooldown,
            qualifies: qualifies
        )

        logAnalysisIfNeeded(
            breakdown: breakdown,
            smoothed: smoothedConfidence,
            threshold: config.threshold,
            noiseFloor: currentNoiseFloor,
            passesPeakSanity: passesPeakSanity,
            passesNoiseFloor: passesNoiseFloor,
            qualifies: qualifies,
            fired: fired
        )

        if inCooldown {
            if qualifies {
                DiagnosticsLog.shared.log(
                    category: "Detection",
                    "cooldown active — suppressing match "
                        + formatDetectionSummary(
                            breakdown: breakdown,
                            smoothed: smoothedConfidence,
                            threshold: config.threshold,
                            fired: false
                        )
                )
                #if DEBUG
                print(
                    "[Detection] Cooldown active — suppressing match "
                        + formatDetectionSummary(
                            breakdown: breakdown,
                            smoothed: smoothedConfidence,
                            threshold: config.threshold,
                            fired: false
                        )
                )
                #endif
            }
            return
        }

        guard qualifies else { return }

        stateLock.lock()
        lastDetectionTime = Date()
        confidenceHistory.removeAll(keepingCapacity: true)
        stateLock.unlock()

        #if DEBUG
        print(
            "[Detection] Detection event emitted "
                + formatDetectionSummary(
                    breakdown: breakdown,
                    smoothed: smoothedConfidence,
                    threshold: config.threshold,
                    fired: true
                )
        )
        #endif

        DiagnosticsLog.shared.log(
            category: "Detection",
            "event emitted "
                + formatDetectionSummary(
                    breakdown: breakdown,
                    smoothed: smoothedConfidence,
                    threshold: config.threshold,
                    fired: true
                )
        )

        let result = PanicDetectionResult(
            confidence: breakdown.final,
            isMatch: true,
            timestamp: Date()
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
