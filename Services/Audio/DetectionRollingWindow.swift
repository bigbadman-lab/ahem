import AVFoundation

final class DetectionRollingWindow {
    private let lock = NSLock()
    private let maxFrameCount: Int
    private let minFrameCount: Int
    private let sampleRate: Double
    private let analysisInterval: TimeInterval
    private let featureService = PanicFingerprintService()
    private let onFeatures: (SampleFeatures) -> Void

    private var frames: [Float] = []
    private var lastAnalysisTime: CFAbsoluteTime = 0

    init(
        sampleRate: Double,
        windowDuration: TimeInterval,
        analysisInterval: TimeInterval,
        onFeatures: @escaping (SampleFeatures) -> Void
    ) {
        self.sampleRate = sampleRate
        self.maxFrameCount = max(1, Int(sampleRate * windowDuration))
        self.minFrameCount = max(1, Int(sampleRate * windowDuration * 0.67))
        self.analysisInterval = analysisInterval
        self.onFeatures = onFeatures
    }

    func append(buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        frames.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))

        if frames.count > maxFrameCount {
            frames.removeFirst(frames.count - maxFrameCount)
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysisTime >= analysisInterval else { return }
        guard frames.count >= minFrameCount else { return }

        lastAnalysisTime = now

        guard let features = featureService.extractLiveSampleFeatures(from: frames, sampleRate: sampleRate) else {
            return
        }

        onFeatures(features)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
        lastAnalysisTime = 0
    }
}
