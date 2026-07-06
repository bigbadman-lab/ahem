import AVFoundation

enum MicrophonePermissionStatus {
    case notDetermined
    case granted
    case denied
}

enum AudioCaptureError: LocalizedError {
    case invalidInputFormat
    case engineStartFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone input format is unavailable."
        case .engineStartFailed(let underlying):
            return underlying.localizedDescription
        }
    }
}

final class AudioCaptureService {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let logInterval: TimeInterval = 3
    private var isTapInstalled = false
    private var bufferCount = 0
    private var lastLogDate: Date?

    var isCapturing: Bool {
        isTapInstalled && engine.isRunning
    }

    var inputSampleRate: Double? {
        guard isTapInstalled else { return nil }
        let sampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        return sampleRate
    }

    static func currentPermissionStatus() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func requestPermission() async -> MicrophonePermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    func startCapture() throws {
        if isTapInstalled && engine.isRunning {
            #if DEBUG
            print("[AudioCapture] Audio engine already running — start ignored")
            #endif
            return
        }

        if isTapInstalled {
            removeTapIfNeeded()
        }

        #if DEBUG
        print("[AudioCapture] Starting audio engine")
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            #if DEBUG
            print("[AudioCapture] Invalid input format — sampleRate: \(format.sampleRate), channels: \(format.channelCount)")
            #endif
            throw AudioCaptureError.invalidInputFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
        isTapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTapIfNeeded()
            #if DEBUG
            print("[AudioCapture] Failed to start audio engine: \(error.localizedDescription)")
            #endif
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }

        #if DEBUG
        print("[AudioCapture] Audio engine started")
        #endif
    }

    func stopCapture() {
        guard isTapInstalled || engine.isRunning else {
            #if DEBUG
            print("[AudioCapture] Audio engine already stopped — stop ignored")
            #endif
            return
        }

        #if DEBUG
        print("[AudioCapture] Stopping audio engine")
        #endif

        removeTapIfNeeded()
        if engine.isRunning {
            engine.stop()
        }
        bufferCount = 0
        lastLogDate = nil

        #if DEBUG
        print("[AudioCapture] Audio engine stopped")
        #endif
    }

    private func removeTapIfNeeded() {
        guard isTapInstalled else { return }

        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            return
        }

        bufferCount += 1
        logBufferActivity(frameLength: buffer.frameLength)
        onBuffer?(buffer)
    }

    private func logBufferActivity(frameLength: AVAudioFrameCount) {
        let now = Date()
        if let lastLogDate, now.timeIntervalSince(lastLogDate) < logInterval {
            return
        }
        lastLogDate = now

        #if DEBUG
        print("[AudioCapture] \(bufferCount) buffers received (latest frameLength: \(frameLength))")
        #endif
    }
}
