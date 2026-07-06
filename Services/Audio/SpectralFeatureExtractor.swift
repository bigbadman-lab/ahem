import Accelerate
import Foundation

struct SpectralFeatures {
    let spectralCentroid: Double
    let spectralRolloff: Double
    let spectralFlatness: Double
    let spectralFlux: Double
    let bandEnergies: [Double]
    let mfccSummary: [Double]
}

enum SpectralFeatureExtractor {
    static let fftSize = 512
    static let hopSize = 256
    static let mfccCoefficientCount = SampleFeatures.mfccCoefficientCount
    static let bandCount = SampleFeatures.bandEnergyCount
    static let melFilterCount = 26
    static let rolloffPercentile = 0.85

    private static let bandEdgesHz: [Double] = [0, 300, 800, 2_000, 5_000, 20_000]

    static func extract(from samples: [Float], sampleRate: Double) -> SpectralFeatures {
        guard !samples.isEmpty, sampleRate > 0 else {
            return emptyFeatures()
        }

        let frames = framedSamples(samples)
        guard !frames.isEmpty else { return emptyFeatures() }

        var centroidSum = 0.0
        var rolloffSum = 0.0
        var flatnessSum = 0.0
        var fluxSum = 0.0
        var bandEnergySum = [Double](repeating: 0, count: bandCount)
        var mfccSum = [Double](repeating: 0, count: mfccCoefficientCount)

        var previousMagnitudes: [Double]?
        var validFrameCount = 0

        for frame in frames {
            let magnitudes = magnitudeSpectrum(frame: frame)
            guard !magnitudes.isEmpty else { continue }

            let normalizedMagnitudes = normalizeMagnitudes(magnitudes)
            let binFrequency = sampleRate / Double(fftSize)

            centroidSum += spectralCentroid(magnitudes: magnitudes, binFrequency: binFrequency)
            rolloffSum += spectralRolloff(magnitudes: magnitudes, binFrequency: binFrequency)
            flatnessSum += spectralFlatness(magnitudes: magnitudes)

            if let previousMagnitudes {
                fluxSum += spectralFlux(current: normalizedMagnitudes, previous: previousMagnitudes)
            }
            previousMagnitudes = normalizedMagnitudes

            let frameBands = bandEnergies(magnitudes: magnitudes, sampleRate: sampleRate)
            for index in bandEnergySum.indices {
                bandEnergySum[index] += frameBands[index]
            }

            let mfcc = mfccCoefficients(magnitudes: magnitudes, sampleRate: sampleRate)
            for index in mfccSum.indices {
                mfccSum[index] += mfcc[index]
            }

            validFrameCount += 1
        }

        guard validFrameCount > 0 else { return emptyFeatures() }

        let frameCount = Double(validFrameCount)
        let averagedBands = bandEnergySum.map { $0 / frameCount }
        let normalizedBands = normalizeBandEnergies(averagedBands)

        return SpectralFeatures(
            spectralCentroid: safe(spectralCentroid: centroidSum / frameCount),
            spectralRolloff: safe(spectralRolloff: rolloffSum / frameCount),
            spectralFlatness: safe(spectralFlatness: flatnessSum / frameCount),
            spectralFlux: safe(spectralFlux: fluxSum / max(frameCount - 1, 1)),
            bandEnergies: normalizedBands,
            mfccSummary: mfccSum.map { safe(mfcc: $0 / frameCount) }
        )
    }

    private static func framedSamples(_ samples: [Float]) -> [[Float]] {
        guard samples.count >= 32 else {
            var padded = [Float](repeating: 0, count: fftSize)
            let copyCount = min(samples.count, fftSize)
            for index in 0..<copyCount {
                padded[index] = samples[index]
            }
            return [padded]
        }

        var frames: [[Float]] = []
        var start = 0
        while start < samples.count {
            var frame = [Float](repeating: 0, count: fftSize)
            let remaining = samples.count - start
            let copyCount = min(fftSize, remaining)
            for index in 0..<copyCount {
                frame[index] = samples[start + index]
            }
            frames.append(frame)

            if remaining <= fftSize { break }
            start += hopSize
        }
        return frames
    }

