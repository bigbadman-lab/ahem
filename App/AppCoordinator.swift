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
    private var isStartingListening = false
    private var explicitTrainingStartInProgress = false
    private var trainingAwaitingUserConfirmation = false

    private let trainingRecordingWindowSeconds: TimeInterval = 5.0
    private let trainingCountdownSeconds = 5
    private let trainingInterSamplePause: TimeInterval = 1.0
    private let maxQuietSampleRetriesPerSample = 2
    private let trainingCompleteDisplayDuration: TimeInterval = 2.0
    private let panicDetectedDisplayDuration: TimeInterval = 1.0
    private let minimumTrainingConsistency: Double = DiagnosticsLog.minimumTrainingConsistency
    private let listeningBufferWaitTimeout: TimeInterval = 3.0
    private let postTrainingAudioCleanupDelay: TimeInterval = 0.5

    private var listeningStartupTask: Task<Void, Never>?
    private var trainingModalActive = false
    private var trainingWatchdogTask: Task<Void, Never>?
    private var startingWatchdogTask: Task<Void, Never>?
    private var startingWatchdogRetried = false
    private let trainingWatchdogDuration: TimeInterval = 90
    private let startingWatchdogDuration: TimeInterval = 15
    private let trainingTimeoutDuration: TimeInterval = 90

    private enum ListeningStartupReason: String {
        case startup
        case postTraining
    }

    init(appState: AppState) {
        self.appState = appState

        #if DEBUG
        print("[Startup] AppCoordinator init")
        #endif
        DiagnosticsLog.shared.log(category: "Startup", "AppCoordinator initialized")

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

        if trainingAwaitingUserConfirmation || AppStateMachine.phase(of: current) == .trainingComplete {
            let toPhase = AppStateMachine.phase(of: newStatus)
            if (toPhase == .starting || toPhase == .listening), !options.userConfirmedTrainingCompletion {
                AppStateMachine.logBlocked(
                    from: current,
                    to: newStatus,
                    reason: "training completion not confirmed — \(reason)"
                )
                if toPhase == .starting {
                    print("[Training] blocked transition to Starting before confirmation")
                }
                print("[Training] blocked listening start — waiting for user confirmation")
                return false
            }
        }

        if AppStateMachine.phase(of: newStatus) == .training, !options.userInitiated {
            AppStateMachine.logBlocked(
                from: current,
                to: newStatus,
                reason: "automatic transition to training blocked"
            )
            print("[StateMachine] BLOCKED automatic transition to training")
            return false
        }

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
        DiagnosticsLog.shared.log(
            category: "StateMachine",
            "transition \(DiagnosticsReportService.appStatusLabel(current)) → \(DiagnosticsReportService.appStatusLabel(newStatus)) — \(reason)"
        )
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
        if options.userConfirmedTrainingCompletion, toPhase == .starting || toPhase == .listening { return true }
        if options.postTrainingExit, toPhase == .starting || toPhase == .listening { return true }
        return false
    }

    private func handleStatusSideEffects(from: AppStatus, to: AppStatus) {
        if AppStateMachine.phase(of: from) == .training {
            cancelTrainingWatchdog()
        }

        if AppStateMachine.phase(of: to) == .training
            || (AppStateMachine.phase(of: to) == .trainingComplete && trainingAwaitingUserConfirmation) {
            scheduleTrainingWatchdog()
        }

        if AppStateMachine.phase(of: from) == .starting {
            cancelStartingWatchdog()
            startingWatchdogRetried = false
        }

        if AppStateMachine.phase(of: to) == .starting {
            scheduleStartingWatchdog()
        }

        if AppStateMachine.phase(of: to) == .listening {
            endTrainingModal()
            cancelStartingWatchdog()
        }

        if AppStateMachine.phase(of: to) == .trainingFailed {
            endTrainingModal()
        }
    }

    private func scheduleTrainingWatchdog() {
        trainingWatchdogTask?.cancel()
        trainingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.trainingWatchdogDuration ?? 90))
            guard let self, !Task.isCancelled else { return }
            guard AppStateMachine.phase(of: self.appState.status) == .training
                || (self.appState.status == .trainingComplete && self.trainingAwaitingUserConfirmation) else { return }

            print("[StateMachine] training watchdog fired")
            self.failTraining("Training timed out. Please try again.")
        }
    }

    private func cancelTrainingWatchdog() {
        trainingWatchdogTask?.cancel()
        trainingWatchdogTask = nil
    }

    private func scheduleStartingWatchdog() {
        startingWatchdogTask?.cancel()
        startingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.startingWatchdogDuration ?? 15))
            guard let self, !Task.isCancelled else { return }
            guard case .starting = self.appState.status else { return }
            guard self.panicFingerprintStore.load() != nil else { return }

            print("[StateMachine] starting watchdog fired")

            if !self.startingWatchdogRetried {
                self.startingWatchdogRetried = true
                self.scheduleListeningStartup(reason: .startup)
                return
            }

            switch AudioCaptureService.currentPermissionStatus() {
            case .denied:
                _ = self.transition(
                    to: .microphonePermissionDenied,
                    reason: "starting watchdog — microphone permission denied",
                    options: .init(force: true)
                )
            case .notDetermined:
                _ = self.transition(
                    to: .microphonePermissionNeeded,
                    reason: "starting watchdog — microphone permission needed",
                    options: .init(force: true)
                )
            case .granted:
                _ = self.transition(
                    to: .microphonePermissionNeeded,
                    reason: "starting watchdog — listening could not start",
                    options: .init(force: true)
                )
            }
        }
    }

    private func cancelStartingWatchdog() {
        startingWatchdogTask?.cancel()
        startingWatchdogTask = nil
    }

    private func beginTrainingModal(reason: String) {
        trainingModalActive = true
        cancelListeningStartup()
        _ = transition(
            to: .training(sample: 1, total: 3),
            reason: reason,
            options: .init(userInitiated: true, force: true)
        )
    }

    private func endTrainingModal() {
        guard trainingModalActive else { return }
        trainingModalActive = false
        cancelTrainingWatchdog()
    }

    private func cancelListeningStartup() {
        listeningStartupTask?.cancel()
        listeningStartupTask = nil
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

    /// True while an active training session owns the microphone and listening must not race it.
    private var isSetupOrTrainingInProgress: Bool {
        isTraining || trainingModalActive
    }

    private var suppressBackgroundStatusChanges: Bool {
        trainingModalActive || isTraining || explicitTrainingStartInProgress
    }

    func prepareOnboarding() {
        appState.onboardingPhase = .welcome
    }

    /// Evaluates permission + fingerprint once at launch and queues a setup window if needed.
    /// Does not request microphone permission or enter Training automatically.
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
                DiagnosticsLog.shared.log(category: "Onboarding", "skipped — fingerprint exists, permission granted")
                if !onboardingStore.hasCompletedOnboarding {
                    onboardingStore.markCompleted()
                }
                return
            }

            #if DEBUG
            print("[Onboarding] Permission granted but no fingerprint — presenting setup UI")
            #endif
            DiagnosticsLog.shared.log(category: "Onboarding", "shown — permission granted, no fingerprint")
            if onboardingStore.hasCompletedOnboarding {
                prepareTrainingUI()
                appState.setupPresentationRequest = .training
            } else {
                prepareOnboarding()
                appState.setupPresentationRequest = .onboarding
            }

        case .notDetermined, .denied:
            #if DEBUG
            print("[Onboarding] Permission not granted — presenting onboarding")
            #endif
            DiagnosticsLog.shared.log(
                category: "Onboarding",
                "shown — permission=\(permission), hasFingerprint=\(hasFingerprint)"
            )
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
        confirmTrainingCompleteAndStartListening()

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
        _ = transition(to: .needsTraining, reason: "onboarding — awaiting explicit training start")

        #if DEBUG
        print("[Onboarding] Training welcome shown — waiting for user to start training")
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
        if trainingAwaitingUserConfirmation {
            #if DEBUG
            print("[Training] Window closed before user confirmation — listening not started")
            #endif
            dismissTrainingUI()
            endTrainingModal()
            return
        }

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
        guard !trainingAwaitingUserConfirmation else { return }

        trainingTask?.cancel()
        isTraining = false
        dismissTrainingUI()
        endTrainingModal()

        if panicFingerprintStore.load() != nil, appState.status != .listening {
            _ = transition(
                to: .starting,
                reason: "training window closed after success",
                options: .init(force: true, postTrainingExit: true, userConfirmedTrainingCompletion: true)
            )
            schedulePostTrainingListening()
        } else if panicFingerprintStore.load() == nil {
            _ = transition(to: .needsTraining, reason: "training window closed after success", options: .init(force: true))
        }
    }

    private func cancelTrainingSession() {
        trainingTask?.cancel()
        explicitTrainingStartInProgress = false
        trainingAwaitingUserConfirmation = false
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

        if panicFingerprintStore.load() != nil {
            _ = transition(to: .starting, reason: "training cancelled", options: .init(force: true))
            scheduleListeningStartup(reason: .startup)
        } else {
            _ = transition(to: .needsTraining, reason: "training cancelled", options: .init(force: true))
        }

        #if DEBUG
        print("[Training] Training cancellation complete")
        #endif
    }

    #if DEBUG
    func pauseListening() {
        guard appState.status == .listening || appState.status == .panicDetected else { return }
        guard !isStartingListening else { return }

        detectionResetTask?.cancel()
        detectionResetTask = nil
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
        cancelListeningStartup()
        audioCaptureService.stopCapture(reason: "user paused listening")
        _ = transition(to: .paused, reason: "user paused listening")
    }

    func resumeListening() {
        guard appState.status == .paused else { return }
        scheduleListeningStartup(reason: .startup)
    }

    func retryListening() {
        guard case .audioError = appState.status else { return }
        guard !isTraining else { return }
        scheduleListeningStartup(reason: .startup)
    }
    #endif

    private func scheduleListeningStartup(reason: ListeningStartupReason) {
        guard !isStartingListening else {
            #if DEBUG
            print("[Startup] startListening ignored — already in progress")
            #endif
            return
        }

        cancelListeningStartup()
        listeningStartupTask = Task { [weak self] in
            await self?.startListening(reason: reason)
        }
    }

    /// Post-training: fully tear down training audio, pause briefly, then cold-start listening.
    private func schedulePostTrainingListening() {
        guard !trainingAwaitingUserConfirmation else {
            print("[Training] blocked listening start — waiting for user confirmation")
            return
        }

        guard !isStartingListening else {
            print("[Startup] post-confirmation listening ignored — startup already in progress")
            return
        }

        cancelListeningStartup()
        listeningStartupTask = Task { [weak self] in
            await self?.runPostTrainingListeningStartup()
        }
    }

    private func runPostTrainingListeningStartup() async {
        isStartingListening = true
        defer { isStartingListening = false }

        guard !Task.isCancelled else { return }

        print("[Training] stopping training audio before listening")
        activeSampleCollector = nil
        activeSampleCapture = nil
        audioPipeline.setSampleCollector(nil)
        clearDetectionForListeningRestart()
        audioCaptureService.stopCapture(reason: "post-confirmation teardown")
        print("[Training] training audio stopped")

        let cleanupNanos = UInt64(postTrainingAudioCleanupDelay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: cleanupNanos)

        guard !Task.isCancelled else { return }

        print("[Training] starting fresh listening session")
        await startListeningFromSavedFingerprint(reason: .postTraining)
    }

    /// Called when the user taps the final training completion button.
    func confirmTrainingCompleteAndStartListening() {
        guard trainingAwaitingUserConfirmation || appState.status == .trainingComplete else {
            if appState.status == .listening { return }
            return
        }

        print("[Training] user confirmed completion")
        trainingAwaitingUserConfirmation = false
        explicitTrainingStartInProgress = false
        dismissTrainingUI()
        endTrainingModal()

        guard panicFingerprintStore.load() != nil else {
            transition(to: .needsTraining, reason: "training confirmed — fingerprint missing")
            return
        }

        _ = transition(
            to: .starting,
            reason: "user confirmed training completion",
            options: .init(
                force: true,
                postTrainingExit: true,
                userConfirmedTrainingCompletion: true
            )
        )

        print("[Startup] post-confirmation cold-start path requested")
        schedulePostTrainingListening()
    }

    /// Entry for cold launch / reopen. Post-training uses `runPostTrainingListeningStartup()` first.
    private func startListening(reason: ListeningStartupReason) async {
        isStartingListening = true
        defer { isStartingListening = false }

        guard !Task.isCancelled else { return }

        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — training in progress")
            #endif
            return
        }

        await startListeningFromSavedFingerprint(reason: reason)
    }

    /// Shared listening startup from a clean audio slate (same path for reopen and post-training).
    private func startListeningFromSavedFingerprint(reason: ListeningStartupReason) async {
        guard panicFingerprintStore.load() != nil else {
            transition(to: .needsTraining, reason: "listening startup — no fingerprint")
            if reason == .postTraining {
                print("[Startup] post-training failed: no saved fingerprint")
            }
            return
        }

        switch AudioCaptureService.currentPermissionStatus() {
        case .granted:
            break
        case .notDetermined:
            transition(to: .microphonePermissionNeeded, reason: "listening startup — permission not determined")
            if reason == .postTraining {
                print("[Startup] post-training failed: microphone permission not determined")
            }
            return
        case .denied:
            transition(to: .microphonePermissionDenied, reason: "listening startup — permission denied")
            if reason == .postTraining {
                print("[Startup] post-training failed: microphone permission denied")
            }
            return
        }

        if reason == .postTraining {
            print("[Startup] post-confirmation fingerprint loaded")
        } else if panicFingerprintStore.hasStoredData {
            print("[Startup] starting from saved fingerprint")
        }

        _ = transition(
            to: .starting,
            reason: "listening startup (\(reason.rawValue))",
            options: .init(force: reason == .postTraining, postTrainingExit: reason == .postTraining)
        )

        clearDetectionForListeningRestart()
        audioCaptureService.stopCapture(reason: "listening startup (\(reason.rawValue))")

        do {
            let captureGeneration = try startCaptureOrThrow()

            guard await audioCaptureService.waitForFirstProcessedBuffer(
                timeout: listeningBufferWaitTimeout,
                generation: captureGeneration
            ) else {
                clearDetectionForListeningRestart()
                audioCaptureService.stopCapture(reason: "no first buffer")
                if reason == .postTraining {
                    print("[Startup] post-training failed: no first processed buffer")
                }
                return
            }

            guard !Task.isCancelled else { return }

            if reason == .postTraining {
                print("[Startup] post-confirmation first buffer confirmed")
            }

        guard attachDetection() else {
                clearDetectionForListeningRestart()
                audioCaptureService.stopCapture(reason: "detector attach failed")
                if reason == .postTraining {
                    print("[Startup] post-training failed: detector attach failed")
                }
                return
            }

            guard !Task.isCancelled else { return }

            if reason == .postTraining {
                print("[Startup] post-training detector attached")
            }

            _ = transition(
                to: .listening,
                reason: "listening ready (\(reason.rawValue))",
                options: .init(force: reason == .postTraining, postTrainingExit: reason == .postTraining)
            )

            if reason == .postTraining {
                print("[Startup] post-confirmation ready")
            } else {
                print("[Startup] ready")
            }
            DiagnosticsLog.shared.log(
                category: "Startup",
                "listening ready — status=listening, detectorAttached=\(panicDetector != nil), captureActive=\(audioCaptureService.isCapturing)"
            )
        } catch {
            clearDetectionForListeningRestart()
            audioCaptureService.stopCapture(reason: "listening startup failed")
            if reason == .postTraining {
                print("[Startup] post-training failed: \(error.localizedDescription)")
            } else {
                #if DEBUG
                print("[Startup] Listening startup failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    @discardableResult
    private func startCaptureOrThrow() throws -> UInt64 {
        let captureGeneration = try audioCaptureService.startCapture()
        DiagnosticsLog.shared.log(
            category: "Audio",
            "capture started — generation=\(captureGeneration), active=\(audioCaptureService.isCapturing)"
        )

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

        guard !isTraining, !trainingAwaitingUserConfirmation, !trainingModalActive else {
            if trainingAwaitingUserConfirmation || trainingModalActive {
                print("[Training] blocked listening start — waiting for user confirmation")
            }
            #if DEBUG
            if isTraining {
                print("[Detection] attachDetection skipped — training still active")
            }
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
            DiagnosticsLog.shared.log(category: "Detection", "attach aborted — no stored fingerprint")
            return false
        }

        DiagnosticsLog.shared.log(
            category: "Fingerprint",
            "loaded for detection — v\(fingerprint.version), sampleRate=\(String(format: "%.0f", fingerprint.processingSampleRate))Hz"
        )

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

        DiagnosticsLog.shared.log(
            category: "Detection",
            "configured and started — threshold=\(String(format: "%.2f", PanicDetector.Configuration.default.threshold)), "
                + "sampleRate=\(String(format: "%.0f", sampleRate)), "
                + "fingerprint v\(fingerprint.version)"
        )

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
        if panicDetector != nil {
            DiagnosticsLog.shared.log(category: "Detection", "stopped — listening restart")
        }
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
    }

    // TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.
    func copyDiagnosticsToClipboard() {
        DiagnosticsLog.shared.log(category: "Diagnostics", "Copy Diagnostics requested from menu")
        let snapshot = makeDiagnosticsSnapshot()
        DiagnosticsLog.shared.copyReportToClipboard(
            snapshot: snapshot,
            fingerprint: panicFingerprintStore.load()
        )

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

        DiagnosticsLog.shared.log(category: "Startup", "app launch started (accessory / menu bar mode)")

        #if DEBUG
        print("[Startup] App launch started (accessory / menu bar mode)")
        #endif

        deriveLaunchState()
        evaluateStartupSetupPresentation()

        Task {
            refreshLastTrainedDate()
            await beginAudioCapture()
        }
    }

    /// Derives initial status from persisted facts only. Never restores Training.
    private func deriveLaunchState() {
        let permission = AudioCaptureService.currentPermissionStatus()
        let hasFingerprint = panicFingerprintStore.load() != nil

        print(
            "[StateMachine] launch derived state — "
                + "fingerprintExists=\(hasFingerprint), micPermission=\(permission)"
        )
        DiagnosticsLog.shared.log(
            category: "Startup",
            "launch derived state — fingerprintExists=\(hasFingerprint), micPermission=\(permission)"
        )

        appState.onboardingPhase = .idle
        appState.trainingUIPhase = .idle
        isTraining = false
        trainingModalActive = false
        explicitTrainingStartInProgress = false
        trainingAwaitingUserConfirmation = false

        switch permission {
        case .granted:
            appState.status = hasFingerprint ? .starting : .needsTraining
        case .notDetermined:
            appState.status = hasFingerprint ? .starting : .needsTraining
        case .denied:
            appState.status = .microphonePermissionDenied
        }
    }

    func startTraining() {
        guard !isTraining else {
            #if DEBUG
            print("[Training] Training already in progress — request ignored")
            #endif
            return
        }

        DiagnosticsLog.shared.log(category: "Training", "started — user requested training")
        trainingAwaitingUserConfirmation = false
        explicitTrainingStartInProgress = true
        Task { [weak self] in
            await self?.startTrainingAfterPermissionCheck()
            if self?.isTraining != true, self?.trainingModalActive != true {
                self?.explicitTrainingStartInProgress = false
            }
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
            if !suppressBackgroundStatusChanges {
                transition(
                    to: .microphonePermissionNeeded,
                    reason: "training start permission request failed"
                )
            }
            appState.trainingUIPhase = .failed(
                "Microphone permission could not be requested. Try Grant Microphone Permission… from the menu."
            )
        }
    }

    private func beginTrainingSession() {
        guard !isTraining else { return }

        print("[Training] explicit training started")
        DiagnosticsLog.shared.log(category: "Training", "session began — explicit user training start")
        explicitTrainingStartInProgress = false

        cancelListeningStartup()
        stopListeningCaptureIfNeeded(reason: "training session starting")
        beginTrainingModal(reason: "explicit user training start")

        do {
            try prepareAudioCaptureForTraining()
        } catch {
            failTraining(error.localizedDescription)
            return
        }

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
        DiagnosticsLog.shared.log(
            category: "Permission",
            "ensureMicrophonePermission callSite=\(callSite) initial=\(initial) "
                + "requestIfNeeded=\(requestIfNeeded)"
        )
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
            if !suppressBackgroundStatusChanges {
                transition(to: .microphonePermissionDenied, reason: "permission denied (\(callSite))")
            }
            if openSettingsIfDenied {
                #if DEBUG
                print("[Permission] Opening System Settings because permission is denied (callSite=\(callSite))")
                #endif
                openMicrophoneSystemSettings()
            }
            return .denied

        case .notDetermined:
            guard requestIfNeeded else {
                if !suppressBackgroundStatusChanges {
                    transition(to: .microphonePermissionNeeded, reason: "permission not determined (\(callSite))")
                }
                #if DEBUG
                print("[Permission] notDetermined — not requesting (callSite=\(callSite))")
                #endif
                return .notDetermined
            }

            if !suppressBackgroundStatusChanges {
                transition(to: .microphonePermissionNeeded, reason: "requesting microphone permission (\(callSite))")
            }

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
                if !suppressBackgroundStatusChanges {
                    transition(to: .microphonePermissionDenied, reason: "permission denied after request (\(callSite))")
                }
                return .denied

            case .notDetermined:
                if !suppressBackgroundStatusChanges {
                    transition(to: .microphonePermissionNeeded, reason: "permission still not determined (\(callSite))")
                }
                return .notDetermined
            }
        }
    }

    private func presentMicrophoneDeniedForTraining() {
        if !suppressBackgroundStatusChanges {
            transition(to: .microphonePermissionDenied, reason: "training denied — microphone permission")
        }
        appState.trainingUIPhase = .failed(
            "Microphone access is required to train your cough.\n\nEnable Ahem in System Settings → Privacy & Security → Microphone."
        )
    }

    func quit() {
        DiagnosticsLog.shared.log(category: "Startup", "app quit requested")
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
            print("[Startup] starting from saved fingerprint")
        }

        let permission = AudioCaptureService.currentPermissionStatus()

        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — training in progress")
            #endif
            return
        }

        switch permission {
        case .notDetermined:
            if !suppressBackgroundStatusChanges {
                transition(to: .microphonePermissionNeeded, reason: "startup — microphone permission not determined")
            }

        case .granted:
            guard panicFingerprintStore.load() != nil else {
                transition(to: .needsTraining, reason: "startup — fingerprint missing")
                return
            }

            scheduleListeningStartup(reason: .startup)

        case .denied:
            if !suppressBackgroundStatusChanges {
                transition(to: .microphonePermissionDenied, reason: "startup — microphone permission denied")
            }
        }
    }

    private func handlePanicDetected(confidence: Double) {
        DiagnosticsLog.shared.log(
            category: "Detection",
            "trigger callback received — confidence=\(String(format: "%.2f", confidence)), status=\(DiagnosticsReportService.appStatusLabel(appState.status))"
        )

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
            DiagnosticsLog.shared.log(
                category: "Detection",
                "trigger callback suppressed — status does not allow browser hiding"
            )
            #if DEBUG
            print("[Panic] Hide suppressed — app status does not allow browser hiding")
            #endif
            return
        }

        DiagnosticsLog.shared.log(category: "BrowserHiding", "hide requested — proceeding from detection trigger")

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
        switch result {
        case .hidden(let bundleIdentifier, let localizedName, let confirmation):
            let confirmationLabel: String
            switch confirmation {
            case .hideReturnedTrue:
                confirmationLabel = "hide() returned true"
            case .isHiddenVerified:
                confirmationLabel = "verified via isHidden"
            }
            DiagnosticsLog.shared.recordBrowserHideAttempt(
                DiagnosticsLog.LastBrowserHideAttempt(
                    recordedAt: Date(),
                    activeAppName: localizedName,
                    bundleIdentifier: bundleIdentifier,
                    matchedSupportedBrowser: true,
                    hideCommandAttempted: true,
                    hideCommandReturnedTrue: confirmation == .hideReturnedTrue,
                    hideSucceeded: true,
                    resultSummary: "hidden (\(confirmationLabel))"
                )
            )
            #if DEBUG
            switch confirmation {
            case .hideReturnedTrue:
                print("[BrowserHiding] Hidden browser: \(localizedName) (\(bundleIdentifier))")
            case .isHiddenVerified:
                print("[BrowserHiding] Hidden browser: \(localizedName) (\(bundleIdentifier)) — confirmed via isHidden (hide() returned false)")
            }
            #endif
        case .notBrowser(let bundleIdentifier, let localizedName):
            DiagnosticsLog.shared.recordBrowserHideAttempt(
                DiagnosticsLog.LastBrowserHideAttempt(
                    recordedAt: Date(),
                    activeAppName: localizedName,
                    bundleIdentifier: bundleIdentifier,
                    matchedSupportedBrowser: false,
                    hideCommandAttempted: false,
                    hideCommandReturnedTrue: nil,
                    hideSucceeded: nil,
                    resultSummary: "not a supported browser"
                )
            )
            #if DEBUG
            print("[BrowserHiding] Frontmost app is not a supported browser: \(localizedName) (\(bundleIdentifier))")
            #endif
        case .noFrontmostApplication:
            DiagnosticsLog.shared.recordBrowserHideAttempt(
                DiagnosticsLog.LastBrowserHideAttempt(
                    recordedAt: Date(),
                    activeAppName: "none",
                    bundleIdentifier: "none",
                    matchedSupportedBrowser: false,
                    hideCommandAttempted: false,
                    hideCommandReturnedTrue: nil,
                    hideSucceeded: nil,
                    resultSummary: "no frontmost application"
                )
            )
            #if DEBUG
            print("[BrowserHiding] No frontmost application")
            #endif
        case .failed(let bundleIdentifier, let localizedName):
            DiagnosticsLog.shared.recordBrowserHideAttempt(
                DiagnosticsLog.LastBrowserHideAttempt(
                    recordedAt: Date(),
                    activeAppName: localizedName,
                    bundleIdentifier: bundleIdentifier,
                    matchedSupportedBrowser: true,
                    hideCommandAttempted: true,
                    hideCommandReturnedTrue: false,
                    hideSucceeded: false,
                    resultSummary: "hide command failed — browser still visible"
                )
            )
            #if DEBUG
            print("[BrowserHiding] Failed to hide browser: \(localizedName) (\(bundleIdentifier))")
            #endif
        }
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
            DiagnosticsLog.shared.log(category: "Training", "sample \(sampleIndex)/3 started")

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
            let consistency = fingerprint.trainingConsistency

            DiagnosticsLog.shared.recordTrainingQualityDecision(
                accepted: consistency >= minimumTrainingConsistency,
                consistency: consistency,
                rejectionReason: consistency >= minimumTrainingConsistency ? nil : "consistency_below_quality_threshold"
            )

            if consistency < minimumTrainingConsistency {
                let message = "Those sounded a little different. Try one more time with the same clear AHEM each time."
                #if DEBUG
                print("[Training] rejected — consistency below quality threshold (consistency=\(String(format: "%.2f", consistency)))")
                #endif
                DiagnosticsLog.shared.log(category: "Training", "rejected — consistency below quality threshold (\(String(format: "%.2f", consistency)))")

                failTraining(message)
                return
            }

            try panicFingerprintStore.save(fingerprint)
            appState.lastTrainedAt = fingerprint.createdAt
            playTrainingConfirmationSoundIfEnabled()

            print("[Training] sample 3 complete")
            print("[Training] fingerprint saved")
            DiagnosticsLog.shared.log(
                category: "Fingerprint",
                "saved — v\(fingerprint.version), sampleRate=\(String(format: "%.0f", fingerprint.processingSampleRate))Hz, "
                    + "samples=\(fingerprint.sampleCount)"
            )

            completeSampleCollectionAwaitingConfirmation(
                onboardingCompletion: isOnboardingSessionActive
            )
        } catch {
            #if DEBUG
            print("[Training] Training failed — \(error.localizedDescription)")
            #endif
            failTraining(error.localizedDescription)
        }
    }

    private func completeSampleCollectionAwaitingConfirmation(onboardingCompletion: Bool) {
        print("[Training] sample collection complete — waiting for user confirmation")

        activeSampleCollector = nil
        activeSampleCapture = nil
        audioPipeline.setSampleCollector(nil)
        audioCaptureService.stopCapture(reason: "training collection complete — awaiting confirmation")
        DiagnosticsLog.shared.log(category: "Audio", "capture stopped — training collection complete, awaiting confirmation")

        trainingAwaitingUserConfirmation = true
        isTraining = false

        if onboardingCompletion {
            appState.onboardingPhase = .completion
            appState.trainingUIPhase = .idle
        } else {
            appState.trainingUIPhase = .succeeded
        }

        _ = transition(
            to: .trainingComplete,
            reason: "all samples collected — awaiting user confirmation"
        )
    }

    private func failTraining(_ message: String) {
        isTraining = false
        trainingAwaitingUserConfirmation = false
        explicitTrainingStartInProgress = false
        endTrainingModal()
        _ = transition(to: .trainingFailed(message), reason: message, options: .init(force: true))
        appState.trainingUIPhase = .failed(message)

        if panicFingerprintStore.load() != nil {
            scheduleListeningStartup(reason: .startup)
        }
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
                    DiagnosticsLog.shared.log(category: "Training", "sample \(sampleIndex)/3 completed and accepted")
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
        DiagnosticsLog.shared.log(category: "Training", "sample \(sampleIndex)/3 recording began")

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
        DiagnosticsLog.shared.log(category: "Training", "sample \(sampleIndex)/3 recording finished")
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

            let smoothing = 0.52
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

        let displayMaximum = 0.09
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
