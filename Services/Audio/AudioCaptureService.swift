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
        guard !isTapInstalled else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
        isTapInstalled = true

        do {
            try engine.start()
        } catch {
            removeTapIfNeeded()
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }
    }

    func stopCapture() {
        removeTapIfNeeded()
        if engine.isRunning {
            engine.stop()
        }
        bufferCount = 0
        lastLogDate = nil
    }

    private func removeTapIfNeeded() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        logBufferActivity(frameLength: buffer.frameLength)
        onBuffer?(buffer)
    }

    private func logBufferActivity(frameLength: AVAudioFrameCount) {
        let now = Date()
        guard lastLogDate == nil || now.timeIntervalSince(lastLogDate!) >= logInterval else {
            return
        }
        lastLogDate = now

        #if DEBUG
        print("[AudioCapture] \(bufferCount) buffers received (latest frameLength: \(frameLength))")
        #endif
    }
}
