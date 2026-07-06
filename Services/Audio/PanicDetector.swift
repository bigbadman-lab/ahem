import AVFoundation
import Foundation

final class PanicDetector {
    struct Configuration {
        let threshold: Double
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

        #if DEBUG
        print(
            "[Detection] Active (version: \(fingerprint.version), threshold: \(config.threshold), "
                + "cooldown: \(config.cooldownDuration)s, smoothing: \(config.confidenceHistorySize))"
        )
        #endif
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        rollingWindow?.reset()
        rollingWindow = nil
        isActive = false
        confidenceHistory.removeAll(keepingCapacity: true)
        noiseFloorHistory.removeAll(keepingCapacity: true)
        noiseFloorRMS = PanicFingerprintService.minimumRMS
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

        let instantaneousConfidence = fingerprintService.computeConfidence(live: live, fingerprint: fingerprint)

        stateLock.lock()
        confidenceHistory.append(instantaneousConfidence)
        if confidenceHistory.count > config.confidenceHistorySize {
            confidenceHistory.removeFirst(confidenceHistory.count - config.confidenceHistorySize)
        }
        let smoothedConfidence = confidenceHistory.reduce(0, +) / Double(confidenceHistory.count)
        let currentNoiseFloor = noiseFloorRMS
        stateLock.unlock()

        let passesPeakSanity = fingerprintService.passesPeakSanityCheck(
            live: live,
            fingerprint: fingerprint,
            minimumSimilarity: config.peakSanityMinimumSimilarity
        )
        let passesNoiseFloor = live.rms >= currentNoiseFloor * config.noiseFloorMultiplier
        let qualifies = passesPeakSanity
            && passesNoiseFloor
            && instantaneousConfidence >= config.threshold

        if instantaneousConfidence < config.threshold {
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

        logAnalysisIfNeeded(
            instantaneous: instantaneousConfidence,
            smoothed: smoothedConfidence,
            threshold: config.threshold,
            noiseFloor: currentNoiseFloor,
            fired: fired
        )

        if inCooldown {
            if qualifies {
                #if DEBUG
                print(
                    "[Detection] Cooldown active — suppressing match "
                        + "(instantaneous: \(formatConfidence(instantaneousConfidence)), "
                        + "smoothed: \(formatConfidence(smoothedConfidence)), "
                        + "threshold: \(formatConfidence(config.threshold)), "
                        + "fired: false)"
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
            "[Detection] Panic detection "
                + "(instantaneous: \(formatConfidence(instantaneousConfidence)), "
                + "smoothed: \(formatConfidence(smoothedConfidence)), "
                + "threshold: \(formatConfidence(config.threshold)), "
                + "fired: true)"
        )
        #endif

        let result = PanicDetectionResult(
            confidence: instantaneousConfidence,
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
        instantaneous: Double,
        smoothed: Double,
        threshold: Double,
        noiseFloor: Double,
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
            "[Detection] instantaneous: \(formatConfidence(instantaneous)), "
                + "smoothed: \(formatConfidence(smoothed)), "
                + "threshold: \(formatConfidence(threshold)), "
                + "noiseFloor: \(String(format: "%.4f", noiseFloor)), "
                + "fired: \(fired)"
        )
        #endif
    }

    private func formatConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", confidence)
    }
}
