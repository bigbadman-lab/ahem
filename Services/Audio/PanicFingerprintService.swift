import AVFoundation
import Foundation

struct DetectionConfidenceBreakdown {
    let heuristic: Double
    let spectral: Double
    let spectralRaw: Double
    let final: Double
}

enum PanicFingerprintError: LocalizedError {
    case emptyBuffer
    case invalidSampleCount
    case inconsistentSamples

    var errorDescription: String? {
        switch self {
        case .emptyBuffer:
            return "Audio sample contained no usable data."
        case .invalidSampleCount:
            return "Training requires exactly 3 samples."
        case .inconsistentSamples:
            return "Samples were too inconsistent. Try making the same AHEM each time."
        }
    }
}

struct PanicFingerprintService {
    static let minimumRMS = 0.001
    static let trainingConsistencyThreshold = 0.60
    static let trainingMinimumPairwiseSimilarity = 0.45
    static let envelopeFrameSize = 256
    static let envelopeBucketCount = SampleFeatures.envelopeBucketCount
    static let trainingActiveRegionPadding: TimeInterval = 0.125

    enum TrainingSampleExtractionResult {
        case extracted(SampleFeatures, activeRegionStart: TimeInterval, activeRegionEnd: TimeInterval)
        case noActiveRegion
        case emptyBuffer
    }

    private static let confidenceWeights = (
        rms: 0.20,
        peak: 0.15,
        zeroCrossing: 0.10,
        activeDuration: 0.15,
        attackStrength: 0.15,
        peakPosition: 0.10,
        energyCentroid: 0.10,
        envelope: 0.15
    )

    private static let spectralSimilarityWeights = (
        mfcc: 0.45,
        bands: 0.25,
        centroid: 0.10,
        rolloff: 0.10,
        flatness: 0.05,
        flux: 0.05
    )

    static let heuristicConfidenceWeight = 0.70
    static let spectralConfidenceWeight = 0.30
    static let spectralCalibrationBaseline = 0.55
    static let spectralCalibrationRange = 0.45

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

    func extractTrainingFeatures(
        from frames: [Float],
        sampleRate: Double
    ) -> TrainingSampleExtractionResult {
        guard !frames.isEmpty, sampleRate > 0 else { return .emptyBuffer }

        guard let bounds = Self.activeRegionSampleBounds(from: frames, sampleRate: sampleRate) else {
            return .noActiveRegion
        }

        let paddingFrames = max(0, Int(sampleRate * Self.trainingActiveRegionPadding))
        let paddedStart = max(0, bounds.start - paddingFrames)
        let paddedEnd = min(frames.count, bounds.end + paddingFrames)
        guard paddedEnd > paddedStart else { return .noActiveRegion }

        let trimmed = Array(frames[paddedStart..<paddedEnd])
        guard let features = extractTrainingSampleFeatures(from: trimmed, sampleRate: sampleRate) else {
            return .emptyBuffer
        }

        let activeRegionStart = Double(paddedStart) / sampleRate
        let activeRegionEnd = Double(paddedEnd) / sampleRate
        return .extracted(features, activeRegionStart: activeRegionStart, activeRegionEnd: activeRegionEnd)
    }

