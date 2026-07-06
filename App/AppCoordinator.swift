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

    private let sampleDuration: TimeInterval = 1.0
    private let trainingGetReadyDelay: TimeInterval = 1.0
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

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApplication.shared.setActivationPolicy(.accessory)

        Task {
            await beginAudioCapture()
        }
    }

    func startTraining() {
        guard !isTraining else { return }

        guard AudioCaptureService.currentPermissionStatus() == .granted else {
            appState.status = .microphonePermissionDenied
            return
        }

        if !audioCaptureService.isCapturing {
            do {
                try audioCaptureService.startCapture()
            } catch {
                appState.status = .audioError(error.localizedDescription)
                return
            }
        }

        panicDetector?.stop()

        #if DEBUG
        print("[Training] Detection paused")
        #endif

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
            appState.status = .trainingFailed("Microphone input is unavailable.")
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

            guard let features = await captureSample(sampleRate: sampleRate, sampleIndex: sampleIndex) else {
                #if DEBUG
                print("[Training] Sample \(sampleIndex)/3 rejected — could not capture audio")
                #endif
                appState.status = .trainingFailed("Could not capture sample \(sampleIndex).")
                return
            }

            #if DEBUG
            print("[Training] Sample RMS: \(String(format: "%.4f", features.rms))")
            #endif

            guard panicFingerprintService.isUsableSample(features) else {
                #if DEBUG
                print("[Training] Sample \(sampleIndex)/3 rejected — RMS below minimum threshold")
                #endif
                appState.status = .trainingFailed("Sample \(sampleIndex) was too quiet. Make your panic signal clearly.")
                return
            }

            #if DEBUG
            print("[Training] Sample \(sampleIndex)/3 accepted")
            #endif

            collectedSamples.append(features)
        }

        do {
            let fingerprint = try panicFingerprintService.combine(samples: collectedSamples)
            try panicFingerprintStore.save(fingerprint)
            appState.status = .trainingComplete

            #if DEBUG
            print("[Training] Training completed")
            print("[Training] Saved panic fingerprint with averageRMS: \(fingerprint.averageRMS)")
            #endif
        } catch {
            #if DEBUG
            print("[Training] Training failed — \(error.localizedDescription)")
            #endif
            appState.status = .trainingFailed(error.localizedDescription)
            return
        }

        try? await Task.sleep(for: .seconds(trainingCompleteDisplayDuration))
        guard !Task.isCancelled else { return }

        appState.status = .listening
    }

    private func captureSample(sampleRate: Double, sampleIndex: Int) async -> SampleFeatures? {
        #if DEBUG
        print("[Training] Get ready delay started (sample \(sampleIndex)/3)")
        #endif

        try? await Task.sleep(for: .seconds(trainingGetReadyDelay))
        if Task.isCancelled { return nil }

        #if DEBUG
        print("[Training] Get ready delay finished (sample \(sampleIndex)/3)")
        print("[Training] Sample recording began (sample \(sampleIndex)/3)")
        #endif

        let features = await withCheckedContinuation { continuation in
            let collector = TrainingSampleCollector(
                sampleRate: sampleRate,
                duration: sampleDuration
            ) { [weak self] features in
                self?.activeSampleCollector = nil
                continuation.resume(returning: features)
            }

            activeSampleCollector = collector
        }

        #if DEBUG
        print("[Training] Sample recording finished (sample \(sampleIndex)/3)")
        #endif

        return features
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        if activeSampleCollector != nil {
            activeSampleCollector?.append(buffer: buffer)
            return
        }

        panicDetector?.process(buffer: buffer)
    }
}
