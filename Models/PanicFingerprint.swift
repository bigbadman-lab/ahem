import Foundation

struct SampleFeatures: Codable, Equatable {
    static let envelopeBucketCount = 8
    static let bandEnergyCount = 5
    static let mfccCoefficientCount = 13

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
    let spectralCentroid: Double
    let spectralRolloff: Double
    let spectralFlatness: Double
    let spectralFlux: Double
    let bandEnergies: [Double]
    let mfccSummary: [Double]

    var isComplete: Bool {
        envelopeBuckets.count == Self.envelopeBucketCount
            && bandEnergies.count == Self.bandEnergyCount
            && mfccSummary.count == Self.mfccCoefficientCount
            && spectralCentroid.isFinite
            && spectralRolloff.isFinite
            && spectralFlatness.isFinite
            && spectralFlux.isFinite
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
        envelopeBuckets: [Double],
        spectralCentroid: Double = 0,
        spectralRolloff: Double = 0,
        spectralFlatness: Double = 0,
        spectralFlux: Double = 0,
        bandEnergies: [Double] = [],
        mfccSummary: [Double] = []
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
        self.spectralCentroid = spectralCentroid
        self.spectralRolloff = spectralRolloff
        self.spectralFlatness = spectralFlatness
        self.spectralFlux = spectralFlux
        self.bandEnergies = bandEnergies
        self.mfccSummary = mfccSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rms = try container.decode(Double.self, forKey: .rms)
        peak = try container.decode(Double.self, forKey: .peak)
        zeroCrossingRate = try container.decode(Double.self, forKey: .zeroCrossingRate)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        activeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .activeDuration) ?? 0
        attackTime = try container.decodeIfPresent(TimeInterval.self, forKey: .attackTime) ?? 0
        attackStrength = try container.decodeIfPresent(Double.self, forKey: .attackStrength) ?? 0
        peakPosition = try container.decodeIfPresent(Double.self, forKey: .peakPosition) ?? 0
        energyCentroid = try container.decodeIfPresent(Double.self, forKey: .energyCentroid) ?? 0
        envelopeBuckets = try container.decodeIfPresent([Double].self, forKey: .envelopeBuckets) ?? []
        spectralCentroid = try container.decodeIfPresent(Double.self, forKey: .spectralCentroid) ?? 0
        spectralRolloff = try container.decodeIfPresent(Double.self, forKey: .spectralRolloff) ?? 0
        spectralFlatness = try container.decodeIfPresent(Double.self, forKey: .spectralFlatness) ?? 0
        spectralFlux = try container.decodeIfPresent(Double.self, forKey: .spectralFlux) ?? 0
        bandEnergies = try container.decodeIfPresent([Double].self, forKey: .bandEnergies) ?? []
        mfccSummary = try container.decodeIfPresent([Double].self, forKey: .mfccSummary) ?? []
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
        case spectralCentroid
        case spectralRolloff
        case spectralFlatness
        case spectralFlux
        case bandEnergies
        case mfccSummary
    }
}

struct PanicFingerprint: Codable, Equatable {
    static let currentVersion = 3

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
    let averageSpectralCentroid: Double
    let averageSpectralRolloff: Double
    let averageSpectralFlatness: Double
    let averageSpectralFlux: Double
    let averageBandEnergies: [Double]
    let averageMfccSummary: [Double]
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
            envelopeBuckets: averageEnvelopeBuckets,
            spectralCentroid: averageSpectralCentroid,
            spectralRolloff: averageSpectralRolloff,
            spectralFlatness: averageSpectralFlatness,
            spectralFlux: averageSpectralFlux,
            bandEnergies: averageBandEnergies,
            mfccSummary: averageMfccSummary
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
        averageSpectralCentroid: Double = 0,
        averageSpectralRolloff: Double = 0,
        averageSpectralFlatness: Double = 0,
        averageSpectralFlux: Double = 0,
        averageBandEnergies: [Double] = [],
        averageMfccSummary: [Double] = [],
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
        self.averageSpectralCentroid = averageSpectralCentroid
        self.averageSpectralRolloff = averageSpectralRolloff
        self.averageSpectralFlatness = averageSpectralFlatness
        self.averageSpectralFlux = averageSpectralFlux
        self.averageBandEnergies = averageBandEnergies
        self.averageMfccSummary = averageMfccSummary
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
        averageSpectralCentroid = try container.decodeIfPresent(Double.self, forKey: .averageSpectralCentroid) ?? 0
        averageSpectralRolloff = try container.decodeIfPresent(Double.self, forKey: .averageSpectralRolloff) ?? 0
        averageSpectralFlatness = try container.decodeIfPresent(Double.self, forKey: .averageSpectralFlatness) ?? 0
        averageSpectralFlux = try container.decodeIfPresent(Double.self, forKey: .averageSpectralFlux) ?? 0
        averageBandEnergies = try container.decodeIfPresent([Double].self, forKey: .averageBandEnergies) ?? []
        averageMfccSummary = try container.decodeIfPresent([Double].self, forKey: .averageMfccSummary) ?? []
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
        case averageSpectralCentroid
        case averageSpectralRolloff
        case averageSpectralFlatness
        case averageSpectralFlux
        case averageBandEnergies
        case averageMfccSummary
        case trainingConsistency
        case samples
    }
}
