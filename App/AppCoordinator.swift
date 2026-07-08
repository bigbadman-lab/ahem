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
    private var didEvaluateStartupSetup = false
    private var didPresentStartupSetup = false
    private var isTraining = false
    private var trainingTask: Task<Void, Never>?
    private var activeSampleCollector: TrainingSampleCollector?
    private var activeSampleCapture: SampleCaptureBridge?
    private var detectionResetTask: Task<Void, Never>?
    private var trainingInputLevelSmoothed: Double = 0

    private var pauseResumeSettleWindow: TimeInterval = 0.75
    private var lastPauseCompletedAt: Date?
    private var isPausing = false
    private var isResuming = false
    private var menuStatusCommitTask: Task<Void, Never>?
    private let menuListeningCommitDebounce: TimeInterval = 0.35
    private var heldMenuStatusDuringResume: AppStatus?
    private var menuStatusCancellables = Set<AnyCancellable>()
    private var didBindMenuDisplayStatus = false

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

    private func bindMenuDisplayStatusIfNeeded() {
        guard !didBindMenuDisplayStatus else { return }
        didBindMenuDisplayStatus = true

        // Seed current display from the current stable status.
        appState.menuDisplayStatus = appState.status

        appState.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.syncMenuDisplayStatus(with: newStatus)
            }
            .store(in: &menuStatusCancellables)
    }

    private func syncMenuDisplayStatus(with newStatus: AppStatus) {
        menuStatusCommitTask?.cancel()
        menuStatusCommitTask = nil

        if isResuming {
            // Hold a stable paused presentation until resume finishes.
            let held = heldMenuStatusDuringResume ?? .paused
            if appState.menuDisplayStatus != held {
                appState.menuDisplayStatus = held
                #if DEBUG
                print("[MenuStatus] Holding previous stable status during resume")
                #endif
            }
            return
        }

        switch newStatus {
        case .listening, .panicDetected:
            // Debounce brief listening flashes (e.g. attach-then-retry) so the menu doesn't flicker.
            menuStatusCommitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.menuListeningCommitDebounce ?? 0.35))
                guard !Task.isCancelled, let self, !self.isResuming else { return }
                guard self.appState.status == .listening || self.appState.status == .panicDetected else {
                    return
                }
                self.commitMenuDisplayStatus(.listening)
            }

        case .paused:
            commitMenuDisplayStatus(.paused)

        case .starting, .needsTraining, .training, .trainingComplete, .trainingFailed,
             .microphonePermissionNeeded, .microphonePermissionDenied, .audioError:
            commitMenuDisplayStatus(newStatus)
        }
    }

    private func commitMenuDisplayStatus(_ status: AppStatus) {
        guard appState.menuDisplayStatus != status else { return }
        appState.menuDisplayStatus = status
        #if DEBUG
        switch status {
        case .listening, .panicDetected:
            print("[MenuStatus] Display status updated to listening")
        case .paused:
            print("[MenuStatus] Display status updated to paused")
        default:
            break
        }
        #endif
    }

    private func beginResumeMenuHold() {
        heldMenuStatusDuringResume = .paused
        commitMenuDisplayStatus(.paused)
        #if DEBUG
        print("[MenuStatus] Holding previous stable status during resume")
        #endif
    }

    private func endResumeMenuHoldAndCommit() {
        heldMenuStatusDuringResume = nil
        syncMenuDisplayStatus(with: appState.status)
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
            appState.status = .microphonePermissionDenied

        case .notDetermined:
            appState.onboardingPhase = .permissionDenied
            appState.status = .microphonePermissionNeeded
        }
    }

    func finishOnboarding() {
        onboardingStore.markCompleted()
        appState.onboardingPhase = .idle
        dismissTrainingUI()
        if !audioCaptureService.isCapturing {
            try? audioCaptureService.startCapture()
        }
        _ = configureDetection()

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
            if !audioCaptureService.isCapturing {
                try? audioCaptureService.startCapture()
            }
            _ = configureDetection()

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
        appState.status = .needsTraining

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
            if !audioCaptureService.isCapturing {
                try? audioCaptureService.startCapture()
            }
            _ = configureDetection()
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

        guard !isPausing else {
            #if DEBUG
            print("[Listening] Pause ignored — pause already in progress")
            #endif
            return
        }
        guard !isResuming else {
            #if DEBUG
            print("[Listening] Pause ignored — resume already in progress")
            #endif
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
        audioCaptureService.stopCapture()
        appState.status = .paused
        lastPauseCompletedAt = Date()
        endResumeMenuHoldAndCommit()

        #if DEBUG
        print("[Listening] Detection paused")
        print("[Listening] Audio capture stopped")
        #endif
    }

    func resumeListening() {
        guard appState.status == .paused else { return }

        #if DEBUG
        print("[Listening] Resume requested")
        #endif
        
        guard !isPausing else {
            #if DEBUG
            print("[Listening] Resume ignored — pause already in progress")
            #endif
            return
        }
        guard !isResuming else {
            #if DEBUG
            print("[Listening] Resume ignored — resume already in progress")
            #endif
            return
        }

        beginResumeMenuHold()
        isResuming = true
        Task { [weak self] in
            await self?.resumeListeningAfterPauseGuard()
        }
    }

    private func resumeListeningAfterPauseGuard() async {
        defer {
            isResuming = false
            endResumeMenuHoldAndCommit()
        }

        guard appState.status == .paused else {
            #if DEBUG
            print("[Listening] Resume aborted — app status changed before start")
            #endif
            return
        }

        guard !isTraining else {
            #if DEBUG
            print("[Listening] Resume skipped — training still active")
            #endif
            return
        }

        if let lastPauseCompletedAt {
            let elapsed = Date().timeIntervalSince(lastPauseCompletedAt)
            if elapsed < pauseResumeSettleWindow {
                let remaining = pauseResumeSettleWindow - elapsed
                #if DEBUG
                print(
                    "[Listening] Resume delayed — waiting for audio teardown settle window (\(String(format: "%.2f", remaining))s)"
                )
                #endif
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }

        switch AudioCaptureService.currentPermissionStatus() {
        case .granted:
            break
        case .notDetermined:
            appState.status = .microphonePermissionNeeded
            return
        case .denied:
            appState.status = .microphonePermissionDenied
            return
        }

        guard panicFingerprintStore.load() != nil else {
            appState.status = .needsTraining
            return
        }

        #if DEBUG
        print("[Listening] Starting capture then attaching detection")
        #endif
        await startCaptureAttachDetectionThenVerifyLiveAudio()
    }

    private func startCaptureAttachDetectionThenVerifyLiveAudio() async {
        // Attempt 1: start → attach detector → verify first buffer
        do {
            try startCaptureOrThrow()

            guard attachDetectionForResume() else {
                // Capture may have dropped between start success and configureDetection;
                // treat that as a failed start so the retry path can recover.
                throw AudioCaptureError.engineStartFailed(
                    underlying: NSError(
                        domain: "AppCoordinator",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Detection attach failed after capture start (capture may not still be active)."
                        ]
                    )
                )
            }

            #if DEBUG
            print("[Listening] Audio capture restarted")
            print("[AudioCapture] Waiting for first buffer after start")
            #endif

            if await audioCaptureService.waitForFirstBufferAfterStart(timeout: 1.0) {
                #if DEBUG
                print("[AudioCapture] First buffer received after start")
                print("[Listening] Audio capture verified live")
                print("[Listening] Detection resumed")
                #endif
                return
            }

            #if DEBUG
            print("[AudioCapture] No buffer received after start — restarting engine once")
            #endif
        } catch {
            #if DEBUG
            print("[Listening] Capture start failed — retrying once")
            print("[Listening] Capture start failure: \(error.localizedDescription)")
            #endif
        }

        // Attempt 2 (one retry): clear → restart capture → re-attach → verify first buffer
        clearDetectionForResumeFailure()
        audioCaptureService.stopCapture()

        do {
            try startCaptureOrThrow()

            guard attachDetectionForResume() else {
                failResumeToPaused(reason: "detection could not be attached after retry")
                return
            }

            #if DEBUG
            print("[AudioCapture] Retry start succeeded")
            print("[AudioCapture] Waiting for first buffer after retry")
            #endif

            if await audioCaptureService.waitForFirstBufferAfterStart(timeout: 1.0) {
                #if DEBUG
                print("[AudioCapture] First buffer received after retry")
                print("[Listening] Audio capture verified live")
                print("[Listening] Detection resumed")
                #endif
                return
            }

            #if DEBUG
            print("[AudioCapture] No buffer received after retry — capture start failed")
            print("[Listening] Resume failed — no live audio buffers")
            #endif
            failResumeToPaused(reason: "no live audio buffers")
        } catch {
            #if DEBUG
            print("[Listening] Resume failed after retry — \(error.localizedDescription)")
            #endif
            failResumeToPaused(reason: error.localizedDescription)
        }
    }

    private func startCaptureOrThrow() throws {
        if !audioCaptureService.isCapturing {
            try audioCaptureService.startCapture()
        }

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
    }

    @discardableResult
    private func attachDetectionForResume() -> Bool {
        configureDetection()
    }

    private func clearDetectionForResumeFailure() {
        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)
    }

    private func failResumeToPaused(reason: String) {
        clearDetectionForResumeFailure()
        audioCaptureService.stopCapture()
        appState.status = .paused
        #if DEBUG
        print("[Listening] ResumeListening failed — \(reason); status restored to paused")
        #endif
    }

    @discardableResult
    private func restoreListeningAfterCaptureStart(callSite: String) -> Bool {
        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — setup/training in progress")
            #endif
            return false
        }

        do {
            if !audioCaptureService.isCapturing {
                try audioCaptureService.startCapture()
            }

            #if DEBUG
            print(
                "[Listening] \(callSite) post-startCapture — "
                    + "captureActive=\(audioCaptureService.isCapturing)"
            )
            #endif

            guard audioCaptureService.isCapturing else {
                throw AudioCaptureError.engineStartFailed(
                    underlying: NSError(
                        domain: "AppCoordinator",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio capture did not become active."]
                    )
                )
            }

            #if DEBUG
            print("[Listening] Audio capture restarted — captureActive=\(audioCaptureService.isCapturing)")
            #endif

            guard configureDetection() else {
                throw AudioCaptureError.engineStartFailed(
                    underlying: NSError(
                        domain: "AppCoordinator",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Detection could not be restored."]
                    )
                )
            }

            #if DEBUG
            print("[Listening] Detection resumed")
            #endif
            return true
        } catch {
            audioCaptureService.stopCapture()
            if callSite == "ResumeListening" {
                appState.status = .paused
            } else {
                appState.status = .audioError(error.localizedDescription)
            }
            #if DEBUG
            print("[Listening] \(callSite) failed — \(error.localizedDescription)")
            #endif
            return false
        }
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

        bindMenuDisplayStatusIfNeeded()

        NSApplication.shared.setActivationPolicy(.accessory)

        #if DEBUG
        print("[Startup] App launch started (accessory / menu bar mode)")
        #endif

        evaluateStartupSetupPresentation()

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
            // Should not happen after a request. Avoid treating this as a hard denial.
            appState.status = .microphonePermissionNeeded
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

        stopListeningCaptureIfNeeded(reason: "training session starting")

        do {
            try prepareAudioCaptureForTraining()
        } catch {
            appState.status = .audioError(error.localizedDescription)
            appState.trainingUIPhase = .failed(error.localizedDescription)
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
            audioCaptureService.stopCapture()
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
        audioCaptureService.stopCapture()
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
            appState.status = .microphonePermissionDenied
            if openSettingsIfDenied {
                #if DEBUG
                print("[Permission] Opening System Settings because permission is denied (callSite=\(callSite))")
                #endif
                openMicrophoneSystemSettings()
            }
            return .denied

        case .notDetermined:
            guard requestIfNeeded else {
                appState.status = .microphonePermissionNeeded
                #if DEBUG
                print("[Permission] notDetermined — not requesting (callSite=\(callSite))")
                #endif
                return .notDetermined
            }

            appState.status = .microphonePermissionNeeded

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
                appState.status = .microphonePermissionDenied
                return .denied

            case .notDetermined:
                appState.status = .microphonePermissionNeeded
                return .notDetermined
            }
        }
    }

    private func presentMicrophoneDeniedForTraining() {
        appState.status = .microphonePermissionDenied
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
        audioCaptureService.stopCapture()
        NSApplication.shared.terminate(nil)
    }

    /// Observes current microphone permission and starts capture when already granted.
    /// Never prompts — permission dialogs are user-action only.
    private func beginAudioCapture() async {
        #if DEBUG
        print("[Startup] Checking microphone permission (status only — will not request)")
        #endif

        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — setup/training in progress")
            #endif
            return
        }

        switch AudioCaptureService.currentPermissionStatus() {
        case .notDetermined:
            appState.status = .microphonePermissionNeeded
            #if DEBUG
            print("[Startup] Microphone permission notDetermined — detection inactive until user grants")
            #endif

        case .granted:
            startCapture()

        case .denied:
            appState.status = .microphonePermissionDenied
            #if DEBUG
            print("[Startup] Startup failed: microphone permission denied")
            #endif
        }
    }

    private func startCapture() {
        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — setup/training in progress")
            #endif
            return
        }

        #if DEBUG
        print("[Startup] Starting audio capture")
        #endif

        _ = restoreListeningAfterCaptureStart(callSite: "Startup")
    }

    @discardableResult
    private func configureDetection() -> Bool {
        #if DEBUG
        print(
            "[Detection] configureDetection called — "
                + "isTraining=\(isTraining), status=\(appState.status), "
                + "captureActive=\(audioCaptureService.isCapturing)"
        )
        #endif

        if isSetupOrTrainingInProgress {
            #if DEBUG
            print("[Startup] Listening deferred — setup/training in progress")
            #endif
            return false
        }

        guard !isTraining else {
            #if DEBUG
            print("[Detection] configureDetection skipped — training still active")
            #endif
            return false
        }

        panicDetector?.stop()
        panicDetector = nil
        audioPipeline.setDetector(nil)

        guard let fingerprint = panicFingerprintStore.load() else {
            appState.status = .needsTraining
            appState.lastTrainedAt = nil
            #if DEBUG
            print("[Detection] configureDetection aborted — no stored fingerprint")
            #endif
            return false
        }

        appState.lastTrainedAt = fingerprint.createdAt

        guard audioCaptureService.isCapturing else {
            #if DEBUG
            print("[Detection] configureDetection aborted — audio capture is not active")
            #endif
            return false
        }

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            appState.status = .audioError("Microphone input is unavailable.")
            #if DEBUG
            print("[Detection] configureDetection aborted — microphone input unavailable")
            #endif
            return false
        }

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
        print(
            "[Detection] configureDetection complete — detector attached, "
                + "sampleRate=\(String(format: "%.0f", sampleRate)), "
                + "captureActive=\(audioCaptureService.isCapturing), status=listening"
        )
        #endif
        return true
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
            #if DEBUG
            print("[Training] Training session ended — resuming detection")
            #endif
            // Only resume listening after onboarding/setup is fully done.
            if !isSetupOrTrainingInProgress {
                if !audioCaptureService.isCapturing {
                    try? audioCaptureService.startCapture()
                }
                if !configureDetection() {
                    #if DEBUG
                    print("[Training] Failed to restore detection after training")
                    #endif
                }
            } else {
                #if DEBUG
                print("[Startup] Listening deferred — setup/training in progress")
                #endif
            }
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
