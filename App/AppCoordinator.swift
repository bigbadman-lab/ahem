import AppKit
@preconcurrency import AVFoundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let appState: AppState

    private let audioCaptureService = AudioCaptureService()
    private let panicFingerprintService = PanicFingerprintService()
    private let panicFingerprintStore = PanicFingerprintStore()
    private let browserHidingService = BrowserHidingService()
    private let launchAtLoginService = LaunchAtLoginService()
    private let onboardingStore = OnboardingStore()
    let preferences = UserPreferencesStore()
    private let audioPipeline = AudioPipeline()
    private let audioProcessingQueue = DispatchQueue(
        label: "com.getahem.audio-processing",
        qos: .userInitiated
    )

    private var panicDetector: PanicDetector?
    private var didStart = false
    private var isTraining = false
    private var trainingTask: Task<Void, Never>?
    private var activeSampleCollector: TrainingSampleCollector?
    private var activeSampleCapture: SampleCaptureBridge?
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

        #if DEBUG
        print("[Startup] AppCoordinator init")
        #endif

        audioPipeline.onTrainingBuffer = { [weak self] buffer in
            Task { @MainActor in
                self?.updateTrainingInputLevel(from: buffer)
            }
        }

        audioCaptureService.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.audioProcessingQueue.async {
                self.audioPipeline.process(buffer)
            }
        }
    }

    var isTrainingSessionActive: Bool {
        isTraining || appState.status.isTrainingSessionActive
    }

    var hasStoredFingerprint: Bool {
        panicFingerprintStore.hasStoredData
    }

    var shouldPresentOnboarding: Bool {
        !onboardingStore.hasCompletedOnboarding
    }

    var isOnboardingSessionActive: Bool {
        appState.onboardingPhase != .idle
    }

    func prepareOnboarding() {
        appState.onboardingPhase = .welcome
    }

    func handleOnboardingGetStarted() async {
        switch AudioCaptureService.currentPermissionStatus() {
        case .notDetermined:
            let permission = await AudioCaptureService.requestPermission()
            await handleOnboardingPermission(permission)

        case .granted:
            enterOnboardingTrainingWelcome()

        case .denied:
            appState.onboardingPhase = .permissionDenied
            appState.status = .microphonePermissionDenied
        }
    }

    func finishOnboarding() {
        onboardingStore.markCompleted()
        appState.onboardingPhase = .idle
        dismissTrainingUI()
        configureDetection()

        #if DEBUG
        print("[Onboarding] Onboarding completed")
        #endif
    }

    func handleOnboardingWindowClosed() {
        guard isOnboardingSessionActive else { return }

        switch appState.onboardingPhase {
        case .training:
            if isTraining {
                cancelTrainingSession()
            } else {
                dismissTrainingUI()
            }

        case .completion:
            dismissTrainingUI()
            configureDetection()

        case .welcome, .permissionDenied:
            break

        case .idle:
            break
        }

        appState.onboardingPhase = .idle

        #if DEBUG
        print("[Onboarding] Window closed — onboarding not completed")
        #endif
    }

    func openMicrophoneSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleOnboardingPermission(_ permission: MicrophonePermissionStatus) async {
        switch permission {
        case .granted:
            enterOnboardingTrainingWelcome()

        case .denied:
            appState.onboardingPhase = .permissionDenied
            appState.status = .microphonePermissionDenied

        case .notDetermined:
            appState.onboardingPhase = .permissionDenied
            appState.status = .microphonePermissionNeeded
        }
    }

    private func enterOnboardingTrainingWelcome() {
        appState.onboardingPhase = .training
        appState.trainingUIPhase = .welcome

        #if DEBUG
        print("[Onboarding] Permission granted — showing training welcome screen")
        #endif
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginService.isEnabled
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        try launchAtLoginService.setEnabled(enabled)
    }

    func playTrainingConfirmationSoundIfEnabled() {
        guard preferences.playConfirmationSoundAfterTraining else { return }
        TrainingConfirmationSound.play()
    }

    func prepareTrainingUI() {
        appState.trainingUIPhase = .welcome
    }

    func dismissTrainingUI() {
        resetTrainingInputLevel()
        appState.trainingUIPhase = .idle
    }

    private var trainingHasSucceeded: Bool {
        switch appState.trainingUIPhase {
        case .succeeded, .succeededListeningActive:
            return true
        default:
            return false
        }
    }

    func handleTrainingWindowClosed() {
        if appState.status == .trainingComplete || trainingHasSucceeded {
            #if DEBUG
            print("[Training] Window closed after success")
            #endif
            finishSuccessfulTrainingOnWindowClose()
            return
        }

        if isTraining {
            #if DEBUG
            print("[Training] Training cancelled by closing window")
            #endif
            cancelTrainingSession()
            return
        }

        #if DEBUG
        print("[Training] Window closed before start")
        #endif
        dismissTrainingUI()
    }

    private func finishSuccessfulTrainingOnWindowClose() {
        trainingTask?.cancel()
        dismissTrainingUI()
        if !isTraining {
            configureDetection()
        }
    }

    private func cancelTrainingSession() {
        trainingTask?.cancel()
        activeSampleCapture?.resume(with: [])

        if activeSampleCollector != nil {
            #if DEBUG
            print("[Training] Active sample collector cleared")
            #endif
        }
        activeSampleCollector = nil
        audioPipeline.setSampleCollector(nil)

        resetTrainingInputLevel()
        dismissTrainingUI()

        #if DEBUG
        print("[Training] Training cancellation complete")
        #endif
    }

    func pauseListening() {
        guard appState.status == .listening || appState.status == .panicDetected else { return }

        detectionResetTask?.cancel()
        detectionResetTask = nil
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
        appState.status = .paused
    }

    func resumeListening() {
        guard appState.status == .paused else { return }
        configureDetection()
    }

    func requestMicrophonePermission() {
        Task {
            await beginAudioCapture()
        }
    }

    func refreshLastTrainedDate() {
        appState.lastTrainedAt = panicFingerprintStore.lastTrainedDate()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        #if DEBUG
        print("[Startup] App launch started")
        #endif

        NSApplication.shared.setActivationPolicy(.accessory)

        Task {
            await beginAudioCapture()
            refreshLastTrainedDate()
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
        panicDetector = nil
        audioPipeline.setDetector(nil)

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
        audioPipeline.setDetector(nil)
        audioCaptureService.stopCapture()
        NSApplication.shared.terminate(nil)
    }

    private func beginAudioCapture() async {
        #if DEBUG
        print("[Startup] Checking microphone permission")
        #endif

        switch AudioCaptureService.currentPermissionStatus() {
        case .notDetermined:
            appState.status = .microphonePermissionNeeded

            if !onboardingStore.hasCompletedOnboarding {
                #if DEBUG
                print("[Startup] Onboarding pending — deferring microphone permission request")
                #endif
                return
            }

            let permission = await AudioCaptureService.requestPermission()
            await handlePermission(permission)

        case .granted:
            startCapture()

        case .denied:
            appState.status = .microphonePermissionDenied
            #if DEBUG
            print("[Startup] Startup failed: microphone permission denied")
            #endif
        }
    }

    private func handlePermission(_ permission: MicrophonePermissionStatus) async {
        switch permission {
        case .granted:
            startCapture()
        case .denied:
            appState.status = .microphonePermissionDenied
            #if DEBUG
            print("[Startup] Startup failed: microphone permission denied")
            #endif
        case .notDetermined:
            appState.status = .microphonePermissionNeeded
        }
    }

    private func startCapture() {
        #if DEBUG
        print("[Startup] Starting audio capture")
        #endif

        do {
            try audioCaptureService.startCapture()
            configureDetection()
            #if DEBUG
            print("[Startup] Startup complete")
            #endif
        } catch {
            appState.status = .audioError(error.localizedDescription)
            #if DEBUG
            print("[Startup] Startup failed: \(error.localizedDescription)")
            #endif
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
        audioPipeline.setDetector(nil)

        #if DEBUG
        print("[Startup] Loading stored fingerprint")
        #endif

        guard let fingerprint = panicFingerprintStore.load() else {
            appState.status = .needsTraining
            appState.lastTrainedAt = nil
            #if DEBUG
            print("[Startup] No stored fingerprint — detection inactive")
            #endif
            return
        }

        appState.lastTrainedAt = fingerprint.createdAt

        #if DEBUG
        print("[Startup] Stored fingerprint loaded")
        #endif

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            appState.status = .audioError("Microphone input is unavailable.")
            #if DEBUG
            print("[Startup] Startup failed: microphone input unavailable")
            #endif
            return
        }

        #if DEBUG
        print("[Startup] Starting detection")
        #endif

        let detector = PanicDetector(fingerprint: fingerprint)
        detector.onMatch = { [weak self] result in
            Task { @MainActor in
                self?.handlePanicDetected(confidence: result.confidence)
            }
        }
        detector.start(sampleRate: sampleRate)
        panicDetector = detector
        audioPipeline.setDetector(detector)
        appState.status = .listening

        #if DEBUG
        print("[Startup] Detection started")
        #endif
    }

    private func handlePanicDetected(confidence: Double) {
        guard appState.status == .listening || appState.status == .panicDetected else { return }

        #if DEBUG
        print("[Panic] Detected with confidence: \(String(format: "%.2f", confidence))")
        #endif

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
        #if DEBUG
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
        #endif
    }

    private func runTrainingSession() async {
        defer {
            activeSampleCollector = nil
            audioPipeline.setSampleCollector(nil)
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
            appState.lastTrainedAt = fingerprint.createdAt
            playTrainingConfirmationSoundIfEnabled()

            if isOnboardingSessionActive {
                appState.onboardingPhase = .completion
                appState.trainingUIPhase = .idle

                #if DEBUG
                print("[Onboarding] Training complete — showing completion screen")
                print("[Training] Training completed")
                print(
                    "[Training] Saved panic fingerprint v\(fingerprint.version) "
                        + "with averageRMS: \(fingerprint.averageRMS), "
                        + "consistency: \(String(format: "%.2f", fingerprint.trainingConsistency))"
                )
                #endif
                return
            }

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
                if Task.isCancelled { return nil }
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
                #if DEBUG
                print("[Training] Sample \(sampleIndex)/3 too quiet — retrying same sample")
                #endif
                continue

            case .features(let features):
                #if DEBUG
                print("[Training] Sample RMS: \(String(format: "%.4f", features.rms))")
                PanicFingerprintService.logSampleFeaturesSummary(features, sampleIndex: sampleIndex)
                #endif

                if panicFingerprintService.isUsableSample(features) {
                    #if DEBUG
                    print("[Training] Sample \(sampleIndex)/3 accepted")
                    #endif
                    return features
                }

                if quietRetries >= maxQuietSampleRetriesPerSample {
                    failTraining(
                        "Training failed — sample was too quiet too many times. Try again closer to the microphone."
                    )
                    return nil
                }

                quietRetries += 1
                #if DEBUG
                print("[Training] Sample \(sampleIndex)/3 too quiet — retrying same sample")
                #endif
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
            #if DEBUG
            print("[Training] Sample \(sampleIndex)/3 countdown: \(secondsRemaining)")
            #endif
            try? await Task.sleep(for: .seconds(1))
        }
        return !Task.isCancelled
    }

    private func captureSample(sampleRate: Double, sampleIndex: Int) async -> TrainingCaptureResult {
        guard await runSampleCountdown(sampleIndex: sampleIndex) else { return .captureFailed }

        appState.trainingUIPhase = .listening(sample: sampleIndex, total: 3)

        #if DEBUG
        print(
            "[Training] Recording sample \(sampleIndex)/3 now — speak your AHEM within "
                + "\(Int(trainingRecordingWindowSeconds)) seconds"
        )
        print("[Training] Sample recording began (sample \(sampleIndex)/3)")
        #endif

        let bridge = SampleCaptureBridge()
        activeSampleCapture = bridge

        let capturedFrames = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                bridge.attach(continuation)

                let collector = TrainingSampleCollector(
                    sampleRate: sampleRate,
                    duration: trainingRecordingWindowSeconds
                ) { [weak self] frames in
                    self?.activeSampleCollector = nil
                    self?.audioPipeline.setSampleCollector(nil)
                    bridge.resume(with: frames)
                }

                activeSampleCollector = collector
                audioPipeline.setSampleCollector(collector)
            }
        } onCancel: {
            bridge.resume(with: [])
        }

        activeSampleCapture = nil

        #if DEBUG
        print("[Training] Sample recording finished (sample \(sampleIndex)/3)")
        #endif
        resetTrainingInputLevel()

        guard !capturedFrames.isEmpty else { return .captureFailed }

        let captureDuration = Double(capturedFrames.count) / sampleRate
        #if DEBUG
        print("[Training] Sample \(sampleIndex)/3 capture duration: \(String(format: "%.2f", captureDuration))s")
        #endif

        switch panicFingerprintService.extractTrainingFeatures(from: capturedFrames, sampleRate: sampleRate) {
        case .emptyBuffer:
            return .captureFailed

        case .noActiveRegion:
            #if DEBUG
            print("[Training] Sample \(sampleIndex)/3 active region not found — too quiet")
            #endif
            return .noActiveRegion

        case .extracted(let features, let activeRegionStart, let activeRegionEnd):
            let activeRegionDuration = activeRegionEnd - activeRegionStart
            #if DEBUG
            print(
                "[Training] Sample \(sampleIndex)/3 active region: "
                    + "start \(String(format: "%.2f", activeRegionStart))s, "
                    + "end \(String(format: "%.2f", activeRegionEnd))s, "
                    + "duration \(String(format: "%.2f", activeRegionDuration))s"
            )
            #endif
            return .features(features)
        }
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

private final class SampleCaptureBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<[Float], Never>?

    func attach(_ continuation: CheckedContinuation<[Float], Never>) {
        lock.lock()
        defer { lock.unlock() }
        if didResume {
            continuation.resume(returning: [])
            return
        }
        self.continuation = continuation
    }

    func resume(with frames: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: frames)
    }
}
