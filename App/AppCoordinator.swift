import AppKit
import AVFoundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let appState: AppState

    private let audioCaptureService = AudioCaptureService()
    private let panicFingerprintService = PanicFingerprintService()
    private let panicFingerprintStore = PanicFingerprintStore()

    private var didStart = false
    private var isTraining = false
    private var trainingTask: Task<Void, Never>?
    private var activeSampleCollector: TrainingSampleCollector?

    private let sampleDuration: TimeInterval = 1.0
    private let trainingCompleteDisplayDuration: TimeInterval = 2.0

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

        isTraining = true
        trainingTask = Task { [weak self] in
            await self?.runTrainingSession()
        }
    }

    func quit() {
        trainingTask?.cancel()
        trainingTask = nil
        activeSampleCollector = nil
        isTraining = false
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

        logStoredFingerprintIfPresent()
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
        } catch {
            appState.status = .audioError(error.localizedDescription)
        }
    }

    private func runTrainingSession() async {
        defer {
            activeSampleCollector = nil
            isTraining = false
            trainingTask = nil
        }

        guard let sampleRate = audioCaptureService.inputSampleRate else {
            appState.status = .trainingFailed("Microphone input is unavailable.")
            return
        }

        var collectedSamples: [SampleFeatures] = []

        for sampleIndex in 1...3 {
            if Task.isCancelled { return }

            appState.status = .training(sample: sampleIndex, total: 3)

            guard let features = await captureSample(sampleRate: sampleRate) else {
                appState.status = .trainingFailed("Could not capture sample \(sampleIndex).")
                return
            }

            guard panicFingerprintService.isUsableSample(features) else {
                appState.status = .trainingFailed("Sample \(sampleIndex) was too quiet. Make your panic signal clearly.")
                return
            }

            collectedSamples.append(features)
        }

        do {
            let fingerprint = try panicFingerprintService.combine(samples: collectedSamples)
            try panicFingerprintStore.save(fingerprint)
            appState.status = .trainingComplete

            #if DEBUG
            print("[Training] Saved panic fingerprint with averageRMS: \(fingerprint.averageRMS)")
            #endif
        } catch {
            appState.status = .trainingFailed(error.localizedDescription)
            return
        }

        try? await Task.sleep(for: .seconds(trainingCompleteDisplayDuration))
        guard !Task.isCancelled else { return }

        appState.status = .listening
    }

    private func captureSample(sampleRate: Double) async -> SampleFeatures? {
        await withCheckedContinuation { continuation in
            let collector = TrainingSampleCollector(
                sampleRate: sampleRate,
                duration: sampleDuration
            ) { [weak self] features in
                self?.activeSampleCollector = nil
                continuation.resume(returning: features)
            }

            activeSampleCollector = collector
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        activeSampleCollector?.append(buffer: buffer)
    }

    private func logStoredFingerprintIfPresent() {
        #if DEBUG
        if let fingerprint = panicFingerprintStore.load() {
            print("[Training] Stored panic fingerprint from \(fingerprint.createdAt) (\(fingerprint.sampleCount) samples)")
        }
        #endif
    }
}
