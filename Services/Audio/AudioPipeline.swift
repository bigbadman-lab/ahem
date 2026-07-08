import AVFoundation

final class AudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sampleCollector: TrainingSampleCollector?
    private var detector: PanicDetector?
    var onTrainingBuffer: ((AVAudioPCMBuffer) -> Void)?

    #if DEBUG
    private var bufferCount = 0
    private var lastRouteLogTime: CFAbsoluteTime = 0
    private let routeLogInterval: CFAbsoluteTime = 3.0
    #endif

    func setSampleCollector(_ collector: TrainingSampleCollector?) {
        lock.lock()
        sampleCollector = collector
        lock.unlock()

        #if DEBUG
        print(
            "[AudioPipeline] Sample collector "
                + (collector == nil ? "cleared" : "attached")
        )
        #endif
    }

    func setDetector(_ detector: PanicDetector?) {
        lock.lock()
        self.detector = detector
        lock.unlock()

        #if DEBUG
        print(
            "[AudioPipeline] Detector "
                + (detector == nil ? "cleared" : "attached")
        )
        #endif
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
            #if DEBUG
            logRouteIfNeeded("training collector")
            #endif
            return
        }

        if let detector {
            detector.process(buffer: buffer)
            #if DEBUG
            logRouteIfNeeded("panic detector")
            #endif
            return
        }

        #if DEBUG
        logRouteIfNeeded("none (buffer dropped)")
        #endif
    }

    #if DEBUG
    private func logRouteIfNeeded(_ route: String) {
        bufferCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRouteLogTime >= routeLogInterval else { return }
        lastRouteLogTime = now
        print(
            "[AudioPipeline] Routing buffers to \(route) "
                + "(total since last log: \(bufferCount))"
        )
        bufferCount = 0
    }
    #endif
}