    func combine(samples: [SampleFeatures]) throws -> PanicFingerprint {
        guard samples.count == 3 else {
            throw PanicFingerprintError.invalidSampleCount
        }

        let consistency = try validateTrainingConsistency(samples)

        let averageRMS = samples.map(\.rms).reduce(0, +) / Double(samples.count)
        let peakRMS = samples.map(\.peak).max() ?? 0
        let zeroCrossingRate = samples.map(\.zeroCrossingRate).reduce(0, +) / Double(samples.count)
        let duration = samples.map(\.duration).reduce(0, +) / Double(samples.count)
        let averageActiveDuration = samples.map(\.activeDuration).reduce(0, +) / Double(samples.count)
        let averageAttackStrength = samples.map(\.attackStrength).reduce(0, +) / Double(samples.count)
        let averagePeakPosition = samples.map(\.peakPosition).reduce(0, +) / Double(samples.count)
        let averageEnergyCentroid = samples.map(\.energyCentroid).reduce(0, +) / Double(samples.count)
        let averageEnvelopeBuckets = Self.averageEnvelopeBuckets(samples.map(\.envelopeBuckets))
        let averageSpectralCentroid = samples.map(\.spectralCentroid).reduce(0, +) / Double(samples.count)
        let averageSpectralRolloff = samples.map(\.spectralRolloff).reduce(0, +) / Double(samples.count)
        let averageSpectralFlatness = samples.map(\.spectralFlatness).reduce(0, +) / Double(samples.count)
        let averageSpectralFlux = samples.map(\.spectralFlux).reduce(0, +) / Double(samples.count)
        let averageBandEnergies = Self.averageVectors(samples.map(\.bandEnergies))
        let averageMfccSummary = Self.averageVectors(samples.map(\.mfccSummary))

        return PanicFingerprint(
            createdAt: Date(),
            sampleCount: samples.count,
            averageRMS: averageRMS,
            peakRMS: peakRMS,
            zeroCrossingRate: zeroCrossingRate,
            duration: duration,
            averageActiveDuration: averageActiveDuration,
            averageAttackStrength: averageAttackStrength,
            averagePeakPosition: averagePeakPosition,
            averageEnergyCentroid: averageEnergyCentroid,
            averageEnvelopeBuckets: averageEnvelopeBuckets,
            averageSpectralCentroid: averageSpectralCentroid,
            averageSpectralRolloff: averageSpectralRolloff,
            averageSpectralFlatness: averageSpectralFlatness,
            averageSpectralFlux: averageSpectralFlux,
            averageBandEnergies: averageBandEnergies,
            averageMfccSummary: averageMfccSummary,
            trainingConsistency: consistency,
            samples: samples
        )
    }

    func isUsableSample(_ features: SampleFeatures) -> Bool {
        features.rms >= Self.minimumRMS
    }

    func computeConfidence(live: SampleFeatures, fingerprint: PanicFingerprint) -> Double {
        computeBlendedConfidence(live: live, fingerprint: fingerprint)?.final ?? 0
    }

    func computeHeuristicConfidence(live: SampleFeatures, fingerprint: PanicFingerprint) -> Double {
        var best = Self.heuristicFeatureSimilarity(live: live, reference: fingerprint.profileSample)
        for sample in fingerprint.samples {
            best = max(best, Self.heuristicFeatureSimilarity(live: live, reference: sample))
        }
        return Self.clampScore(best)
    }

    func computeRawSpectralSimilarity(live: SampleFeatures, fingerprint: PanicFingerprint) -> Double {
        guard fingerprint.hasCompleteSpectralProfile else { return 0 }

        var best = Self.spectralFeatureSimilarity(live: live, reference: fingerprint.profileSample)
        for sample in fingerprint.samples where sample.hasCompleteSpectralFeatures {
            best = max(best, Self.spectralFeatureSimilarity(live: live, reference: sample))
        }
        return Self.clampScore(best)
    }

    func computeSpectralSimilarity(live: SampleFeatures, fingerprint: PanicFingerprint) -> Double {
        Self.calibrateSpectralScore(computeRawSpectralSimilarity(live: live, fingerprint: fingerprint))
    }

    func computeBlendedConfidence(
        live: SampleFeatures,
        fingerprint: PanicFingerprint
    ) -> DetectionConfidenceBreakdown? {
        guard fingerprint.hasCompleteSpectralProfile else {
            #if DEBUG
            print("[Detection] Fingerprint spectral profile incomplete — retraining required")
            #endif
            return nil
        }

        let heuristic = computeHeuristicConfidence(live: live, fingerprint: fingerprint)
        let spectralRaw = computeRawSpectralSimilarity(live: live, fingerprint: fingerprint)
        let spectral = Self.calibrateSpectralScore(spectralRaw)
        let final = Self.clampScore(
            (heuristic * Self.heuristicConfidenceWeight) + (spectral * Self.spectralConfidenceWeight)
        )

        return DetectionConfidenceBreakdown(
            heuristic: heuristic,
            spectral: spectral,
            spectralRaw: spectralRaw,
            final: final
        )
    }

