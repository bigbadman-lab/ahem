import AVFoundation

enum PanicFingerprintError: LocalizedError {
    case emptyBuffer
    case invalidSampleCount

    var errorDescription: String? {
        switch self {
        case .emptyBuffer:
            return "Audio sample contained no usable data."
        case .invalidSampleCount:
            return "Training requires exactly 3 samples."
        }
    }
}

struct PanicFingerprintService {
    private static let minimumRMS = 0.001

    func extractFeatures(from buffer: AVAudioPCMBuffer) -> SampleFeatures? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        return Self.extractFeatures(
            from: channelData[0],
            frameLength: frameLength,
            sampleRate: buffer.format.sampleRate
        )
    }

    func extractFeatures(from frames: [Float], sampleRate: Double) -> SampleFeatures? {
        guard !frames.isEmpty, sampleRate > 0 else { return nil }
        return frames.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return Self.extractFeatures(
                from: base,
                frameLength: frames.count,
                sampleRate: sampleRate
            )
        }
    }

    func combine(samples: [SampleFeatures]) throws -> PanicFingerprint {
        guard samples.count == 3 else {
            throw PanicFingerprintError.invalidSampleCount
        }

        let averageRMS = samples.map(\.rms).reduce(0, +) / Double(samples.count)
        let peakRMS = samples.map(\.peak).max() ?? 0
        let zeroCrossingRate = samples.map(\.zeroCrossingRate).reduce(0, +) / Double(samples.count)
        let duration = samples.map(\.duration).reduce(0, +) / Double(samples.count)

        return PanicFingerprint(
            createdAt: Date(),
            sampleCount: samples.count,
            averageRMS: averageRMS,
            peakRMS: peakRMS,
            zeroCrossingRate: zeroCrossingRate,
            duration: duration,
            samples: samples
        )
    }

    func isUsableSample(_ features: SampleFeatures) -> Bool {
        features.rms >= Self.minimumRMS
    }

    private static func extractFeatures(
        from samples: UnsafePointer<Float>,
        frameLength: Int,
        sampleRate: Double
    ) -> SampleFeatures? {
        guard frameLength > 0, sampleRate > 0 else { return nil }

        var sumSquares = 0.0
        var peak = 0.0
        var zeroCrossings = 0

        for index in 0..<frameLength {
            let sample = Double(samples[index])
            sumSquares += sample * sample
            peak = max(peak, abs(sample))

            if index > 0 {
                let previous = samples[index - 1]
                let current = samples[index]
                if (previous >= 0 && current < 0) || (previous < 0 && current >= 0) {
                    zeroCrossings += 1
                }
            }
        }

        let rms = sqrt(sumSquares / Double(frameLength))
        let zeroCrossingRate = Double(zeroCrossings) / Double(frameLength)
        let duration = Double(frameLength) / sampleRate

        return SampleFeatures(
            rms: rms,
            peak: peak,
            zeroCrossingRate: zeroCrossingRate,
            duration: duration
        )
    }
}
