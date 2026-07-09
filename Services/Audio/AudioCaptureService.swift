import AppKit
import AVFoundation
import os

enum MicrophonePermissionStatus: Equatable, CustomStringConvertible {
    case notDetermined
    case granted
    case denied

    var description: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .granted: return "granted"
        case .denied: return "denied"
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidInputFormat
    case engineStartFailed(underlying: Error)
    case converterSetupFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone input format is unavailable."
        case .engineStartFailed(let underlying):
            return underlying.localizedDescription
        case .converterSetupFailed:
            return "Could not configure audio sample-rate conversion."
        }
    }
}

final class AudioCaptureService {
    /// Stable processing rate used for training and detection (mono float PCM).
    static let targetProcessingSampleRate: Double = 16_000

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    // Lazy: do not create AVAudioEngine / touch input hardware until permission is granted.
    private var engine: AVAudioEngine?
    /// Session commitment flag. Only set true after tap install + verified running engine.
    private var captureSessionActive = false
    private let logInterval: TimeInterval = 3
    private var isTapInstalled = false
    private var bufferCount = 0
    private var lastLogDate: Date?

    private var hardwareSampleRateValue: Double = 0
    private var processingFormat: AVAudioFormat?
    private var sampleRateConverter: AVAudioConverter?

    // Swift 6-safe scoped lock protecting capture-active state and first-buffer wait.
    private let captureStateLock = OSAllocatedUnfairLock()
    private var captureGeneration: UInt64 = 0
    private var liveCaptureGeneration: UInt64 = 0
    private var bufferSerial: UInt64 = 0
    private var bufferSerialAtLastStart: UInt64 = 0
    private var firstProcessedBufferWaitContinuation: CheckedContinuation<Bool, Never>?
    private var firstProcessedBufferWaitGeneration: UInt64 = 0
    private var firstProcessedBufferWaitTimeoutTask: Task<Void, Never>?

    /// Single source of truth for live capture.
    /// True only when session committed, tap installed, engine exists, and engine.isRunning.
    var isCapturing: Bool {
        captureStateLock.withLock { isCapturingUnlocked() }
    }

    /// Monotonically increasing token assigned on each `startCapture()`.
    var currentCaptureGeneration: UInt64 {
        captureStateLock.withLock { captureGeneration }
    }

    /// Sample rate used by training/detection after normalization (always 16000 when capturing).
    var inputSampleRate: Double? {
        captureStateLock.withLock {
            guard isCapturingUnlocked() else { return nil }
            return Self.targetProcessingSampleRate
        }
    }

    /// Raw microphone hardware sample rate before conversion.
    var hardwareSampleRate: Double? {
        captureStateLock.withLock {
            guard isCapturingUnlocked(), hardwareSampleRateValue > 0 else { return nil }
            return hardwareSampleRateValue
        }
    }

    private func isCapturingUnlocked() -> Bool {
        guard captureSessionActive, isTapInstalled, let engine else { return false }
        return engine.isRunning
    }

    static func currentPermissionStatus() -> MicrophonePermissionStatus {
        let audioAppStatus = AVAudioApplication.shared.recordPermission

        #if DEBUG
        let captureStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print(
            "[Permission] Status check — "
                + "AVAudioApplication.recordPermission=\(debugLabel(for: audioAppStatus)) "
                + "(source of truth)"
        )
        print(
            "[Permission] diagnostic only — "
                + "AVCaptureDevice.audio=\(debugLabel(for: captureStatus)) "
                + "(not used for decisions)"
        )
        #endif

        return mapRecordPermission(audioAppStatus)
    }

    private static func mapRecordPermission(
        _ status: AVAudioApplication.recordPermission
    ) -> MicrophonePermissionStatus {
        switch status {
        case .undetermined:
            return .notDetermined
        case .granted:
            return .granted
        case .denied:
            return .denied
        @unknown default:
            #if DEBUG
            print(
                "[Permission] Unknown AVAudioApplication.recordPermission "
                    + "rawValue=\(status.rawValue) — treating as notDetermined"
            )
            #endif
            return .notDetermined
        }
    }

