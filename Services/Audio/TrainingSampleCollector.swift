import AVFoundation

final class TrainingSampleCollector {
    private let lock = NSLock()
    private let targetFrameCount: Int
    private let onComplete: ([Float]) -> Void

    private var frames: [Float] = []
    private var isComplete = false

    init(sampleRate: Double, duration: TimeInterval, onComplete: @escaping ([Float]) -> Void) {
        self.targetFrameCount = max(1, Int(sampleRate * duration))
        self.onComplete = onComplete
    }

    func append(buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isComplete else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channel = channelData[0]
        frames.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameLength))

        guard frames.count >= targetFrameCount else { return }

        isComplete = true
        let captured = Array(frames.prefix(targetFrameCount))

        DispatchQueue.main.async { [onComplete] in
            onComplete(captured)
        }
    }
}
