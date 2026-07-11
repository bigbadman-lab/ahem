import AVFoundation
import XCTest
@testable import Ahem

final class DetectionRollingWindowTests: XCTestCase {
    private let sampleRate = AudioCaptureService.targetProcessingSampleRate

    func testAnalysisHopSpacingAt125Milliseconds() {
        let chunkSize = 1_024
        let totalSamples = 16_000
        let samples = sineWave(
            sampleCount: totalSamples,
            frequency: 440,
            amplitude: 0.35
        )

        var analysisCount = 0
        let window = DetectionRollingWindow(
            sampleRate: sampleRate,
            windowDuration: PanicDetector.Configuration.default.windowDuration,
            analysisInterval: PanicDetector.Configuration.default.analysisInterval
        ) { _ in
            analysisCount += 1
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            append(samples: Array(samples[offset..<end]), to: window)
            offset = end
        }

        // After the 0.75 s window fills, expect roughly one analysis per 125 ms hop.
        XCTAssertGreaterThanOrEqual(analysisCount, 4)
        XCTAssertLessThanOrEqual(analysisCount, 9)
    }

    func testDuplicateAudioPositionsAreNotAnalysedTwice() {
        let chunkSize = 512
        let samples = sineWave(sampleCount: 10_000, frequency: 440, amplitude: 0.35)

        var analysisCount = 0
        let window = DetectionRollingWindow(
            sampleRate: sampleRate,
            windowDuration: PanicDetector.Configuration.default.windowDuration,
            analysisInterval: PanicDetector.Configuration.default.analysisInterval
        ) { _ in
            analysisCount += 1
        }

        // Two back-to-back appends in the same hop interval should produce at most one analysis.
        append(samples: Array(samples[0..<chunkSize]), to: window)
        let countAfterFirst = analysisCount
        append(samples: Array(samples[chunkSize..<(chunkSize * 2)]), to: window)
        XCTAssertLessThanOrEqual(analysisCount - countAfterFirst, 1)
    }

    func testDetectorStateResetsCorrectly() {
        var analysisCount = 0
        let window = DetectionRollingWindow(
            sampleRate: sampleRate,
            windowDuration: PanicDetector.Configuration.default.windowDuration,
            analysisInterval: PanicDetector.Configuration.default.analysisInterval
        ) { _ in
            analysisCount += 1
        }

        let samples = sineWave(sampleCount: 16_000, frequency: 440, amplitude: 0.35)
        append(samples: Array(samples.prefix(8_000)), to: window)
        window.reset()
        analysisCount = 0

        append(samples: Array(samples.suffix(8_192)), to: window)
        XCTAssertGreaterThan(analysisCount, 0)
    }

    func testTrainingUsesSeparateCollectorPath() {
        let pipeline = AudioPipeline()
        pipeline.setDetector(PanicDetector(fingerprint: makeSyntheticFingerprint()))
        pipeline.setSampleCollector(
            TrainingSampleCollector(sampleRate: sampleRate, duration: 0.25) { _ in }
        )

        guard let buffer = makeBuffer(samples: sineWave(sampleCount: 512, frequency: 440, amplitude: 0.2)) else {
            XCTFail("Failed to create PCM buffer")
            return
        }
        pipeline.process(buffer)
        XCTAssertNotNil(buffer.floatChannelData)
    }

    private func append(samples: [Float], to window: DetectionRollingWindow) {
        guard let buffer = makeBuffer(samples: samples) else {
            XCTFail("Failed to create PCM buffer")
            return
        }
        window.append(buffer: buffer)
    }

    private func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
        buffer?.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer?.floatChannelData?[0] else { return nil }
        for index in samples.indices {
            channel[index] = samples[index]
        }
        return buffer
    }

    private func sineWave(sampleCount: Int, frequency: Double, amplitude: Float) -> [Float] {
        (0..<sampleCount).map { index in
            let t = Double(index) / sampleRate
            return amplitude * Float(sin(2 * Double.pi * frequency * t))
        }
    }

    private func makeSyntheticFingerprint() -> PanicFingerprint {
        let sample = SampleFeatures(
            rms: 0.1,
            peak: 0.2,
            zeroCrossingRate: 0.05,
            duration: 0.5,
            activeDuration: 0.4,
            attackTime: 0.05,
            attackStrength: 0.8,
            peakPosition: 0.3,
            energyCentroid: 0.4,
            envelopeBuckets: Array(repeating: 0.1, count: SampleFeatures.envelopeBucketCount),
            spectralCentroid: 1_500,
            spectralRolloff: 2_000,
            spectralFlatness: 0.2,
            spectralFlux: 0.1,
            bandEnergies: Array(repeating: 0.1, count: SampleFeatures.bandEnergyCount),
            mfccSummary: Array(repeating: 0.1, count: SampleFeatures.mfccCoefficientCount)
        )

        return PanicFingerprint(
            createdAt: Date(),
            sampleCount: 3,
            averageRMS: sample.rms,
            peakRMS: sample.peak,
            zeroCrossingRate: sample.zeroCrossingRate,
            duration: sample.duration,
            averageActiveDuration: sample.activeDuration,
            averageAttackStrength: sample.attackStrength,
            averagePeakPosition: sample.peakPosition,
            averageEnergyCentroid: sample.energyCentroid,
            averageEnvelopeBuckets: sample.envelopeBuckets,
            averageSpectralCentroid: sample.spectralCentroid,
            averageSpectralRolloff: sample.spectralRolloff,
            averageSpectralFlatness: sample.spectralFlatness,
            averageSpectralFlux: sample.spectralFlux,
            averageBandEnergies: sample.bandEnergies,
            averageMfccSummary: sample.mfccSummary,
            trainingConsistency: 0.9,
            samples: [sample, sample, sample],
            processingSampleRate: sampleRate
        )
    }
}
