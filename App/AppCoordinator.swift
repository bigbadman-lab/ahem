import AppKit
@preconcurrency import AVFoundation

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
    private var didEvaluateStartupSetup = false
    private var didPresentStartupSetup = false
    private var isTraining = false
    private var trainingTask: Task<Void, Never>?
    private var activeSampleCollector: TrainingSampleCollector?
    private var activeSampleCapture: SampleCaptureBridge?
    private var detectionResetTask: Task<Void, Never>?
    private var trainingInputLevelSmoothed: Double = 0

    private var isPausing = false
    private var isListeningStartupInProgress = false
    private var activeListeningStartupFailureMode: ListeningRecoveryFailureMode = .audioError

    private let trainingRecordingWindowSeconds: TimeInterval = 5.0
    private let trainingCountdownSeconds = 5
    private let trainingInterSamplePause: TimeInterval = 1.0
    private let maxQuietSampleRetriesPerSample = 2
    private let trainingCompleteDisplayDuration: TimeInterval = 2.0
    private let panicDetectedDisplayDuration: TimeInterval = 1.0
    private let listeningBufferWaitTimeout: TimeInterval = 3.0
    private let listeningStartupRetryBackoff: TimeInterval = 0.3

    private var listeningStartupTask: Task<Void, Never>?
    private var listeningStartupGeneration: UInt64 = 0
    private var trainingModalActive = false
    private var startingTimeoutTask: Task<Void, Never>?
    private var trainingTimeoutTask: Task<Void, Never>?
    private let startingTimeoutDuration: TimeInterval = 12
    private let trainingTimeoutDuration: TimeInterval = 120

    private enum ListeningStartupReason: String {
        case startup
        case retry
        case resume
        case postTraining
    }

    private enum ListeningRecoveryFailureMode {
        case paused
        case audioError
    }

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

    // MARK: - State machine (single owner of appState.status)

    @discardableResult
    private func transition(
        to newStatus: AppStatus,
        reason: String,
        options: AppStateMachine.Options = .init()
    ) -> Bool {
        let current = appState.status

        if trainingModalActive,
           !options.force,
           !allowsTransitionDuringTraining(from: current, to: newStatus, options: options) {
            AppStateMachine.logBlocked(
                from: current,
                to: newStatus,
                reason: "training modal active — \(reason)"
            )
            return false
        }

        guard AppStateMachine.isAllowed(from: current, to: newStatus, options: options) else {
            AppStateMachine.logBlocked(from: current, to: newStatus, reason: reason)
            return false
        }

        AppStateMachine.logTransition(from: current, to: newStatus, reason: reason)
        appState.status = newStatus
        handleStatusSideEffects(from: current, to: newStatus)
        return true
    }

    private func allowsTransitionDuringTraining(
        from: AppStatus,
        to: AppStatus,
        options: AppStateMachine.Options
    ) -> Bool {
        let fromPhase = AppStateMachine.phase(of: from)
        let toPhase = AppStateMachine.phase(of: to)

        if fromPhase == .training, toPhase == .training { return true }
        if toPhase == .trainingFailed { return true }
        if toPhase == .trainingComplete { return true }
        if options.postTrainingExit, toPhase == .starting || toPhase == .listening { return true }
        return false
    }

    private func handleStatusSideEffects(from: AppStatus, to: AppStatus) {
        if AppStateMachine.phase(of: from) == .starting {
            startingTimeoutTask?.cancel()
            startingTimeoutTask = nil
        }

        if AppStateMachine.phase(of: to) == .starting {
            scheduleStartingTimeout()
        }

        if AppStateMachine.phase(of: to) == .listening {
            endTrainingModal()
        }

        if AppStateMachine.phase(of: to) == .trainingFailed {
            endTrainingModal()
        }
    }

    private func scheduleStartingTimeout() {
        startingTimeoutTask?.cancel()
        startingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.startingTimeoutDuration ?? 12))
            guard let self, !Task.isCancelled else { return }
            guard case .starting = self.appState.status else { return }

            AppStateMachine.logTimeout("starting timed out", reason: "listening startup exceeded timeout")
            self.applyListeningRecoveryFailure(
                self.listeningStartupError(code: 7, message: "Listening startup timed out."),
                mode: self.activeListeningStartupFailureMode
            )
        }
    }

    private func beginTrainingModal(reason: String) {
        trainingModalActive = true
        cancelListeningStartup()
        scheduleTrainingTimeout()
        _ = transition(
            to: .training(sample: 1, total: 3),
            reason: reason,
            options: .init(userInitiated: true, force: true)
        )
    }

    private func endTrainingModal() {
        guard trainingModalActive else { return }
        trainingModalActive = false
        trainingTimeoutTask?.cancel()
        trainingTimeoutTask = nil
    }

    private func scheduleTrainingTimeout() {
        trainingTimeoutTask?.cancel()
        trainingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.trainingTimeoutDuration ?? 120))
            guard let self, !Task.isCancelled else { return }
            guard self.trainingModalActive || self.isTraining else { return }

            AppStateMachine.logTimeout("training timed out", reason: "training session exceeded timeout")
            self.failTraining("Training timed out. Please try again.")
        }
    }

    private func cancelListeningStartup() {
        listeningStartupTask?.cancel()
        listeningStartupTask = nil
        listeningStartupGeneration &+= 1
    }

    var isTrainingSessionActive: Bool {
        isTraining || appState.status.isTrainingSessionActive
    }

    var hasStoredFingerprint: Bool {
        panicFingerprintStore.hasStoredData
    }

    var shouldPresentOnboarding: Bool {
        // Kept for manual flows; automatic launch uses evaluateStartupSetupPresentation().
        !onboardingStore.hasCompletedOnboarding
    }

    var isOnboardingSessionActive: Bool {
        appState.onboardingPhase != .idle
    }

    /// True while onboarding/training UI owns the microphone and listening must not race it.
    private var isSetupOrTrainingInProgress: Bool {
        if isTraining { return true }
        if isOnboardingSessionActive { return true }
        switch appState.trainingUIPhase {
        case .idle:
            return false
        case .welcome, .countdown, .listening, .preparingNextSample, .succeeded, .succeededListeningActive, .failed:
            return true
        }
    }

    func prepareOnboarding() {
        appState.onboardingPhase = .welcome
    }

    /// Evaluates permission + fingerprint once at launch and queues a setup window if needed.
    /// Does not request microphone permission.
    func evaluateStartupSetupPresentation() {
        guard !didEvaluateStartupSetup else {
            #if DEBUG
            print("[Onboarding] Startup evaluation already done — skipping duplicate")
            #endif
            return
        }
        didEvaluateStartupSetup = true

        let permission = AudioCaptureService.currentPermissionStatus()
        let hasFingerprint = panicFingerprintStore.load() != nil

        #if DEBUG
        print(
            "[Onboarding] Startup evaluation — "
                + "permission=\(permission), "
                + "hasFingerprint=\(hasFingerprint), "
                + "onboardingCompleted=\(onboardingStore.hasCompletedOnboarding)"
        )
        #endif

        switch permission {
        case .granted:
            if hasFingerprint {
                #if DEBUG
                print("[Onboarding] Setup complete — onboarding not needed")
                #endif
                if !onboardingStore.hasCompletedOnboarding {
                    onboardingStore.markCompleted()
                }
                return
            }

            #if DEBUG
            print("[Onboarding] Permission granted but no fingerprint — presenting training/setup")
            #endif
            if onboardingStore.hasCompletedOnboarding {
                prepareTrainingUI()
                appState.setupPresentationRequest = .training
            } else {
                // First-run / incomplete setup: keep the onboarding shell and go to training welcome.
                appState.onboardingPhase = .training
                appState.trainingUIPhase = .welcome
                beginTrainingModal(reason: "startup onboarding training welcome")
                appState.setupPresentationRequest = .onboarding
            }

        case .notDetermined, .denied:
            #if DEBUG
            print("[Onboarding] Permission not granted — presenting onboarding")
            #endif
            prepareOnboarding()
            appState.setupPresentationRequest = .onboarding
        }
    }

    func markStartupSetupPresented() {
        didPresentStartupSetup = true
        appState.setupPresentationRequest = nil
    }

    var didConsumeStartupSetupPresentation: Bool {
        didPresentStartupSetup
    }

    func handleOnboardingGetStarted() async {
        let permission = await ensureMicrophonePermission(
            requestIfNeeded: true,
            callSite: "Onboarding.GetStarted"
        )

        switch permission {
        case .granted:
            #if DEBUG
            print("[Onboarding] Permission granted — starting training flow")
            #endif
            // Do not start listening here. Training owns the mic until setup completes.
            stopListeningCaptureIfNeeded(reason: "permission granted during onboarding")
            enterOnboardingTrainingWelcome()

        case .denied:
            appState.onboardingPhase = .permissionDenied
            transition(to: .microphonePermissionDenied, reason: "onboarding permission denied")

        case .notDetermined:
            appState.onboardingPhase = .permissionDenied
            transition(to: .microphonePermissionNeeded, reason: "onboarding permission not determined")
        }
    }

    func finishOnboarding() {
        onboardingStore.markCompleted()
        appState.onboardingPhase = .idle
        dismissTrainingUI()
        scheduleListeningStartup(reason: .postTraining, failureMode: .audioError)

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
            scheduleListeningStartup(reason: .postTraining, failureMode: .audioError)

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

    private func enterOnboardingTrainingWelcome() {
        appState.onboardingPhase = .training
        appState.trainingUIPhase = .welcome
        beginTrainingModal(reason: "onboarding enter training welcome")

        #if DEBUG
        print("[Onboarding] Listening deferred — setup/training in progress")
        #endif
    }

    private func stopListeningCaptureIfNeeded(reason: String) {
        let hadDetector = panicDetector != nil
        let wasCapturing = audioCaptureService.isCapturing
        guard hadDetector || wasCapturing else { return }

        #if DEBUG
        print("[Training] Stopping listening capture before training (\(reason))")
        #endif

        detectionResetTask?.cancel()
        detectionResetTask = nil
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
        // Keep capture running if possible — training can reuse it — but if detection was wired,
        // clear detector so buffers are not consumed for listening during setup.
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
        if !trainingModalActive {
            beginTrainingModal(reason: "prepare training UI")
        }
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
            scheduleListeningStartup(reason: .postTraining, failureMode: .audioError)
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
        endTrainingModal()

        #if DEBUG
        print("[Training] Training cancellation complete")
        #endif
    }

    func pauseListening() {
        guard appState.status == .listening || appState.status == .panicDetected else { return }

        guard !isPausing else {
            #if DEBUG
            print("[Listening] Pause ignored — pause already in progress")
            #endif
            return
        }
        guard !isListeningStartupInProgress else {
            print("[AudioLifecycle] pause ignored — listening startup already in progress")
            return
        }

        isPausing = true
        defer { isPausing = false }

        #if DEBUG
        print("[Listening] Pause requested")
        #endif

        detectionResetTask?.cancel()
        detectionResetTask = nil
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
        cancelListeningStartup()
        audioCaptureService.stopCapture(reason: "user paused listening")
        _ = transition(to: .paused, reason: "user paused listening")

        #if DEBUG
        print("[Listening] Detection paused")
        print("[Listening] Audio capture stopped")
        #endif
    }

    func resumeListening() {
        guard appState.status == .paused else { return }
        guard !isPausing else {
            print("[AudioLifecycle] resume ignored — pause already in progress")
            return
        }
        scheduleListeningStartup(reason: .resume, failureMode: .paused)
    }

    func retryListening() {
        guard case .audioError = appState.status else { return }
        guard !isPausing, !isTraining else { return }
        scheduleListeningStartup(reason: .retry, failureMode: .audioError)
    }

    private func scheduleListeningStartup(
        reason: ListeningStartupReason,
        failureMode: ListeningRecoveryFailureMode
    ) {
        if isListeningStartupInProgress {
            let label: String
            switch reason {
            case .resume: label = "resume"
            case .retry: label = "retry"
            case .startup, .postTraining: label = "startup"
            }
            print("[AudioLifecycle] duplicate \(label) ignored — startup already running")
            return
        }

        cancelListeningStartup()
        let generation = listeningStartupGeneration
        activeListeningStartupFailureMode = failureMode

        print("[AudioLifecycle] scheduleListeningStartup — reason=\(reason.rawValue) generation=\(generation)")

        isListeningStartupInProgress = true
        listeningStartupTask = Task { [weak self] in
            defer { self?.isListeningStartupInProgress = false }
            await self?.startListeningReliably(
                reason: reason,
                failureMode: failureMode,
                generation: generation
            )
        }
    }

    /// Event-driven listening startup shared by launch, retry, resume, and post-training.
    private func startListeningReliably(
        reason: ListeningStartupReason,
        failureMode: ListeningRecoveryFailureMode,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, generation == listeningStartupGeneration else { return }

        if isSetupOrTrainingInProgress, reason != .postTraining {
            #if DEBUG
            print("[AppStartup] Listening deferred — setup/training in progress")
            #endif
            return
        }

        guard panicFingerprintStore.load() != nil else {
            if !trainingModalActive {
                transition(to: .needsTraining, reason: "listening startup — no fingerprint")
            }
            return
        }

        switch AudioCaptureService.currentPermissionStatus() {
        case .granted:
            break
        case .notDetermined:
            transition(to: .microphonePermissionNeeded, reason: "listening startup — permission not determined")
            return
        case .denied:
            transition(to: .microphonePermissionDenied, reason: "listening startup — permission denied")
            return
        }

        if !trainingModalActive {
            _ = transition(
                to: .starting,
                reason: "listening startup (\(reason.rawValue))",
                options: .init(postTrainingExit: reason == .postTraining)
            )
        }

        for attempt in 1...2 {
            guard !Task.isCancelled, generation == listeningStartupGeneration else { return }

            #if DEBUG
            print("[AppStartup] Attempt \(attempt) starting")
            #endif

            clearDetectionForListeningRestart()
            audioCaptureService.stopCapture(
                reason: "listening startup attempt \(attempt) (\(reason.rawValue))"
            )

            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(Int(listeningStartupRetryBackoff * 1000)))
            }

            do {
                let captureGeneration = try startCaptureOrThrow()

                #if DEBUG
                print("[AppStartup] Capture started — generation=\(captureGeneration)")
                #endif

                guard await audioCaptureService.waitForFirstProcessedBuffer(
                    timeout: listeningBufferWaitTimeout,
                    generation: captureGeneration
                ) else {
                    throw listeningStartupError(
                        code: 5,
                        message: "No live audio buffers received."
                    )
                }

                guard !Task.isCancelled, generation == listeningStartupGeneration else { return }

                #if DEBUG
                print("[AppStartup] First buffer confirmed — generation=\(captureGeneration)")
                #endif

                guard attachDetection() else {
                    throw listeningStartupError(
                        code: 3,
                        message: "Detection could not be attached after first buffer."
                    )
                }

                guard !Task.isCancelled, generation == listeningStartupGeneration else { return }

                #if DEBUG
                print("[AppStartup] Detector attached")
                #endif

                _ = transition(
                    to: .listening,
                    reason: "listening ready (\(reason.rawValue))",
                    options: .init(postTrainingExit: reason == .postTraining)
                )

                if reason == .resume {
                    print("[AudioLifecycle] resume succeeded")
                }

                #if DEBUG
                print("[AppStartup] Listening ready")
                #endif
                return
            } catch {
                #if DEBUG
                print("[AppStartup] Attempt \(attempt) failed: \(error.localizedDescription)")
                #endif

                clearDetectionForListeningRestart()
                audioCaptureService.stopCapture(
                    reason: "listening startup attempt \(attempt) failed (\(reason.rawValue))"
                )
            }
        }

        guard !Task.isCancelled, generation == listeningStartupGeneration else { return }

        if reason == .resume {
            print("[AudioLifecycle] resume failed after retry")
        }

        applyListeningRecoveryFailure(
            listeningStartupError(code: 6, message: "Audio capture could not be restored."),
            mode: failureMode
        )
    }

    private func listeningStartupError(code: Int, message: String) -> AudioCaptureError {
        AudioCaptureError.engineStartFailed(
            underlying: NSError(
                domain: "AppCoordinator",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private func applyListeningRecoveryFailure(_ error: Error, mode: ListeningRecoveryFailureMode) {
        clearDetectionForListeningRestart()
        audioCaptureService.stopCapture(reason: "listening recovery failure")
        refreshLastTrainedDate()
        endTrainingModal()

        switch mode {
        case .paused:
            _ = transition(
                to: .paused,
                reason: "resume listening failed: \(error.localizedDescription)",
                options: .init(force: true)
            )
            #if DEBUG
            print("[Listening] ResumeListening failed — \(error.localizedDescription); status restored to paused")
            #endif

        case .audioError:
            _ = transition(
                to: .audioError(error.localizedDescription),
                reason: "listening startup failed: \(error.localizedDescription)",
                options: .init(force: true)
            )
            #if DEBUG
            print("[AppStartup] Audio Error shown after retry failure")
            #endif
        }
    }

    @discardableResult
    private func startCaptureOrThrow() throws -> UInt64 {
        let captureGeneration = try audioCaptureService.startCapture()

        let snapshot = audioCaptureService.captureActivitySnapshot()
        #if DEBUG
        print(
            "[Listening] post-startCapture snapshot — "
                + "captureActive=\(snapshot.isCapturing), "
                + "isRunning=\(snapshot.isRunning), "
                + "tapInstalled=\(snapshot.tapInstalled)"
        )
        #endif

        guard snapshot.isCapturing else {
            throw AudioCaptureError.engineStartFailed(
                underlying: NSError(
                    domain: "AppCoordinator",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Audio capture did not become active (isRunning=\(snapshot.isRunning), tapInstalled=\(snapshot.tapInstalled))."
                    ]
                )
            )
        }

        return captureGeneration
    }

    @discardableResult
    private func attachDetection() -> Bool {
        #if DEBUG
        print(
            "[Detection] attachDetection called — "
                + "isTraining=\(isTraining), status=\(appState.status), "
                + "captureActive=\(audioCaptureService.isCapturing)"
        )
        #endif

        guard !isTraining else {
            #if DEBUG
            print("[Detection] attachDetection skipped — training still active")
            #endif
            return false
        }

        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)

        guard let fingerprint = panicFingerprintStore.load() else {
            #if DEBUG
            print("[Detection] attachDetection aborted — no stored fingerprint")
            #endif
            return false
        }

        appState.lastTrainedAt = fingerprint.createdAt

        guard audioCaptureService.isCapturing else {
            #if DEBUG
            print("[Detection] attachDetection aborted — audio capture is not active")
            #endif
            return false
        }

        guard audioCaptureService.inputSampleRate != nil else {
            #if DEBUG
            print("[Detection] attachDetection aborted — microphone input unavailable")
            #endif
            return false
        }

        let sampleRate = AudioCaptureService.targetProcessingSampleRate

        let detector = PanicDetector(fingerprint: fingerprint)
        detector.onMatch = { [weak self] result in
            Task { @MainActor in
                self?.handlePanicDetected(confidence: result.confidence)
            }
        }
        detector.start(sampleRate: sampleRate)
        panicDetector = detector
        audioPipeline.setDetector(detector)

        #if DEBUG
        let hardwareRate = audioCaptureService.hardwareSampleRate ?? 0
        print(
            "[Detection] attachDetection complete — detector attached, "
                + "hardwareRate=\(String(format: "%.0f", hardwareRate)), "
                + "processingRate=\(String(format: "%.0f", sampleRate)), "
                + "fingerprintRate=\(String(format: "%.0f", fingerprint.processingSampleRate)), "
                + "captureActive=\(audioCaptureService.isCapturing)"
        )
        #endif
        return true
    }

    private func clearDetectionForListeningRestart() {
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
    }

    // TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.
    func copyDiagnosticsToClipboard() {
        let report = DiagnosticsReportService.makeReport(snapshot: makeDiagnosticsSnapshot())
        DiagnosticsReportService.copyToClipboard(report)

        appState.diagnosticsCopyConfirmation = "Diagnostics copied to clipboard."

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if self.appState.diagnosticsCopyConfirmation == "Diagnostics copied to clipboard." {
                self.appState.diagnosticsCopyConfirmation = nil
            }
        }

        #if DEBUG
        print("[Diagnostics] Copied diagnostics report to clipboard")
        #endif
    }

    private func makeDiagnosticsSnapshot() -> DiagnosticsSnapshot {
        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let bundlePath = bundle.bundlePath
        let entitlements = DiagnosticsReportService.currentProcessEntitlements()
        let fingerprint = panicFingerprintStore.load()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmost?.bundleIdentifier ?? "none"
        let frontmostName = frontmost?.localizedName ?? "none"

        return DiagnosticsSnapshot(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            executablePath: bundle.executablePath ?? "unknown",
            bundlePath: bundlePath,
            installLocation: DiagnosticsReportService.installLocationLabel(bundlePath: bundlePath),
            buildConfiguration: DiagnosticsReportService.buildConfigurationLabel(),
            entitlementAudioInput: DiagnosticsReportService.entitlementValue(
                entitlements,
                key: "com.apple.security.device.audio-input"
            ),
            entitlementAppSandbox: DiagnosticsReportService.entitlementValue(
                entitlements,
                key: "com.apple.security.app-sandbox"
            ),
            entitlementGetTaskAllow: DiagnosticsReportService.entitlementValue(
                entitlements,
                key: "com.apple.security.get-task-allow"
            ),
            microphonePermission: DiagnosticsReportService.microphonePermissionLabel(),
            microphoneUsageDescriptionPresent: info?["NSMicrophoneUsageDescription"] != nil,
            microphoneUsageDescription: info?["NSMicrophoneUsageDescription"] as? String,
            fingerprintStored: panicFingerprintStore.hasStoredData,
            fingerprintVersion: fingerprint.map { String($0.version) } ?? "n/a",
            fingerprintConsistency: fingerprint.map {
                String(format: "%.2f", $0.trainingConsistency)
            } ?? "n/a",
            appStatus: DiagnosticsReportService.appStatusLabel(appState.status),
            audioCaptureActive: audioCaptureService.isCapturing,
            panicDetectorAttached: panicDetector != nil,
            detectionPaused: appState.status == .paused,
            frontmostAppName: frontmostName,
            frontmostAppBundleID: frontmostBundleID,
            frontmostIsSupportedBrowser: BrowserHidingService.supportedBrowserBundleIDs
                .contains(frontmostBundleID),
            supportedBrowserBundleIDs: BrowserHidingService.supportedBrowserBundleIDs.sorted()
        )
    }

    func requestMicrophonePermission() {
        Task {
            #if DEBUG
            print("[Permission] Menu action: Grant Microphone Permission…")
            #endif
            let permission = await ensureMicrophonePermission(
                requestIfNeeded: true,
                openSettingsIfDenied: true,
                callSite: "Menu.GrantMicrophonePermission"
            )
            #if DEBUG
            print("[Permission] Menu action result=\(permission)")
            #endif
            if permission == .granted {
                if isSetupOrTrainingInProgress {
                    #if DEBUG
                    print("[Startup] Listening deferred — setup/training in progress")
                    #endif
                } else {
                    await beginAudioCapture()
                }
            }
        }
    }

    func refreshLastTrainedDate() {
        appState.lastTrainedAt = panicFingerprintStore.lastTrainedDate()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        NSApplication.shared.setActivationPolicy(.accessory)

        #if DEBUG
        print("[Startup] App launch started (accessory / menu bar mode)")
        #endif

        evaluateStartupSetupPresentation()

        Task {
            refreshLastTrainedDate()
            guard !isSetupOrTrainingInProgress else {
                #if DEBUG
                print("[AppStartup] Startup listening skipped — setup/training in progress")
                #endif
                return
            }
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

        Task { [weak self] in
            await self?.startTrainingAfterPermissionCheck()
        }
    }

    private func startTrainingAfterPermissionCheck() async {
        #if DEBUG
        print("[Permission] Training start — checking microphone permission")
        #endif

        let permission = await ensureMicrophonePermission(
            requestIfNeeded: true,
            callSite: "Training.StartTraining"
        )

        #if DEBUG
        print("[Permission] Training start — permission result=\(permission)")
        #endif

        switch permission {
        case .granted:
            beginTrainingSession()

        case .denied:
            presentMicrophoneDeniedForTraining()

        case .notDetermined:
            transition(
                to: .microphonePermissionNeeded,
                reason: "training start permission request failed"
            )
            appState.trainingUIPhase = .failed(
                "Microphone permission could not be requested. Try Grant Microphone Permission… from the menu."
            )
        }
    }

    private func beginTrainingSession() {
        guard !isTraining else { return }

        #if DEBUG
        print("[Training] Preparing audio capture for training")
        #endif

        cancelListeningStartup()
        stopListeningCaptureIfNeeded(reason: "training session starting")
        beginTrainingModal(reason: "training session started")

        do {
            try prepareAudioCaptureForTraining()
        } catch {
            failTraining(error.localizedDescription)
            return
        }

        #if DEBUG
        print("[Training] Audio capture ready for training")
        print("[Training] Detection paused")
        #endif

        trainingTask?.cancel()
        isTraining = true
        trainingTask = Task { [weak self] in
            await self?.runTrainingSession()
        }
    }

    /// Ensures a live capture session owned by training, restarting once if needed.
    private func prepareAudioCaptureForTraining() throws {
        // If listening left a half-dead session, tear it down so training owns a clean engine.
        if audioCaptureService.isCapturing, audioCaptureService.inputSampleRate == nil {
            #if DEBUG
            print("[Training] Stopping listening capture before training (capture active but sample rate unavailable)")
            #endif
            audioCaptureService.stopCapture(reason: "training prep — stale capture")
        }

        if !audioCaptureService.isCapturing {
            try audioCaptureService.startCapture()
        }

        if audioCaptureService.inputSampleRate != nil {
            return
        }

        #if DEBUG
        print("[Training] Sample rate unavailable after start — restarting capture once for training")
        #endif
        audioCaptureService.stopCapture(reason: "training prep — sample rate retry")
        try audioCaptureService.startCapture()

        guard audioCaptureService.isCapturing, audioCaptureService.inputSampleRate != nil else {
            throw AudioCaptureError.engineStartFailed(
                underlying: NSError(
                    domain: "AppCoordinator",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone input is unavailable."]
                )
            )
        }
    }

    /// Returns the current microphone permission, requesting it when undetermined
    /// and `requestIfNeeded` is true (user-initiated actions only).
    @discardableResult
    private func ensureMicrophonePermission(
        requestIfNeeded: Bool,
        openSettingsIfDenied: Bool = false,
        callSite: String
    ) async -> MicrophonePermissionStatus {
        let initial = AudioCaptureService.currentPermissionStatus()
        #if DEBUG
        print(
            "[Permission] ensureMicrophonePermission callSite=\(callSite) "
                + "initial=\(initial) requestIfNeeded=\(requestIfNeeded) "
                + "openSettingsIfDenied=\(openSettingsIfDenied)"
        )
        #endif

        switch initial {
        case .granted:
            return .granted

        case .denied:
            transition(to: .microphonePermissionDenied, reason: "permission denied (\(callSite))")
            if openSettingsIfDenied {
                #if DEBUG
                print("[Permission] Opening System Settings because permission is denied (callSite=\(callSite))")
                #endif
                openMicrophoneSystemSettings()
            }
            return .denied

        case .notDetermined:
            guard requestIfNeeded else {
                transition(to: .microphonePermissionNeeded, reason: "permission not determined (\(callSite))")
                #if DEBUG
                print("[Permission] notDetermined — not requesting (callSite=\(callSite))")
                #endif
                return .notDetermined
            }

            transition(to: .microphonePermissionNeeded, reason: "requesting microphone permission (\(callSite))")

            #if DEBUG
            print("[Permission] Status is notDetermined — calling native request API (callSite=\(callSite))")
            #endif

            let result = await AudioCaptureService.requestPermission(callSite: callSite)

            #if DEBUG
            print("[Permission] Native request finished with result=\(result) (callSite=\(callSite))")
            #endif

            switch result {
            case .granted:
                return .granted

            case .denied:
                transition(to: .microphonePermissionDenied, reason: "permission denied after request (\(callSite))")
                return .denied

            case .notDetermined:
                transition(to: .microphonePermissionNeeded, reason: "permission still not determined (\(callSite))")
                return .notDetermined
            }
        }
    }

    private func presentMicrophoneDeniedForTraining() {
        transition(to: .microphonePermissionDenied, reason: "training denied — microphone permission")
        appState.trainingUIPhase = .failed(
            "Microphone access is required to train your cough.\n\nEnable Ahem in System Settings → Privacy & Security → Microphone."
        )
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
        audioCaptureService.stopCapture(reason: "app quit")
        NSApplication.shared.terminate(nil)
    }

    /// Observes current microphone permission and starts capture when already granted.
    /// Never prompts — permission dialogs are user-action only.
    private func beginAudioCapture() async {
        if panicFingerprintStore.hasStoredData {
            #if DEBUG
            print("[AppStartup] Stored fingerprint exists")
            #endif
        }

        let permission = AudioCaptureService.currentPermissionStatus()
        #if DEBUG
        print("[AppStartup] Microphone permission status: \(permission)")
        #endif

        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[AppStartup] Listening deferred — setup/training in progress")
            #endif
            return
        }

        switch permission {
        case .notDetermined:
            transition(to: .microphonePermissionNeeded, reason: "startup — microphone permission not determined")
            #if DEBUG
            print("[AppStartup] Microphone permission notDetermined — detection inactive until user grants")
            #endif

        case .granted:
            guard panicFingerprintStore.load() != nil else {
                transition(to: .needsTraining, reason: "startup — fingerprint missing")
                return
            }

            scheduleListeningStartup(reason: .startup, failureMode: .audioError)

        case .denied:
            transition(to: .microphonePermissionDenied, reason: "startup — microphone permission denied")
            #if DEBUG
            print("[AppStartup] Startup failed: microphone permission denied")
            #endif
        }
    }

    private func handlePanicDetected(confidence: Double) {
        #if DEBUG
        let hideAllowed = appState.status == .listening || appState.status == .panicDetected
        print(
            "[Panic] Detection callback received — "
                + "confidence: \(String(format: "%.2f", confidence)), "
                + "status: \(appState.status), "
                + "isTraining: \(isTraining), "
                + "hideAllowed: \(hideAllowed)"
        )
        #endif

        guard appState.status == .listening || appState.status == .panicDetected else {
            #if DEBUG
            print("[Panic] Hide suppressed — app status does not allow browser hiding")
            #endif
            return
        }

        #if DEBUG
        print("[Panic] Proceeding with browser hide")
        #endif

        let hideResult = browserHidingService.hideActiveBrowserIfSupported()
        logBrowserHidingResult(hideResult)

        detectionResetTask?.cancel()
        _ = transition(to: .panicDetected, reason: "cough detected")

        detectionResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.panicDetectedDisplayDuration ?? 1.0))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if case .panicDetected = self.appState.status {
                _ = self.transition(to: .listening, reason: "panic display complete")
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
            #if DEBUG
            print("[Training] Training session ended")
            #endif
        }

        #if DEBUG
        print("[Training] Preparing audio capture for training")
        #endif

        do {
            try prepareAudioCaptureForTraining()
        } catch {
            failTraining(error.localizedDescription)
            return
        }

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            failTraining("Microphone input is unavailable.")
            return
        }

        #if DEBUG
        print("[Training] Audio capture ready for training")
        print("[Training] Training started")
        #endif

        var collectedSamples: [SampleFeatures] = []

        for sampleIndex in 1...3 {
            if Task.isCancelled { return }

            _ = transition(
                to: .training(sample: sampleIndex, total: 3),
                reason: "training sample \(sampleIndex)/3"
            )

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
                        + "processingSampleRate=\(String(format: "%.0f", fingerprint.processingSampleRate)) "
                        + "with averageRMS: \(fingerprint.averageRMS), "
                        + "consistency: \(String(format: "%.2f", fingerprint.trainingConsistency))"
                )
                #endif
                return
            }

            _ = transition(to: .trainingComplete, reason: "training samples saved")
            appState.trainingUIPhase = .succeeded

            #if DEBUG
            print("[Training] Training completed")
            print(
                "[Training] Saved panic fingerprint v\(fingerprint.version) "
                    + "processingSampleRate=\(String(format: "%.0f", fingerprint.processingSampleRate)) "
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

        #if DEBUG
        print("[Training] Training complete — starting reliable listening")
        #endif

        scheduleListeningStartup(reason: .postTraining, failureMode: .audioError)
    }

    private func failTraining(_ message: String) {
        endTrainingModal()
        _ = transition(to: .trainingFailed(message), reason: message, options: .init(force: true))
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