    private static func hannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [Float](repeating: 1, count: max(count, 1)) }
        return (0..<count).map { index in
            let value = Float(index) / Float(count - 1)
            return 0.5 * (1 - cos(2 * Float.pi * value))
        }
    }

    private static func magnitudeSpectrum(frame: [Float]) -> [Double] {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = hannWindow(count: fftSize)
        var input = [Float](repeating: 0, count: fftSize)
        for index in 0..<fftSize {
            input[index] = frame[index] * window[index]
        }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        input.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                var split = DSPSplitComplex(realp: &real, imagp: &imag)
                vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
            }
        }

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var scale = Float(1.0 / (Float(fftSize) * 2))
        vDSP_vsmul(real, 1, &scale, &real, 1, vDSP_Length(real.count))
        vDSP_vsmul(imag, 1, &scale, &imag, 1, vDSP_Length(imag.count))

        var magnitudes = [Double](repeating: 0, count: fftSize / 2)
        for index in 0..<magnitudes.count {
            let re = Double(real[index])
            let im = Double(imag[index])
            magnitudes[index] = sqrt((re * re) + (im * im))
        }
        return magnitudes
    }

    private static func normalizeMagnitudes(_ magnitudes: [Double]) -> [Double] {
        let sum = magnitudes.reduce(0, +)
        guard sum > 0 else { return magnitudes }
        return magnitudes.map { $0 / sum }
    }

    private static func spectralCentroid(magnitudes: [Double], binFrequency: Double) -> Double {
        var weighted = 0.0
        var total = 0.0
        for (index, magnitude) in magnitudes.enumerated() where magnitude > 0 {
            let frequency = Double(index) * binFrequency
            weighted += frequency * magnitude
            total += magnitude
        }
        guard total > 0 else { return 0 }
        return weighted / total
    }

    private static func spectralRolloff(magnitudes: [Double], binFrequency: Double) -> Double {
        let totalEnergy = magnitudes.reduce(0, +)
        guard totalEnergy > 0 else { return 0 }

        let targetEnergy = totalEnergy * rolloffPercentile
        var cumulative = 0.0
        for (index, magnitude) in magnitudes.enumerated() {
            cumulative += magnitude
            if cumulative >= targetEnergy {
                return Double(index) * binFrequency
            }
        }
        return Double(magnitudes.count - 1) * binFrequency
    }

    private static func spectralFlatness(magnitudes: [Double]) -> Double {
        let positive = magnitudes.filter { $0 > 0 }
        guard !positive.isEmpty else { return 0 }

        let logSum = positive.reduce(0.0) { $0 + log($1) }
        let geometricMean = exp(logSum / Double(positive.count))
        let arithmeticMean = positive.reduce(0, +) / Double(positive.count)
        guard arithmeticMean > 0 else { return 0 }
        return geometricMean / arithmeticMean
    }

    private static func spectralFlux(current: [Double], previous: [Double]) -> Double {
        let count = min(current.count, previous.count)
        guard count > 0 else { return 0 }

        var sum = 0.0
        for index in 0..<count {
            let delta = current[index] - previous[index]
            sum += delta * delta
        }
        return sqrt(sum / Double(count))
    }

    private static func bandEnergies(magnitudes: [Double], sampleRate: Double) -> [Double] {
        let binFrequency = sampleRate / Double(fftSize)
        var energies = [Double](repeating: 0, count: bandCount)

        for (index, magnitude) in magnitudes.enumerated() {
            let frequency = Double(index) * binFrequency
            let energy = magnitude * magnitude
            guard let bandIndex = bandIndex(for: frequency, sampleRate: sampleRate) else { continue }
            energies[bandIndex] += energy
        }

        return energies
    }

    private static func bandIndex(for frequency: Double, sampleRate: Double) -> Int? {
        let nyquist = sampleRate / 2
        let edges = bandEdgesHz.map { min($0, nyquist) }
        guard frequency >= edges[0], frequency <= edges[edges.count - 1] else { return nil }

        for index in 0..<(edges.count - 1) {
            let lower = edges[index]
            let upper = edges[index + 1]
            if frequency >= lower && frequency < upper {
                return index
            }
        }

        if frequency >= edges[edges.count - 2] {
            return bandCount - 1
        }
        return nil
    }

    private static func normalizeBandEnergies(_ energies: [Double]) -> [Double] {
        let total = energies.reduce(0, +)
        guard total > 0 else {
            return [Double](repeating: 1.0 / Double(bandCount), count: bandCount)
        }
        return energies.map { $0 / total }
    }

    private static func mfccCoefficients(magnitudes: [Double], sampleRate: Double) -> [Double] {
        let melEnergies = melFilterbankEnergies(magnitudes: magnitudes, sampleRate: sampleRate)
        let logMel = melEnergies.map { log(max($0, 1e-10)) }
        return discreteCosineTransform(logMel, coefficientCount: mfccCoefficientCount)
    }

    private static func hzToMel(_ frequency: Double) -> Double {
        2_595 * log10(1 + (frequency / 700))
    }

    private static func melToHz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2_595) - 1)
    }

    private static func melFilterbankEnergies(magnitudes: [Double], sampleRate: Double) -> [Double] {
        let nyquist = sampleRate / 2
        let minMel = hzToMel(0)
        let maxMel = hzToMel(nyquist)
        let melPoints = (0..<(melFilterCount + 2)).map { index in
            melToHz(minMel + (Double(index) * (maxMel - minMel) / Double(melFilterCount + 1)))
        }

        let binFrequency = sampleRate / Double(fftSize)
        let binCount = magnitudes.count
        var energies = [Double](repeating: 0, count: melFilterCount)

        for filterIndex in 0..<melFilterCount {
            let left = melPoints[filterIndex]
            let center = melPoints[filterIndex + 1]
            let right = melPoints[filterIndex + 2]

            for binIndex in 0..<binCount {
                let frequency = Double(binIndex) * binFrequency
                let weight: Double
                if frequency < left || frequency > right {
                    weight = 0
                } else if frequency <= center {
                    weight = (frequency - left) / max(center - left, 1e-10)
                } else {
                    weight = (right - frequency) / max(right - center, 1e-10)
                }

                let power = magnitudes[binIndex] * magnitudes[binIndex]
                energies[filterIndex] += weight * power
            }
        }

        return energies
    }

    private static func discreteCosineTransform(_ input: [Double], coefficientCount: Int) -> [Double] {
        guard !input.isEmpty else {
            return [Double](repeating: 0, count: coefficientCount)
        }

        var coefficients = [Double](repeating: 0, count: coefficientCount)
        let inputCount = input.count

        for coefficientIndex in 0..<coefficientCount {
            var sum = 0.0
            for inputIndex in 0..<inputCount {
                let angle = Double.pi * Double(coefficientIndex) * (Double(inputIndex) + 0.5) / Double(inputCount)
                sum += input[inputIndex] * cos(angle)
            }
            coefficients[coefficientIndex] = sum
        }

        return coefficients
    }

    private static func emptyFeatures() -> SpectralFeatures {
        SpectralFeatures(
            spectralCentroid: 0,
            spectralRolloff: 0,
            spectralFlatness: 0,
            spectralFlux: 0,
            bandEnergies: [Double](repeating: 0, count: bandCount),
            mfccSummary: [Double](repeating: 0, count: mfccCoefficientCount)
        )
    }

    private static func safe(spectralCentroid value: Double) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    private static func safe(spectralRolloff value: Double) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    private static func safe(spectralFlatness value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func safe(spectralFlux value: Double) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    private static func safe(mfcc value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
