import Foundation

struct SampleFeatures: Codable, Equatable {
    static let envelopeBucketCount = 8

    let rms: Double
    let peak: Double
    let zeroCrossingRate: Double
    let duration: TimeInterval
    let activeDuration: TimeInterval
    let attackTime: TimeInterval
    let attackStrength: Double
    let peakPosition: Double
    let energyCentroid: Double
    let envelopeBuckets: [Double]

    var isComplete: Bool {
        envelopeBuckets.count == Self.envelopeBucketCount
    }

    init(
        rms: Double,
        peak: Double,
        zeroCrossingRate: Double,
        duration: TimeInterval,
        activeDuration: TimeInterval,
        attackTime: TimeInterval,
        attackStrength: Double,
        peakPosition: Double,
        energyCentroid: Double,
        envelopeBuckets: [Double]
    ) {
        self.rms = rms
        self.peak = peak
        self.zeroCrossingRate = zeroCrossingRate
        self.duration = duration
        self.activeDuration = activeDuration
        self.attackTime = attackTime
        self.attackStrength = attackStrength
        self.peakPosition = peakPosition
        self.energyCentroid = energyCentroid
        self.envelopeBuckets = envelopeBuckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rms = try container.decode(Double.self, forKey: .rms)
        peak = try container.decode(Double.self, forKey: .peak)
        zeroCrossingRate = try container.decode(Double.self, forKey: .zeroCrossingRate)
        duration = try container.decode(Double.self, forKey: .duration)
        activeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .activeDuration) ?? 0
        attackTime = try container.decodeIfPresent(TimeInterval.self, forKey: .attackTime) ?? 0
        attackStrength = try container.decodeIfPresent(Double.self, forKey: .attackStrength) ?? 0
        peakPosition = try container.decodeIfPresent(Double.self, forKey: .peakPosition) ?? 0
        energyCentroid = try container.decodeIfPresent(Double.self, forKey: .energyCentroid) ?? 0
        envelopeBuckets = try container.decodeIfPresent([Double].self, forKey: .envelopeBuckets) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case rms
        case peak
        case zeroCrossingRate
        case duration
        case activeDuration
        case attackTime
        case attackStrength
        case peakPosition
        case energyCentroid
        case envelopeBuckets
    }
}

struct PanicFingerprint: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let createdAt: Date
    let sampleCount: Int
    let averageRMS: Double
    let peakRMS: Double
    let zeroCrossingRate: Double
    let duration: TimeInterval
    let averageActiveDuration: TimeInterval
    let averageAttackStrength: Double
    let averagePeakPosition: Double
    let averageEnergyCentroid: Double
    let averageEnvelopeBuckets: [Double]
    let trainingConsistency: Double
    let samples: [SampleFeatures]

    var isDetectionCompatible: Bool {
        version >= Self.currentVersion && samples.allSatisfy(\.isComplete)
    }

    var profileSample: SampleFeatures {
        SampleFeatures(
            rms: averageRMS,
            peak: peakRMS,
            zeroCrossingRate: zeroCrossingRate,
            duration: duration,
            activeDuration: averageActiveDuration,
            attackTime: samples.map(\.attackTime).reduce(0, +) / Double(max(samples.count, 1)),
            attackStrength: averageAttackStrength,
            peakPosition: averagePeakPosition,
            energyCentroid: averageEnergyCentroid,
            envelopeBuckets: averageEnvelopeBuckets
        )
    }

    init(
        version: Int = PanicFingerprint.currentVersion,
        createdAt: Date,
        sampleCount: Int,
        averageRMS: Double,
        peakRMS: Double,
        zeroCrossingRate: Double,
        duration: TimeInterval,
        averageActiveDuration: TimeInterval,
        averageAttackStrength: Double,
        averagePeakPosition: Double,
        averageEnergyCentroid: Double,
        averageEnvelopeBuckets: [Double],
        trainingConsistency: Double,
        samples: [SampleFeatures]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.sampleCount = sampleCount
        self.averageRMS = averageRMS
        self.peakRMS = peakRMS
        self.zeroCrossingRate = zeroCrossingRate
        self.duration = duration
        self.averageActiveDuration = averageActiveDuration
        self.averageAttackStrength = averageAttackStrength
        self.averagePeakPosition = averagePeakPosition
        self.averageEnergyCentroid = averageEnergyCentroid
        self.averageEnvelopeBuckets = averageEnvelopeBuckets
        self.trainingConsistency = trainingConsistency
        self.samples = samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        averageRMS = try container.decode(Double.self, forKey: .averageRMS)
        peakRMS = try container.decode(Double.self, forKey: .peakRMS)
        zeroCrossingRate = try container.decode(Double.self, forKey: .zeroCrossingRate)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        averageActiveDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .averageActiveDuration) ?? 0
        averageAttackStrength = try container.decodeIfPresent(Double.self, forKey: .averageAttackStrength) ?? 0
        averagePeakPosition = try container.decodeIfPresent(Double.self, forKey: .averagePeakPosition) ?? 0
        averageEnergyCentroid = try container.decodeIfPresent(Double.self, forKey: .averageEnergyCentroid) ?? 0
        averageEnvelopeBuckets = try container.decodeIfPresent([Double].self, forKey: .averageEnvelopeBuckets) ?? []
        trainingConsistency = try container.decodeIfPresent(Double.self, forKey: .trainingConsistency) ?? 0
        samples = try container.decode([SampleFeatures].self, forKey: .samples)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case createdAt
        case sampleCount
        case averageRMS
        case peakRMS
        case zeroCrossingRate
        case duration
        case averageActiveDuration
        case averageAttackStrength
        case averagePeakPosition
        case averageEnergyCentroid
        case averageEnvelopeBuckets
        case trainingConsistency
        case samples
    }
}
