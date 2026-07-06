import Foundation

struct SampleFeatures: Codable, Equatable {
    let rms: Double
    let peak: Double
    let zeroCrossingRate: Double
    let duration: TimeInterval
}

struct PanicFingerprint: Codable, Equatable {
    let createdAt: Date
    let sampleCount: Int
    let averageRMS: Double
    let peakRMS: Double
    let zeroCrossingRate: Double
    let duration: TimeInterval
    let samples: [SampleFeatures]
}