    func passesPeakSanityCheck(
        live: SampleFeatures,
        fingerprint: PanicFingerprint,
        minimumSimilarity: Double
    ) -> Bool {
        var referencePeaks = fingerprint.samples.map(\.peak)
        referencePeaks.append(fingerprint.peakRMS)

        return referencePeaks.contains { referencePeak in
            Self.ratioSimilarity(live.peak, referencePeak) >= minimumSimilarity
        }
    }

    @discardableResult
    func validateTrainingConsistency(_ samples: [SampleFeatures]) throws -> Double {
        let pairwise = Self.pairwiseSimilarities(samples)
        let average = Self.clampScore(pairwise.reduce(0, +) / Double(pairwise.count))
        let minimum = Self.clampScore(pairwise.min() ?? 0)

        #if DEBUG
        print("[Training] Pairwise similarities: \(pairwise.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
        print("[Training] Training consistency score: \(String(format: "%.2f", average))")
        #endif

        guard average >= Self.trainingConsistencyThreshold,
              minimum >= Self.trainingMinimumPairwiseSimilarity else {
            throw PanicFingerprintError.inconsistentSamples
        }

        return average
    }

    static func logSampleFeaturesSummary(_ features: SampleFeatures, sampleIndex: Int) {
        #if DEBUG
        let envelopeSummary = features.envelopeBuckets
            .map { String(format: "%.2f", $0) }
            .joined(separator: ", ")
        print(
            "[Training] Sample \(sampleIndex) features — "
                + "RMS: \(String(format: "%.4f", features.rms)), "
                + "activeDuration: \(String(format: "%.3f", features.activeDuration))s, "
                + "attackStrength: \(String(format: "%.2f", features.attackStrength)), "
                + "peakPosition: \(String(format: "%.2f", features.peakPosition)), "
                + "envelope: [\(envelopeSummary)]"
        )
        logSampleSpectralSummary(features, sampleIndex: sampleIndex)
        #endif
    }

    static func logSampleSpectralSummary(_ features: SampleFeatures, sampleIndex: Int) {
        #if DEBUG
        let bandSummary = features.bandEnergies
            .map { String(format: "%.2f", $0) }
            .joined(separator: ", ")
        let mfccSummary = features.mfccSummary
            .map { String(format: "%.1f", $0) }
            .joined(separator: ", ")
        print(
            "[Training] Sample \(sampleIndex) spectral — "
                + "centroid: \(String(format: "%.0f", features.spectralCentroid))Hz, "
                + "rolloff: \(String(format: "%.0f", features.spectralRolloff))Hz, "
                + "flatness: \(String(format: "%.2f", features.spectralFlatness)), "
                + "flux: \(String(format: "%.2f", features.spectralFlux)), "
                + "bands: [\(bandSummary)], "
                + "mfccMean: [\(mfccSummary)]"
        )
        #endif
    }

    func extractLiveSampleFeatures(from frames: [Float], sampleRate: Double) -> SampleFeatures? {
        extractTrainingSampleFeatures(from: frames, sampleRate: sampleRate)
    }

    func extractTrainingSampleFeatures(from frames: [Float], sampleRate: Double) -> SampleFeatures? {
        guard let baseFeatures = extractFeatures(from: frames, sampleRate: sampleRate) else { return nil }

        let spectral = SpectralFeatureExtractor.extract(from: frames, sampleRate: sampleRate)
        return SampleFeatures(
            rms: baseFeatures.rms,
            peak: baseFeatures.peak,
            zeroCrossingRate: baseFeatures.zeroCrossingRate,
            duration: baseFeatures.duration,
            activeDuration: baseFeatures.activeDuration,
            attackTime: baseFeatures.attackTime,
            attackStrength: baseFeatures.attackStrength,
            peakPosition: baseFeatures.peakPosition,
            energyCentroid: baseFeatures.energyCentroid,
            envelopeBuckets: baseFeatures.envelopeBuckets,
            spectralCentroid: spectral.spectralCentroid,
            spectralRolloff: spectral.spectralRolloff,
            spectralFlatness: spectral.spectralFlatness,
            spectralFlux: spectral.spectralFlux,
            bandEnergies: spectral.bandEnergies,
            mfccSummary: spectral.mfccSummary
        )
    }

    static func extractFeatures(
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

        let frameEnergies = frameRMSEnergies(from: samples, frameLength: frameLength)
        let envelopeMetrics = envelopeMetrics(
            frameEnergies: frameEnergies,
            frameSize: envelopeFrameSize,
            sampleRate: sampleRate,
            peak: peak
        )

        return SampleFeatures(
            rms: rms,
            peak: peak,
            zeroCrossingRate: zeroCrossingRate,
            duration: duration,
            activeDuration: envelopeMetrics.activeDuration,
            attackTime: envelopeMetrics.attackTime,
            attackStrength: envelopeMetrics.attackStrength,
            peakPosition: envelopeMetrics.peakPosition,
            energyCentroid: envelopeMetrics.energyCentroid,
            envelopeBuckets: envelopeMetrics.envelopeBuckets
        )
    }

    static func heuristicFeatureSimilarity(live: SampleFeatures, reference: SampleFeatures) -> Double {
        let weights = confidenceWeights

        let rmsSimilarity = ratioSimilarity(live.rms, reference.rms)
        let peakSimilarity = ratioSimilarity(live.peak, reference.peak)
        let zeroCrossingSimilarity = ratioSimilarity(live.zeroCrossingRate, reference.zeroCrossingRate, floor: 0.01)
        let activeDurationSimilarity = ratioSimilarity(live.activeDuration, reference.activeDuration, floor: 0.01)
        let attackStrengthSimilarity = ratioSimilarity(live.attackStrength, reference.attackStrength, floor: 0.01)
        let peakPositionSimilarity = positionSimilarity(live.peakPosition, reference.peakPosition)
        let energyCentroidSimilarity = positionSimilarity(live.energyCentroid, reference.energyCentroid)
        let envelopeSimilarity = envelopeShapeSimilarity(live.envelopeBuckets, reference.envelopeBuckets)

        return clampScore(
            (weights.rms * rmsSimilarity)
                + (weights.peak * peakSimilarity)
                + (weights.zeroCrossing * zeroCrossingSimilarity)
                + (weights.activeDuration * activeDurationSimilarity)
                + (weights.attackStrength * attackStrengthSimilarity)
                + (weights.peakPosition * peakPositionSimilarity)
                + (weights.energyCentroid * energyCentroidSimilarity)
                + (weights.envelope * envelopeSimilarity)
        )
    }

    static func spectralFeatureSimilarity(live: SampleFeatures, reference: SampleFeatures) -> Double {
        guard live.hasCompleteSpectralFeatures, reference.hasCompleteSpectralFeatures else { return 0 }

        let weights = spectralSimilarityWeights

        let centroidSimilarity = ratioSimilarity(live.spectralCentroid, reference.spectralCentroid, floor: 1)
        let rolloffSimilarity = ratioSimilarity(live.spectralRolloff, reference.spectralRolloff, floor: 1)
        let flatnessSimilarity = normalizedValueSimilarity(live.spectralFlatness, reference.spectralFlatness)
        let fluxSimilarity = normalizedValueSimilarity(live.spectralFlux, reference.spectralFlux)
        let bandSimilarity = vectorRatioSimilarity(live.bandEnergies, reference.bandEnergies)
        let mfccSimilarity = cosineSimilarity(live.mfccSummary, reference.mfccSummary)

        return clampScore(
            (weights.mfcc * mfccSimilarity)
                + (weights.bands * bandSimilarity)
                + (weights.centroid * centroidSimilarity)
                + (weights.rolloff * rolloffSimilarity)
                + (weights.flatness * flatnessSimilarity)
                + (weights.flux * fluxSimilarity)
        )
    }

    static func featureSimilarity(live: SampleFeatures, reference: SampleFeatures) -> Double {
        clampScore(heuristicFeatureSimilarity(live: live, reference: reference))
    }

    private static func activeEnergyThreshold(maxEnergy: Double) -> Double {
        max(maxEnergy * 0.15, minimumRMS)
    }

    private static func activeRegionSampleBounds(
        from frames: [Float],
        sampleRate: Double
    ) -> (start: Int, end: Int)? {
        guard !frames.isEmpty, sampleRate > 0 else { return nil }

        return frames.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }

            let frameEnergies = frameRMSEnergies(from: base, frameLength: frames.count)
            guard !frameEnergies.isEmpty else { return nil }

            let maxEnergy = frameEnergies.max() ?? 0
            let activeThreshold = activeEnergyThreshold(maxEnergy: maxEnergy)

            let activeFrameIndices = frameEnergies.enumerated().compactMap { index, energy in
                energy >= activeThreshold ? index : nil
            }
            guard let firstActive = activeFrameIndices.first,
                  let lastActive = activeFrameIndices.last else {
                return nil
            }

            let start = firstActive * envelopeFrameSize
            let end = min(frames.count, (lastActive + 1) * envelopeFrameSize)
            guard end > start else { return nil }

            return (start, end)
        }
    }

    private static func frameRMSEnergies(
        from samples: UnsafePointer<Float>,
        frameLength: Int
    ) -> [Double] {
        guard frameLength > 0 else { return [] }

        var energies: [Double] = []
        energies.reserveCapacity((frameLength / envelopeFrameSize) + 1)

        var index = 0
        while index < frameLength {
            let end = min(index + envelopeFrameSize, frameLength)
            var frameSum = 0.0
            for frameIndex in index..<end {
                let sample = Double(samples[frameIndex])
                frameSum += sample * sample
            }
            let frameCount = end - index
            energies.append(sqrt(frameSum / Double(frameCount)))
            index += envelopeFrameSize
        }

        return energies
    }

    private static func envelopeMetrics(
        frameEnergies: [Double],
        frameSize: Int,
        sampleRate: Double,
        peak: Double
    ) -> (
        activeDuration: TimeInterval,
        attackTime: TimeInterval,
        attackStrength: Double,
        peakPosition: Double,
        energyCentroid: Double,
        envelopeBuckets: [Double]
    ) {
        guard !frameEnergies.isEmpty else {
            return (0, 0, 0, 0, 0, [Double](repeating: 0, count: envelopeBucketCount))
        }

        let maxEnergy = frameEnergies.max() ?? 0
        let activeThreshold = Self.activeEnergyThreshold(maxEnergy: maxEnergy)
        let frameDuration = Double(frameSize) / sampleRate

        let activeFrameIndices = frameEnergies.enumerated().compactMap { index, energy in
            energy >= activeThreshold ? index : nil
        }
        let activeDuration = Double(activeFrameIndices.count) * frameDuration

        let peakFrameIndex = frameEnergies.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let normalizedDenominator = Double(max(frameEnergies.count - 1, 1))
        let peakPosition = Double(peakFrameIndex) / normalizedDenominator

        let firstActiveIndex = activeFrameIndices.first ?? peakFrameIndex
        let attackFrames = max(peakFrameIndex - firstActiveIndex, 0)
        let attackTime = Double(attackFrames) * frameDuration
        let attackStrength = peak / max(attackTime, 0.01)

        var weightedPosition = 0.0
        var energySum = 0.0
        for (index, energy) in frameEnergies.enumerated() {
            weightedPosition += Double(index) * energy
            energySum += energy
        }
        let energyCentroid = energySum > 0
            ? (weightedPosition / energySum) / normalizedDenominator
            : 0

        let envelopeBuckets = normalizedEnvelopeBuckets(from: frameEnergies)

        return (
            activeDuration,
            attackTime,
            attackStrength,
            peakPosition,
            energyCentroid,
            envelopeBuckets
        )
    }

    private static func normalizedEnvelopeBuckets(from frameEnergies: [Double]) -> [Double] {
        var buckets = [Double](repeating: 0, count: envelopeBucketCount)
        guard !frameEnergies.isEmpty else { return buckets }

        let bucketSize = max(1, Int(ceil(Double(frameEnergies.count) / Double(envelopeBucketCount))))

        for bucketIndex in 0..<envelopeBucketCount {
            let start = bucketIndex * bucketSize
            guard start < frameEnergies.count else { continue }
            let end = min(start + bucketSize, frameEnergies.count)
            let slice = frameEnergies[start..<end]
            buckets[bucketIndex] = slice.reduce(0, +) / Double(slice.count)
        }

        let peakBucket = buckets.max() ?? 0
        guard peakBucket > 0 else { return buckets }

        return buckets.map { $0 / peakBucket }
    }

    private static func averageEnvelopeBuckets(_ sampleBuckets: [[Double]]) -> [Double] {
        averageVectors(sampleBuckets)
    }

    private static func averageVectors(_ sampleVectors: [[Double]]) -> [Double] {
        guard let first = sampleVectors.first, !first.isEmpty else { return [] }

        var averages = [Double](repeating: 0, count: first.count)
        for vector in sampleVectors {
            for index in averages.indices where index < vector.count {
                averages[index] += vector[index]
            }
        }

        let count = Double(sampleVectors.count)
        return averages.map { $0 / count }
    }

    private static func pairwiseSimilarities(_ samples: [SampleFeatures]) -> [Double] {
        guard samples.count >= 2 else { return [] }

        var similarities: [Double] = []
        for left in 0..<(samples.count - 1) {
            for right in (left + 1)..<samples.count {
                similarities.append(clampScore(featureSimilarity(live: samples[left], reference: samples[right])))
            }
        }
        return similarities
    }

    private static func envelopeShapeSimilarity(_ live: [Double], _ reference: [Double]) -> Double {
        guard live.count == reference.count, !live.isEmpty else { return 0 }

        var total = 0.0
        for index in live.indices {
            total += ratioSimilarity(live[index], reference[index], floor: 0.0001)
        }
        return clampScore(total / Double(live.count))
    }

    private static func positionSimilarity(_ live: Double, _ reference: Double) -> Double {
        let difference = abs(live - reference)
        return clampScore(1.0 - difference)
    }

    static func calibrateSpectralScore(_ rawSpectral: Double) -> Double {
        let clampedRaw = clampScore(rawSpectral)
        return clampScore((clampedRaw - spectralCalibrationBaseline) / spectralCalibrationRange)
    }

    static func ratioSimilarity(_ live: Double, _ reference: Double, floor: Double = 0.0001) -> Double {
        let safeLive = live.isFinite ? live : 0
        let safeReference = reference.isFinite ? reference : 0
        let maximum = max(safeLive, safeReference, floor)
        let minimum = min(safeLive, safeReference)
        return clampScore(minimum / maximum)
    }

    static func clampScore(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func normalizedValueSimilarity(_ live: Double, _ reference: Double) -> Double {
        let safeLive = live.isFinite ? live : 0
        let safeReference = reference.isFinite ? reference : 0
        return clampScore(1.0 - abs(safeLive - safeReference))
    }

    private static func vectorRatioSimilarity(_ live: [Double], _ reference: [Double]) -> Double {
        guard live.count == reference.count, !live.isEmpty else { return 0 }

        var total = 0.0
        for index in live.indices {
            total += ratioSimilarity(live[index], reference[index], floor: 0.0001)
        }
        return clampScore(total / Double(live.count))
    }

    private static func cosineSimilarity(_ live: [Double], _ reference: [Double]) -> Double {
        guard live.count == reference.count, !live.isEmpty else { return 0 }

        var dotProduct = 0.0
        var liveMagnitudeSquared = 0.0
        var referenceMagnitudeSquared = 0.0

        for index in live.indices {
            let liveValue = live[index].isFinite ? live[index] : 0
            let referenceValue = reference[index].isFinite ? reference[index] : 0
            dotProduct += liveValue * referenceValue
            liveMagnitudeSquared += liveValue * liveValue
            referenceMagnitudeSquared += referenceValue * referenceValue
        }

        guard liveMagnitudeSquared > 0, referenceMagnitudeSquared > 0 else { return 0 }

        let cosine = dotProduct / (sqrt(liveMagnitudeSquared) * sqrt(referenceMagnitudeSquared))
        return clampScore(cosine)
    }
}
