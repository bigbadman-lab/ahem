import AppKit
import AVFoundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let appState: AppState

    private let audioCaptureService = AudioCaptureService()
    private let panicFingerprintService = PanicFingerprintService()
    private let panicFingerprintStore = PanicFingerprintStore()
    private let browserHidingService = BrowserHidingService()

    private var panicDetector: PanicDetector?
    private var didStart = false
    private var isTraining = false
    private var trainingTask: Task<Void, Never>?
    private var activeSampleCollector: TrainingSampleCollector?
    private var detectionResetTask: Task<Void, Never>?
    private var trainingInputLevelSmoothed: Double = 0

    private let trainingRecordingWindowSeconds: TimeInterval = 5.0
    private let trainingCountdownSeconds = 5
    private let trainingInterSamplePause: TimeInterval = 1.0
    private let maxQuietSampleRetriesPerSample = 2
    private let trainingCompleteDisplayDuration: TimeInterval = 2.0
    private let panicDetectedDisplayDuration: TimeInterval = 1.0

    init(appState: AppState) {
        self.appState = appState
        audioCaptureService.onBuffer = { [weak self] buffer in
            self?.handleAudioBuffer(buffer)
        }
    }

    var isTrainingSessionActive: Bool {
        isTraining || appState.status.isTrainingSessionActive
    }

    var hasStoredFingerprint: Bool {
        panicFingerprintStore.hasFingerprint
    }

    func prepareTrainingUI() {
        appState.trainingUIPhase = .welcome
    }

    func dismissTrainingUI() {
        resetTrainingInputLevel()
        appState.trainingUIPhase = .idle
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApplication.shared.setActivationPolicy(.accessory)

        Task {
            await beginAudioCapture()
        }
    }

    func startTraining() {
        guard !isTraining else {
            #if DEBUG
            print("[Training] Training already in progress — request ignored")
            #endif
            return
        }

        guard AudioCaptureService.currentPermissionStatus() == .granted else {
            appState.status = .microphonePermissionDenied
            appState.trainingUIPhase = .failed("Microphone permission is required to train your panic cough.")
            return
        }

        if !audioCaptureService.isCapturing {
            do {
                try audioCaptureService.startCapture()
            } catch {
                appState.status = .audioError(error.localizedDescription)
                appState.trainingUIPhase = .failed(error.localizedDescription)
                return
            }
        }

        panicDetector?.stop()

        #if DEBUG
        print("[Training] Detection paused")
        #endif

        trainingTask?.cancel()
        isTraining = true
        trainingTask = Task { [weak self] in
            await self?.runTrainingSession()
        }
    }

    func quit() {
        trainingTask?.cancel()
        detectionResetTask?.cancel()
        trainingTask = nil
        detectionResetTask = nil
        activeSampleCollector = nil
        isTraining = false
        panicDetector?.stop()
        panicDetector = nil
        audioCaptureService.stopCapture()
        NSApplication.shared.terminate(nil)
    }

    private func beginAudioCapture() async {
        switch AudioCaptureService.currentPermissionStatus() {
        case .notDetermined:
            appState.status = .microphonePermissionNeeded
            let permission = await AudioCaptureService.requestPermission()
            await handlePermission(permission)

        case .granted:
            startCapture()

        case .denied:
            appState.status = .microphonePermissionDenied
        }
    }

    private func handlePermission(_ permission: MicrophonePermissionStatus) async {
        switch permission {
        case .granted:
            startCapture()
        case .denied:
            appState.status = .microphonePermissionDenied
        case .notDetermined:
            appState.status = .microphonePermissionNeeded
        }
    }

    private func startCapture() {
        do {
            try audioCaptureService.startCapture()
            appState.status = .listening
            configureDetection()
        } catch {
            appState.status = .audioError(error.localizedDescription)
        }
    }

    private func configureDetection() {
        guard !isTraining else {
            #if DEBUG
            print("[Detection] Resume skipped — training still active")
            #endif
            return
        }

        panicDetector?.stop()
        panicDetector = nil

        guard let fingerprint = panicFingerprintStore.load() else {
            #if DEBUG
            print("[Detection] No stored fingerprint — detection inactive")
            #endif
            return
        }

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            #if DEBUG
            print("[Detection] Stored fingerprint loaded but microphone input is unavailable")
            #endif
            return
        }

        let detector = PanicDetector(fingerprint: fingerprint)
        detector.onMatch = { [weak self] result in
            Task { @MainActor in
                self?.handlePanicDetected(confidence: result.confidence)
            }
        }
        detector.start(sampleRate: sampleRate)
        panicDetector = detector

        #if DEBUG
        print("[Detection] Stored fingerprint loaded — detection active")
        #endif
    }

    private func handlePanicDetected(confidence: Double) {
        guard appState.status == .listening || appState.status == .panicDetected else { return }

        print("[Panic] Detected with confidence: \(String(format: "%.2f", confidence))")

        let hideResult = browserHidingService.hideActiveBrowserIfSupported()
        logBrowserHidingResult(hideResult)

        detectionResetTask?.cancel()
        appState.status = .panicDetected

        detectionResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.panicDetectedDisplayDuration ?? 1.0))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if case .panicDetected = self.appState.status {
                self.appState.status = .listening
            }
        }
    }

    private func logBrowserHidingResult(_ result: BrowserHidingResult) {
        switch result {
        case .hidden(let bundleIdentifier, let localizedName, let confirmation):
            switch confirmation {
            case .hideReturnedTrue:
                print("[BrowserHiding] Hidden browser: \(localizedName) (\(bundleIdentifier))")
            case .isHiddenVerified:
                print("[BrowserHiding] Hidden browser: \(localizedName) (\(bundleIdentifier)) — confirmed via isHidden (hide() returned false)")
            }
        case .notBrowser(let bundleIdentifier, let localizedName):
            print("[BrowserHiding] Frontmost app is not a supported browser: \(localizedName) (\(bundleIdentifier))")
        case .noFrontmostApplication:
            print("[BrowserHiding] No frontmost application")
        case .failed(let bundleIdentifier, let localizedName):
            print("[BrowserHiding] Failed to hide browser: \(localizedName) (\(bundleIdentifier))")
        }
    }

    private func runTrainingSession() async {
        defer {
            activeSampleCollector = nil
            isTraining = false
            trainingTask = nil
            configureDetection()
            #if DEBUG
            print("[Training] Detection resumed")
            #endif
        }

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            failTraining("Microphone input is unavailable.")
            return
        }

        #if DEBUG
        print("[Training] Training started")
        #endif

        var collectedSamples: [SampleFeatures] = []

        for sampleIndex in 1...3 {
            if Task.isCancelled { return }

            appState.status = .training(sample: sampleIndex, total: 3)

            #if DEBUG
            print("[Training] Sample \(sampleIndex)/3 started")
            #endif

            guard let features = await captureAcceptedSample(
                sampleRate: sampleRate,
                sampleIndex: sampleIndex
            ) else {
                return
            }

            collectedSamples.append(features)

            if sampleIndex < 3 {
                appState.trainingUIPhase = .preparingNextSample(completedSample: sampleIndex, total: 3)
                try? await Task.sleep(for: .seconds(trainingInterSamplePause))
                if Task.isCancelled { return }
            }
        }

        do {
            let fingerprint = try panicFingerprintService.combine(samples: collectedSamples)
            try panicFingerprintStore.save(fingerprint)
            appState.status = .trainingComplete
            appState.trainingUIPhase = .succeeded

            #if DEBUG
            print("[Training] Training completed")
            print(
                "[Training] Saved panic fingerprint v\(fingerprint.version) "
                    + "with averageRMS: \(fingerprint.averageRMS), "
                    + "consistency: \(String(format: "%.2f", fingerprint.trainingConsistency))"
            )
            #endif
        } catch {
            #if DEBUG
            print("[Training] Training failed — \(error.localizedDescription)")
            #endif
            failTraining(error.localizedDescription)
            return
        }

        try? await Task.sleep(for: .seconds(trainingCompleteDisplayDuration))
        guard !Task.isCancelled else { return }

        appState.trainingUIPhase = .succeededListeningActive
        appState.status = .listening
    }

    private func failTraining(_ message: String) {
        appState.status = .trainingFailed(message)
        appState.trainingUIPhase = .failed(message)
    }

    private enum TrainingCaptureResult {
        case features(SampleFeatures)
        case noActiveRegion
        case captureFailed
    }

    private func captureAcceptedSample(
        sampleRate: Double,
        sampleIndex: Int
    ) async -> SampleFeatures? {
        var quietRetries = 0

        while true {
            if Task.isCancelled { return nil }

            switch await captureSample(sampleRate: sampleRate, sampleIndex: sampleIndex) {
            case .captureFailed:
                #if DEBUG
                print("[Training] Sample \(sampleIndex)/3 rejected — could not capture audio")
                #endif
                failTraining("Could not capture sample \(sampleIndex).")
                return nil

            case .noActiveRegion:
                if quietRetries >= maxQuietSampleRetriesPerSample {
                    failTraining(
                        "Training failed — sample was too quiet too many times. Try again closer to the microphone."
                    )
                    return nil
                }

                quietRetries += 1
                print("[Training] Sample \(sampleIndex)/3 too quiet — retrying same sample")
                continue

            case .features(let features):
                #if DEBUG
                print("[Training] Sample RMS: \(String(format: "%.4f", features.rms))")
                PanicFingerprintService.logSampleFeaturesSummary(features, sampleIndex: sampleIndex)
                #endif

                if panicFingerprintService.isUsableSample(features) {
                    print("[Training] Sample \(sampleIndex)/3 accepted")
                    return features
                }

                if quietRetries >= maxQuietSampleRetriesPerSample {
                    failTraining(
                        "Training failed — sample was too quiet too many times. Try again closer to the microphone."
                    )
                    return nil
                }

                quietRetries += 1
                print("[Training] Sample \(sampleIndex)/3 too quiet — retrying same sample")
            }
        }
    }

    private func runSampleCountdown(sampleIndex: Int, total: Int = 3) async -> Bool {
        resetTrainingInputLevel()
        for secondsRemaining in stride(from: trainingCountdownSeconds, through: 1, by: -1) {
            if Task.isCancelled { return false }
            appState.trainingUIPhase = .countdown(
                sample: sampleIndex,
                total: total,
                secondsRemaining: secondsRemaining
            )
            print("[Training] Sample \(sampleIndex)/3 countdown: \(secondsRemaining)")
            try? await Task.sleep(for: .seconds(1))
        }
        return !Task.isCancelled
    }

    private func captureSample(sampleRate: Double, sampleIndex: Int) async -> TrainingCaptureResult {
        guard await runSampleCountdown(sampleIndex: sampleIndex) else { return .captureFailed }

        appState.trainingUIPhase = .listening(sample: sampleIndex, total: 3)

        print(
            "[Training] Recording sample \(sampleIndex)/3 now — speak your AHEM within "
                + "\(Int(trainingRecordingWindowSeconds)) seconds"
        )
        print("[Training] Sample recording began (sample \(sampleIndex)/3)")

        let capturedFrames = await withCheckedContinuation { continuation in
            final class ResumeGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false

                func resumeOnce(returning frames: [Float], continuation: CheckedContinuation<[Float], Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: frames)
                }
            }

            let resumeGuard = ResumeGuard()
            let collector = TrainingSampleCollector(
                sampleRate: sampleRate,
                duration: trainingRecordingWindowSeconds
            ) { [weak self] frames in
                self?.activeSampleCollector = nil
                resumeGuard.resumeOnce(returning: frames, continuation: continuation)
            }

            activeSampleCollector = collector
        }

        print("[Training] Sample recording finished (sample \(sampleIndex)/3)")
        resetTrainingInputLevel()

        guard !capturedFrames.isEmpty else { return .captureFailed }

        let captureDuration = Double(capturedFrames.count) / sampleRate
        print("[Training] Sample \(sampleIndex)/3 capture duration: \(String(format: "%.2f", captureDuration))s")

        switch panicFingerprintService.extractTrainingFeatures(from: capturedFrames, sampleRate: sampleRate) {
        case .emptyBuffer:
            return .captureFailed

        case .noActiveRegion:
            print("[Training] Sample \(sampleIndex)/3 active region not found — too quiet")
            return .noActiveRegion

        case .extracted(let features, let activeRegionStart, let activeRegionEnd):
            let activeRegionDuration = activeRegionEnd - activeRegionStart
            print(
                "[Training] Sample \(sampleIndex)/3 active region: "
                    + "start \(String(format: "%.2f", activeRegionStart))s, "
                    + "end \(String(format: "%.2f", activeRegionEnd))s, "
                    + "duration \(String(format: "%.2f", activeRegionDuration))s"
            )
            return .features(features)
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            return
        }

        if activeSampleCollector != nil {
            updateTrainingInputLevel(from: buffer)
            activeSampleCollector?.append(buffer: buffer)
            return
        }

        panicDetector?.process(buffer: buffer)
    }

    private func updateTrainingInputLevel(from buffer: AVAudioPCMBuffer) {
        guard let level = Self.normalizedTrainingInputLevel(from: buffer) else { return }

        Task { @MainActor [weak self] in
            guard let self, self.activeSampleCollector != nil else {
                self?.resetTrainingInputLevel()
                return
            }

            let smoothing = 0.35
            let smoothed = (self.trainingInputLevelSmoothed * (1 - smoothing)) + (level * smoothing)
            self.trainingInputLevelSmoothed = min(1, max(0, smoothed))
            self.appState.trainingInputLevel = self.trainingInputLevelSmoothed
        }
    }

    private func resetTrainingInputLevel() {
        trainingInputLevelSmoothed = 0
        appState.trainingInputLevel = 0
    }

    private static func normalizedTrainingInputLevel(from buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData else { return nil }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        let samples = channelData[0]
        var sumSquares = 0.0
        for index in 0..<frameLength {
            let sample = Double(samples[index])
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Double(frameLength))
        guard rms.isFinite else { return nil }

        let displayMaximum = 0.12
        return min(1, max(0, rms / displayMaximum))
    }
}
