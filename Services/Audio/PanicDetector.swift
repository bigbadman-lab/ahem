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

        static let `default` = Configuration(
            threshold: 0.78,
            cooldownDuration: 2.5,
            windowDuration: 0.75,
            analysisInterval: 0.25,
            confidenceLogInterval: 3.0,
            confidenceHistorySize: 4,
            peakSanityMinimumSimilarity: 0.40
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

        #if DEBUG
        print(
            "[Detection] Active (threshold: \(config.threshold), cooldown: \(config.cooldownDuration)s, "
                + "smoothing: \(config.confidenceHistorySize))"
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

        let instantaneousConfidence = Self.computeConfidence(live: live, fingerprint: fingerprint)

        stateLock.lock()
        confidenceHistory.append(instantaneousConfidence)
        if confidenceHistory.count > config.confidenceHistorySize {
            confidenceHistory.removeFirst(confidenceHistory.count - config.confidenceHistorySize)
        }
        let smoothedConfidence = confidenceHistory.reduce(0, +) / Double(confidenceHistory.count)

        let passesPeakSanity = Self.passesPeakSanityCheck(
            live: live,
            fingerprint: fingerprint,
            minimumSimilarity: config.peakSanityMinimumSimilarity
        )

        let qualifies = passesPeakSanity && instantaneousConfidence >= config.threshold

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

    static func passesPeakSanityCheck(
        live: SampleFeatures,
        fingerprint: PanicFingerprint,
        minimumSimilarity: Double
    ) -> Bool {
        var referencePeaks = fingerprint.samples.map(\.peak)
        referencePeaks.append(fingerprint.peakRMS)

        return referencePeaks.contains { referencePeak in
            ratioSimilarity(live.peak, referencePeak) >= minimumSimilarity
        }
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

    private func logAnalysisIfNeeded(
        instantaneous: Double,
        smoothed: Double,
        threshold: Double,
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
                + "fired: \(fired)"
        )
        #endif
    }

    private func formatConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", confidence)
    }
}
