import XCTest
@testable import Ahem

final class DetectionConfigurationTests: XCTestCase {
    func testAnalysisIntervalIs125Milliseconds() {
        XCTAssertEqual(
            PanicDetector.Configuration.default.analysisInterval,
            0.125,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PanicDetector.Configuration.defaultAnalysisIntervalSeconds,
            0.125,
            accuracy: 0.000_001
        )
    }

    func testRollingWindowRemains750Milliseconds() {
        XCTAssertEqual(
            PanicDetector.Configuration.default.windowDuration,
            0.75,
            accuracy: 0.000_001
        )
    }

    func testThresholdRemainsPoint78() {
        XCTAssertEqual(
            PanicDetector.Configuration.default.threshold,
            0.78,
            accuracy: 0.000_001
        )
    }

    func testCooldownRemainsTwoPointFiveSeconds() {
        XCTAssertEqual(
            PanicDetector.Configuration.default.cooldownDuration,
            2.5,
            accuracy: 0.000_001
        )
    }

    func testAnalysisIntervalEquals2000SamplesAt16kHz() {
        let sampleRate = AudioCaptureService.targetProcessingSampleRate
        let expectedSamples = Int(sampleRate * PanicDetector.Configuration.default.analysisInterval)
        XCTAssertEqual(expectedSamples, 2_000)
    }
}