    /// Requests microphone permission when undetermined.
    /// Uses AVAudioApplication only — appropriate for AVAudioEngine-based recording.
    /// Temporarily becomes a regular, frontmost app so macOS can present the system dialog.
    /// - Parameter callSite: DEBUG label identifying the explicit user action that triggered the request.
    @MainActor
    static func requestPermission(callSite: String) async -> MicrophonePermissionStatus {
        let current = currentPermissionStatus()
        #if DEBUG
        print("[Permission] requestPermission() callSite=\(callSite) entered with status=\(current)")
        #endif

        switch current {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            break
        }

        let previousPolicy = NSApp.activationPolicy()
        #if DEBUG
        print("[Permission] Activation policy before request=\(debugLabel(for: previousPolicy)) isActive=\(NSApp.isActive)")
        #endif

        if previousPolicy != .regular {
            let didChange = NSApp.setActivationPolicy(.regular)
            #if DEBUG
            print(
                "[Permission] Switched activation policy to .regular "
                    + "didChange=\(didChange) now=\(debugLabel(for: NSApp.activationPolicy()))"
            )
            #endif
        }

        NSApp.activate(ignoringOtherApps: true)
        bringRelevantWindowsToFront()

        // Give AppKit time to become frontmost before TCC presents its alert.
        try? await Task.sleep(for: .milliseconds(400))

        #if DEBUG
        print(
            "[Permission] Pre-request front state — "
                + "policy=\(debugLabel(for: NSApp.activationPolicy())) "
                + "isActive=\(NSApp.isActive) "
                + "keyWindow=\(NSApp.keyWindow?.title ?? "nil") "
                + "mainWindow=\(NSApp.mainWindow?.title ?? "nil")"
        )
        logRuntimeMicrophoneDiagnostics(callSite: callSite)
        print("[Permission] Calling AVAudioApplication.requestRecordPermission callSite=\(callSite)")
        #endif

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVAudioApplication.requestRecordPermission { _ in
                Task { @MainActor in
                    #if DEBUG
                    let callbackStatus = AVAudioApplication.shared.recordPermission
                    print(
                        "[Permission] requestRecordPermission callback — "
                            + "AVAudioApplication=\(debugLabel(for: callbackStatus)) "
                            + "callSite=\(callSite)"
                    )
                    #endif
                    continuation.resume()
                }
            }
        }

        let result = mapRecordPermission(AVAudioApplication.shared.recordPermission)

        #if DEBUG
        let captureDiagnostic = AVCaptureDevice.authorizationStatus(for: .audio)
        print(
            "[Permission] Post-request AVAudioApplication=\(debugLabel(for: AVAudioApplication.shared.recordPermission)) "
                + "mapped=\(result) callSite=\(callSite)"
        )
        print(
            "[Permission] diagnostic only — "
                + "AVCaptureDevice.audio=\(debugLabel(for: captureDiagnostic)) "
                + "(not used for decisions)"
        )
        #endif

        // Keep .regular briefly so the alert can finish dismissing before becoming accessory again.
        try? await Task.sleep(for: .milliseconds(300))

        if previousPolicy != .regular {
            let didRestore = NSApp.setActivationPolicy(previousPolicy)
            #if DEBUG
            print(
                "[Permission] Restored activation policy to \(debugLabel(for: previousPolicy)) "
                    + "didChange=\(didRestore) now=\(debugLabel(for: NSApp.activationPolicy()))"
            )
            #endif
        }

