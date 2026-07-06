import AVFoundation
import Foundation

final class PanicDetector {
    struct Configuration {
        let threshold: Double
        let cooldownDuration: TimeInterval
        let windowDuration: TimeInterval
        let analysisInterval: TimeInterval
        let confidenceLogInterval: TimeInterval

        static let `default` = Configuration(
            threshold: 0.75,
            cooldownDuration: 2.5,
            windowDuration: 0.75,
            analysisInterval: 0.25,
            confidenceLogInterval: 3.0
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

        #if DEBUG
        print("[Detection] Active (threshold: \(config.threshold), cooldown: \(config.cooldownDuration)s)")
        #endif
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        rollingWindow?.reset()
        rollingWindow = nil
        isActive = false
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
        guard fingerprintService.isUsableSample(live) else { return }

        let confidence = Self.computeConfidence(live: live, fingerprint: fingerprint)
        logConfidenceIfNeeded(confidence)

        stateLock.lock()
        let inCooldown: Bool
        if let lastDetectionTime {
            inCooldown = Date().timeIntervalSince(lastDetectionTime) < config.cooldownDuration
        } else {
            inCooldown = false
        }
        stateLock.unlock()

        if inCooldown {
            if confidence >= config.threshold {
                #if DEBUG
                print("[Detection] Cooldown active — suppressing match (confidence: \(formatConfidence(confidence)))")
                #endif
            }
            return
        }

        guard confidence >= config.threshold else { return }

        stateLock.lock()
        lastDetectionTime = Date()
        stateLock.unlock()

        let result = PanicDetectionResult(
            confidence: confidence,
            isMatch: true,
            timestamp: Date()
        )

        DispatchQueue.main.async { [weak self] in
            self?.onMatch?(result)
        }
    }

    static func computeConfidence(live: SampleFeatures, fingerprint: PanicFingerprint) -> Double {
        let profileReference = SampleFeatures(
            rms: fingerprint.averageRMS,
            peak: fingerprint.peakRMS,
            zeroCrossingRate: fingerprint.zeroCrossingRate,
            duration: fingerprint.duration
        )

        var best = confidence(live: live, reference: profileReference)
        for sample in fingerprint.samples {
            best = max(best, confidence(live: live, reference: sample))
        }
        return min(1.0, max(0.0, best))
    }

    private static func confidence(live: SampleFeatures, reference: SampleFeatures) -> Double {
        let rmsSimilarity = ratioSimilarity(live.rms, reference.rms)
        let peakSimilarity = ratioSimilarity(live.peak, reference.peak)
        let zeroCrossingSimilarity = ratioSimilarity(live.zeroCrossingRate, reference.zeroCrossingRate, floor: 0.01)

        return (0.45 * rmsSimilarity) + (0.35 * peakSimilarity) + (0.20 * zeroCrossingSimilarity)
    }

    private static func ratioSimilarity(_ live: Double, _ reference: Double, floor: Double = 0.0001) -> Double {
        let maximum = max(live, reference, floor)
        let minimum = min(live, reference)
        return minimum / maximum
    }

    private func logConfidenceIfNeeded(_ confidence: Double) {
        #if DEBUG
        let now = Date()
        if let lastConfidenceLogTime,
           now.timeIntervalSince(lastConfidenceLogTime) < config.confidenceLogInterval {
            return
        }

        stateLock.lock()
        lastConfidenceLogTime = now
        stateLock.unlock()

        print("[Detection] confidence: \(formatConfidence(confidence))")
        #endif
    }

    private func formatConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", confidence)
    }
}
