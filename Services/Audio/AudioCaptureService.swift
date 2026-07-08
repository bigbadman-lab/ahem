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

    // Lazy: do not create AVAudioEngine / touch input hardware until permission is granted.
    private var engine: AVAudioEngine?
    /// Session commitment flag. Only set true after tap install + verified running engine.
    private var captureSessionActive = false
    private let logInterval: TimeInterval = 3
    private var isTapInstalled = false
    private var bufferCount = 0
    private var lastLogDate: Date?

    // Swift 6-safe scoped lock protecting capture-active state and first-buffer wait.
    private let captureStateLock = OSAllocatedUnfairLock()
    private var bufferSerial: UInt64 = 0
    private var bufferSerialAtLastStart: UInt64 = 0
    private var firstBufferWaitContinuation: CheckedContinuation<Bool, Never>?

    /// Single source of truth for live capture.
    /// True only when session committed, tap installed, engine exists, and engine.isRunning.
    var isCapturing: Bool {
        captureStateLock.withLock { isCapturingUnlocked() }
    }

    var inputSampleRate: Double? {
        captureStateLock.withLock { () -> Double? in
            guard isCapturingUnlocked(), let engine else { return nil }
            let sampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else { return nil }
            return sampleRate
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

    func startCapture() throws {
        if isCapturing {
            #if DEBUG
            print("[AudioCapture] Audio engine already running — start ignored")
            #endif
            return
        }

        // Tear down any half-started session before recreating the engine.
        captureStateLock.withLock {
            captureSessionActive = false
            bufferSerialAtLastStart = bufferSerial
        }
        if isTapInstalled || engine != nil {
            cleanupFailedCaptureStart(reason: "resetting before fresh start")
        }

        #if DEBUG
        print("[AudioCapture] Creating AVAudioEngine (permission granted path)")
        #endif
        let newEngine = AVAudioEngine()
        engine = newEngine

        #if DEBUG
        print("[AudioCapture] Starting audio engine")
        #endif

        let inputNode = newEngine.inputNode
        #if DEBUG
        print("[AudioCapture] Accessing inputNode.outputFormat")
        #endif
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            cleanupFailedCaptureStart(
                reason: "invalid input format sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
            )
            throw AudioCaptureError.invalidInputFormat
        }

        #if DEBUG
        print("[AudioCapture] Installing input tap (onBus=0, bufferSize=1024)")
        #endif
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
        captureStateLock.withLock {
            isTapInstalled = true
        }

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            cleanupFailedCaptureStart(
                reason: "engine.start() threw: \(error.localizedDescription)"
            )
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }

        // Commit capture as active only if the engine is still running under the same lock
        // used by external `isCapturing` reads — never return success with a false external state.
        let committed = captureStateLock.withLock { () -> Bool in
            guard isTapInstalled, let engine, engine === newEngine, engine.isRunning else {
                captureSessionActive = false
                return false
            }
            captureSessionActive = true
            return isCapturingUnlocked()
        }

        guard committed else {
            cleanupFailedCaptureStart(reason: "engine.isRunning=false after start")
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
                + "captureActive=\(snapshot.isCapturing), isRunning=\(snapshot.isRunning)"
        )
        #endif
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

    private func cleanupFailedCaptureStart(reason: String) {
        #if DEBUG
        if reason != "resetting before fresh start" {
            print("[AudioCapture] Audio engine start failed — \(reason)")
            print("[AudioCapture] Cleaning up failed capture start")
        }
        #endif

        let continuationToResume = captureStateLock.withLock { () -> CheckedContinuation<Bool, Never>? in
            captureSessionActive = false
            let pending = firstBufferWaitContinuation
            firstBufferWaitContinuation = nil
            return pending
        }
        continuationToResume?.resume(returning: false)

        removeTapIfNeeded()
        if let engine {
            if engine.isRunning {
                engine.stop()
            }
        }
        engine = nil
        bufferCount = 0
        lastLogDate = nil
    }

    func stopCapture() {
        // If someone is waiting for a first buffer, stop that wait immediately.
        let continuationToResume = captureStateLock.withLock { () -> CheckedContinuation<Bool, Never>? in
            captureSessionActive = false
            let pending = firstBufferWaitContinuation
            firstBufferWaitContinuation = nil
            return pending
        }
        continuationToResume?.resume(returning: false)

        let shouldStop = captureStateLock.withLock {
            isTapInstalled || engine != nil
        }
        guard shouldStop else {
            #if DEBUG
            print("[AudioCapture] Audio engine already stopped — stop ignored")
            #endif
            return
        }

        #if DEBUG
        print("[AudioCapture] Stopping audio engine")
        #endif

        removeTapIfNeeded()
        if let engine, engine.isRunning {
            engine.stop()
        }
        engine = nil
        bufferCount = 0
        lastLogDate = nil

        #if DEBUG
        print("[AudioCapture] Audio engine stopped — captureActive=\(isCapturing)")
        #endif
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
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            return
        }

        let continuationToResume = captureStateLock.withLock { () -> CheckedContinuation<Bool, Never>? in
            bufferSerial &+= 1
            let pending = firstBufferWaitContinuation
            firstBufferWaitContinuation = nil
            return pending
        }

        bufferCount += 1
        logBufferActivity(frameLength: buffer.frameLength)
        onBuffer?(buffer)

        continuationToResume?.resume(returning: true)
    }

    /// Waits briefly for the first live audio buffer to arrive after the most recent `startCapture()` call.
    /// - Returns: `true` if a buffer arrived before timeout, otherwise `false`.
    func waitForFirstBufferAfterStart(timeout: TimeInterval) async -> Bool {
        let timeoutSeconds = max(0, timeout)
        if timeoutSeconds == 0 {
            return false
        }

        let alreadyHasBuffer = captureStateLock.withLock {
            bufferSerial > bufferSerialAtLastStart
        }
        if alreadyHasBuffer {
            return true
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let shouldResumeNow = captureStateLock.withLock { () -> Bool in
                // Re-check while holding the lock (covers "buffer arrived just before we installed the continuation").
                if bufferSerial > bufferSerialAtLastStart {
                    return true
                }
                firstBufferWaitContinuation = continuation
                return false
            }

            if shouldResumeNow {
                continuation.resume(returning: true)
                return
            }

            Task {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)

                let timeoutContinuation = captureStateLock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    let pending = firstBufferWaitContinuation
                    firstBufferWaitContinuation = nil
                    return pending
                }

                timeoutContinuation?.resume(returning: false)
            }
        }
    }

    private func logBufferActivity(frameLength: AVAudioFrameCount) {
        let now = Date()
        if let lastLogDate, now.timeIntervalSince(lastLogDate) < logInterval {
            return
        }
        lastLogDate = now

        #if DEBUG
        print(
            "[AudioCapture] \(bufferCount) buffers received "
                + "(latest frameLength: \(frameLength), captureActive: \(isCapturing))"
        )
        #endif
    }
}