        return result
    }

    @MainActor
    private static func bringRelevantWindowsToFront() {
        let preferredTitles = ["Train your cough", "Preferences", "Welcome to Ahem"]
        let windows = NSApp.windows.filter(\.isVisible)

        let preferred = windows.first { window in
            preferredTitles.contains(where: { window.title.localizedCaseInsensitiveContains($0) })
        }

        let target = preferred ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        for window in windows {
            window.orderFrontRegardless()
        }

        #if DEBUG
        print(
            "[Permission] Brought windows forward — "
                + "preferred=\(preferred?.title ?? "nil") "
                + "visibleCount=\(windows.count)"
        )
        #endif
    }

    #if DEBUG
    @MainActor
    private static func logRuntimeMicrophoneDiagnostics(callSite: String) {
        let bundle = Bundle.main
        let usageDescription = bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        let infoPlistPath = bundle.bundleURL.appendingPathComponent("Contents/Info.plist").path
        let infoPlistExists = FileManager.default.fileExists(atPath: infoPlistPath)

        print("[Permission] Runtime diagnostics callSite=\(callSite)")
        print("[Permission] bundleIdentifier=\(bundle.bundleIdentifier ?? "nil")")
        print("[Permission] bundlePath=\(bundle.bundlePath)")
        print("[Permission] executablePath=\(bundle.executablePath ?? "nil")")
        print("[Permission] infoPlistPath=\(infoPlistPath) exists=\(infoPlistExists)")
        print(
            "[Permission] NSMicrophoneUsageDescription="
                + (usageDescription.map { "\"\($0)\"" } ?? "MISSING")
        )

        if let entitlements = currentProcessEntitlements() {
            let sandbox = entitlements["com.apple.security.app-sandbox"] as? Bool
            let audioInput = entitlements["com.apple.security.device.audio-input"] as? Bool
            print("[Permission] entitlement app-sandbox=\(sandbox.map(String.init(describing:)) ?? "absent")")
            print("[Permission] entitlement audio-input=\(audioInput.map(String.init(describing:)) ?? "absent")")
            print("[Permission] entitlementKeys=\(entitlements.keys.sorted().joined(separator: ", "))")
        } else {
            print("[Permission] entitlements=unavailable (codesign lookup failed or unsigned)")
        }

        let captureDiagnostic = AVCaptureDevice.authorizationStatus(for: .audio)
        print(
            "[Permission] diagnostic only — "
                + "AVCaptureDevice.audio=\(debugLabel(for: captureDiagnostic)) "
                + "(not used for decisions)"
        )
    }

    private static func currentProcessEntitlements() -> [String: Any]? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return nil }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess,
              let information = information as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return nil
        }
        return entitlements
    }
    #endif

    #if DEBUG
    private static func debugLabel(for status: AVAudioApplication.recordPermission) -> String {
        switch status {
        case .undetermined: return "undetermined(\(status.rawValue))"
        case .denied: return "denied(\(status.rawValue))"
        case .granted: return "granted(\(status.rawValue))"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func debugLabel(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined(\(status.rawValue))"
        case .restricted: return "restricted(\(status.rawValue))"
        case .denied: return "denied(\(status.rawValue))"
        case .authorized: return "authorized(\(status.rawValue))"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func debugLabel(for policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }
    #endif

    /// Idempotent: always tears down any prior session, then builds a fresh engine and tap.
    /// - Returns: The capture generation token for this session.
    @discardableResult
    func startCapture() throws -> UInt64 {
        stopCapture(reason: "pre-start clean slate")

        let generation = captureStateLock.withLock {
            captureGeneration &+= 1
            return captureGeneration
        }

        print("[AudioLifecycle] startCapture requested — generation=\(generation)")

        #if DEBUG
        print("[AudioCapture] Creating AVAudioEngine (permission granted path)")
        #endif
        let newEngine = AVAudioEngine()
        engine = newEngine
        print("[AudioLifecycle] engine created — generation=\(generation)")

        #if DEBUG
        print("[AudioCapture] Starting audio engine")
        #endif

        let inputNode = newEngine.inputNode
        #if DEBUG
        print("[AudioCapture] Accessing inputNode.outputFormat")
        #endif
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate.isFinite,
              hardwareFormat.sampleRate > 0,
              hardwareFormat.channelCount > 0 else {
            cleanupFailedCaptureStart(
                reason: "invalid input format sampleRate=\(hardwareFormat.sampleRate) channels=\(hardwareFormat.channelCount)",
                generation: generation
            )
            throw AudioCaptureError.invalidInputFormat
        }

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetProcessingSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            cleanupFailedCaptureStart(
                reason: "could not create 16 kHz mono processing format",
                generation: generation
            )
            throw AudioCaptureError.converterSetupFailed
        }

        let converter: AVAudioConverter?
        if abs(hardwareFormat.sampleRate - Self.targetProcessingSampleRate) < 0.5,
           hardwareFormat.channelCount == 1,
           hardwareFormat.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else {
            guard let madeConverter = AVAudioConverter(from: hardwareFormat, to: processingFormat) else {
                cleanupFailedCaptureStart(
                    reason: "AVAudioConverter setup failed \(hardwareFormat.sampleRate)Hz → \(Self.targetProcessingSampleRate)Hz",
                    generation: generation
                )
                throw AudioCaptureError.converterSetupFailed
            }
            converter = madeConverter
        }

        hardwareSampleRateValue = hardwareFormat.sampleRate
        self.processingFormat = processingFormat
        sampleRateConverter = converter

        #if DEBUG
        print(
            "[AudioCapture] Hardware sample rate=\(String(format: "%.0f", hardwareFormat.sampleRate)) "
                + "channels=\(hardwareFormat.channelCount)"
        )
        print(
            "[AudioCapture] Normalized processing sample rate=\(String(format: "%.0f", Self.targetProcessingSampleRate)) "
                + "mono converter=\(converter == nil ? "passthrough" : "active")"
        )
        print("[AudioCapture] Installing input tap (onBus=0, bufferSize=1024)")
        #endif
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, bufferGeneration: generation)
        }
        captureStateLock.withLock {
            isTapInstalled = true
        }
        print("[AudioLifecycle] tap installed — generation=\(generation)")

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            cleanupFailedCaptureStart(
                reason: "engine.start() threw: \(error.localizedDescription)",
                generation: generation
            )
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }

        print("[AudioLifecycle] engine started — generation=\(generation)")

        // Commit capture as active only if the engine is still running under the same lock
        // used by external `isCapturing` reads — never return success with a false external state.
        let committed = captureStateLock.withLock { () -> Bool in
            guard isTapInstalled, let engine, engine === newEngine, engine.isRunning else {
                captureSessionActive = false
                liveCaptureGeneration = 0
                return false
            }
            captureSessionActive = true
            liveCaptureGeneration = generation
            bufferSerialAtLastStart = bufferSerial
            return isCapturingUnlocked()
        }

        guard committed else {
            cleanupFailedCaptureStart(
                reason: "engine.isRunning=false after start",
                generation: generation
            )
            throw AudioCaptureError.engineStartFailed(
                underlying: NSError(
                    domain: "AudioCaptureService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioEngine did not enter running state."]
                )
            )
        }

        #if DEBUG
        let snapshot = captureActivitySnapshot()
        print(
            "[AudioCapture] Audio engine started — "
                + "captureActive=\(snapshot.isCapturing), isRunning=\(snapshot.isRunning), "
                + "hardwareRate=\(String(format: "%.0f", hardwareSampleRateValue)), "
                + "processingRate=\(String(format: "%.0f", Self.targetProcessingSampleRate))"
        )
        #endif

        return generation
    }

    /// Snapshot of capture activity using the same lock as `isCapturing`.
    func captureActivitySnapshot() -> (isCapturing: Bool, isRunning: Bool, tapInstalled: Bool) {
        captureStateLock.withLock {
            (
                isCapturing: isCapturingUnlocked(),
                isRunning: engine?.isRunning ?? false,
                tapInstalled: isTapInstalled
            )
        }
    }

    /// Idempotent: safe to call repeatedly; always invalidates live generation and tears down engine state.
    func stopCapture(reason: String = "unspecified") {
        print("[AudioLifecycle] stopCapture requested — reason=\(reason)")

        let continuationToResume = captureStateLock.withLock { () -> CheckedContinuation<Bool, Never>? in
            captureSessionActive = false
            liveCaptureGeneration = 0
            firstProcessedBufferWaitGeneration = 0
            let pending = firstProcessedBufferWaitContinuation
            firstProcessedBufferWaitContinuation = nil
            return pending
        }
        firstProcessedBufferWaitTimeoutTask?.cancel()
        firstProcessedBufferWaitTimeoutTask = nil
        continuationToResume?.resume(returning: false)

        let hadEngine = captureStateLock.withLock {
            isTapInstalled || engine != nil
        }

        guard hadEngine else {
            resetEngineResources(logEvents: false)
            return
        }

        removeTapIfNeeded()
        if let engine, engine.isRunning {
            engine.stop()
            print("[AudioLifecycle] engine stopped")
        } else {
            print("[AudioLifecycle] engine stopped")
        }

        resetEngineResources(logEvents: true)
    }

    private func resetEngineResources(logEvents: Bool) {
        engine = nil
        sampleRateConverter = nil
        processingFormat = nil
        hardwareSampleRateValue = 0
        bufferCount = 0
        lastLogDate = nil

        if logEvents {
            print("[AudioLifecycle] engine reset")
        }
    }

    private func cleanupFailedCaptureStart(reason: String, generation: UInt64) {
        #if DEBUG
        print("[AudioCapture] Audio engine start failed — \(reason)")
        print("[AudioCapture] Cleaning up failed capture start")
        #endif

        captureStateLock.withLock {
            if liveCaptureGeneration == generation {
                liveCaptureGeneration = 0
            }
            captureSessionActive = false
            firstProcessedBufferWaitGeneration = 0
        }

        stopCapture(reason: "failed start cleanup (generation=\(generation))")
    }

    private func removeTapIfNeeded() {
        let engineForTap: AVAudioEngine? = captureStateLock.withLock {
            guard isTapInstalled else { return nil }
            let current = engine
            isTapInstalled = false
            return current
        }
        guard let engineForTap else { return }

        #if DEBUG
        print("[AudioCapture] Removing input tap (onBus=0)")
        #endif
        engineForTap.inputNode.removeTap(onBus: 0)
        print("[AudioLifecycle] input tap removed")
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, bufferGeneration: UInt64) {
        let currentGeneration = captureStateLock.withLock { liveCaptureGeneration }
        guard currentGeneration > 0, currentGeneration == bufferGeneration else {
            let latest = captureStateLock.withLock { captureGeneration }
            print(
                "[AudioLifecycle] ignoring stale buffer — "
                    + "bufferGeneration=\(bufferGeneration) currentGeneration=\(latest)"
            )
            return
        }

        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            return
        }

        let sourceFrameLength = buffer.frameLength
        guard let processed = normalizedBuffer(from: buffer) else { return }

        let waitResolution = captureStateLock.withLock { () -> (CheckedContinuation<Bool, Never>?, Bool) in
            guard liveCaptureGeneration == bufferGeneration else {
                return (nil, false)
            }

            bufferSerial &+= 1
            let hasNewBuffer = bufferSerial > bufferSerialAtLastStart
            guard let pending = firstProcessedBufferWaitContinuation,
                  firstProcessedBufferWaitGeneration == bufferGeneration else {
                return (nil, hasNewBuffer)
            }

            firstProcessedBufferWaitContinuation = nil
            firstProcessedBufferWaitGeneration = 0
            return (pending, true)
        }

        bufferCount += 1
        logBufferActivity(
            sourceFrameLength: sourceFrameLength,
            processedFrameLength: processed.frameLength
        )
        onBuffer?(processed)

        if let continuationToResume = waitResolution.0 {
            firstProcessedBufferWaitTimeoutTask?.cancel()
            firstProcessedBufferWaitTimeoutTask = nil
            print("[AudioLifecycle] first buffer received — generation=\(bufferGeneration)")
            continuationToResume.resume(returning: true)
        }
    }

    private func normalizedBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Already at target format — pass through.
        if sampleRateConverter == nil,
           abs(buffer.format.sampleRate - Self.targetProcessingSampleRate) < 0.5,
           buffer.format.channelCount == 1 {
            return buffer
        }

        guard let processingFormat, let converter = sampleRateConverter else {
            return buffer
        }

        let ratio = processingFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumedSource = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumedSource {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedSource = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if let error {
            #if DEBUG
            print("[AudioCapture] Sample-rate conversion failed: \(error.localizedDescription)")
            #endif
            return nil
        }

        switch status {
        case .haveData, .inputRanDry:
            guard converted.frameLength > 0 else { return nil }
            return converted
        case .error, .endOfStream:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Waits for the first normalized mono 16 kHz buffer for the given capture generation.
    /// - Returns: `true` when a valid processed buffer arrived before timeout, otherwise `false`.
    func waitForFirstProcessedBuffer(timeout: TimeInterval, generation: UInt64) async -> Bool {
        let timeoutSeconds = max(0, timeout)
        if timeoutSeconds == 0 || generation == 0 {
            return false
        }

        let alreadyHasBuffer = captureStateLock.withLock {
            liveCaptureGeneration == generation && bufferSerial > bufferSerialAtLastStart
        }
        if alreadyHasBuffer {
            print("[AudioLifecycle] first buffer received — generation=\(generation)")
            return true
        }

        guard captureStateLock.withLock({ liveCaptureGeneration == generation }) else {
            return false
        }

        print("[AudioLifecycle] waiting for first buffer — generation=\(generation)")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let shouldResumeNow = captureStateLock.withLock { () -> Bool in
                guard liveCaptureGeneration == generation else { return false }
                if bufferSerial > bufferSerialAtLastStart {
                    return true
                }
                firstProcessedBufferWaitContinuation = continuation
                firstProcessedBufferWaitGeneration = generation
                return false
            }

            if shouldResumeNow {
                print("[AudioLifecycle] first buffer received — generation=\(generation)")
                continuation.resume(returning: true)
                return
            }

            firstProcessedBufferWaitTimeoutTask?.cancel()
            firstProcessedBufferWaitTimeoutTask = Task {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)

                let timeoutResolution = captureStateLock.withLock { () -> (CheckedContinuation<Bool, Never>?, UInt64) in
                    let pending = firstProcessedBufferWaitContinuation
                    let waitGeneration = firstProcessedBufferWaitGeneration
                    firstProcessedBufferWaitContinuation = nil
                    firstProcessedBufferWaitGeneration = 0
                    return (pending, waitGeneration)
                }

                guard let timeoutContinuation = timeoutResolution.0 else { return }
                guard timeoutResolution.1 == generation else {
                    timeoutContinuation.resume(returning: false)
                    return
                }

                #if DEBUG
                print("[AudioCapture] First buffer wait timed out")
                #endif
                timeoutContinuation.resume(returning: false)
            }
        }
    }

    /// Backward-compatible alias used by older call sites.
    func waitForFirstBufferAfterStart(timeout: TimeInterval) async -> Bool {
        let generation = captureStateLock.withLock { liveCaptureGeneration }
        return await waitForFirstProcessedBuffer(timeout: timeout, generation: generation)
    }

    private func logBufferActivity(
        sourceFrameLength: AVAudioFrameCount,
        processedFrameLength: AVAudioFrameCount
    ) {
        let now = Date()
        if let lastLogDate, now.timeIntervalSince(lastLogDate) < logInterval {
            return
        }
        lastLogDate = now

        #if DEBUG
        print(
            "[AudioCapture] \(bufferCount) buffers received "
                + "(hardwareFrames: \(sourceFrameLength), "
                + "processingFrames: \(processedFrameLength), "
                + "hardwareRate: \(String(format: "%.0f", hardwareSampleRateValue)), "
                + "processingRate: \(String(format: "%.0f", Self.targetProcessingSampleRate)), "
                + "captureActive: \(isCapturing))"
        )
        #endif
    }
}
