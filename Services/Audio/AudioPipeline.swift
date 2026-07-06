import AVFoundation

final class AudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sampleCollector: TrainingSampleCollector?
    private var detector: PanicDetector?
    var onTrainingBuffer: ((AVAudioPCMBuffer) -> Void)?

    func setSampleCollector(_ collector: TrainingSampleCollector?) {
        lock.lock()
        sampleCollector = collector
        lock.unlock()
    }

    func setDetector(_ detector: PanicDetector?) {
        lock.lock()
        self.detector = detector
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            return
        }

        lock.lock()
        let collector = sampleCollector
        let detector = detector
        let trainingHandler = onTrainingBuffer
        lock.unlock()

        if let collector {
            trainingHandler?(buffer)
            collector.append(buffer: buffer)
            return
        }

        detector?.process(buffer: buffer)
    }
}
