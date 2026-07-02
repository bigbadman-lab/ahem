# Architecture

Technical architecture for the Ahem macOS MVP.

---

# Overview

Ahem is a menu bar–first native macOS application built in Swift and SwiftUI. It runs continuously in the background, captures microphone input locally, and matches incoming audio against a user-trained panic signal profile. When a match exceeds the confidence threshold, it hides the frontmost window of a supported browser.

The system is organised as a linear detection pipeline with loosely coupled services. UI, permissions, audio capture, detection, and browser control are separate modules with explicit boundaries. Detection logic is isolated behind protocols so the fingerprint-matching implementation can be replaced later (e.g. SoundAnalysis, Core ML) without rewriting onboarding, menu bar, or browser control.

No network layer exists. No account system exists. All state lives on disk in a local profile store.

---

# Core Pipeline

```
Microphone
    ↓
Audio Engine
    ↓
Event Detector
    ↓
Fingerprint Extractor
    ↓
Signal Matcher
    ↓
Confidence Engine
    ↓
Trigger Engine
    ↓
Browser Controller
    ↓
Hide active browser
```

| Stage | Role |
|---|---|
| **Microphone** | System audio input via AVFoundation. Ephemeral buffers only. |
| **Audio Engine** | Owns capture session lifecycle, buffer delivery, and level metering for UI. Runs on a dedicated audio queue. |
| **Event Detector** | Segments the stream into candidate events. Filters quiet background audio; isolates short, loud bursts likely to be the panic signal. |
| **Fingerprint Extractor** | Converts a candidate audio segment into a compact feature vector (fingerprint). Same algorithm used in training and live detection. |
| **Signal Matcher** | Compares candidate fingerprint against the stored `PanicSignalProfile`. Returns a raw similarity score. |
| **Confidence Engine** | Translates similarity into a normalised confidence score. Applies threshold and cooldown policy. |
| **Trigger Engine** | Emits a single trigger event when confidence threshold is met and cooldown allows. Sole entry point to the action path. |
| **Browser Controller** | Resolves the active application, validates browser support, and issues the hide command. |

---

# Components

## AppCoordinator

**Responsibility:** Application lifecycle orchestration. Wires services together at launch, manages global state (listening / paused / onboarding), and routes trigger events to browser control.

**Inputs:** Launch context, persisted profile presence, permission status, user actions (pause, re-train, quit).

**Outputs:** Service initialisation, pipeline start/stop, navigation to onboarding when required.

**Must NOT:** Capture audio, extract fingerprints, render UI directly, or request permissions without going through `PermissionService`.

---

## MenuBarController

**Responsibility:** Menu bar icon, status display, and menu actions (pause/resume, re-train, launch at login, about, quit).

**Inputs:** Listening state, permission errors, app version.

**Outputs:** User intents dispatched to `AppCoordinator`.

**Must NOT:** Own detection logic, store profiles, or present full-screen windows outside defined flows.

---

## OnboardingCoordinator

**Responsibility:** Linear first-run and re-train flow: welcome → microphone → accessibility → train → success.

**Inputs:** Permission status, training progress, validation result.

**Outputs:** Completed `PanicSignalProfile`, launch-at-login preference, signal to begin live listening.

**Must NOT:** Skip permission steps, persist raw audio, or expose settings beyond the defined onboarding screens.

---

## PermissionService

**Responsibility:** Query and request Microphone and Accessibility permissions. Surface denial state with recovery guidance.

**Inputs:** Permission type requests, system authorisation status.

**Outputs:** Granted / denied / not-determined state per permission.

**Must NOT:** Proceed with audio capture or window control when required permissions are missing. Must NOT send permission data off-device.

---

## AudioEngineService

**Responsibility:** Microphone capture via native AVFoundation APIs. Delivers PCM buffers to the detection pipeline and optional level data to UI.

**Inputs:** Start/stop commands, audio session configuration.

**Outputs:** Audio buffers, engine health events (started, interrupted, failed).

**Must NOT:** Perform matching, write buffers to disk, or block the main thread.

---

## TrainingService

**Responsibility:** Manages the three-sample recording flow during onboarding and re-train. Coordinates capture, fingerprint extraction, and profile assembly.

**Inputs:** Record/stop/re-record commands, raw sample buffers from `AudioEngineService`.

**Outputs:** `PanicSignalProfile` ready for persistence.

**Must NOT:** Retain raw audio after fingerprint extraction. Must NOT upload samples.

---

## FingerprintExtractor

**Responsibility:** Deterministic conversion of a fixed-duration audio segment into a feature vector. Shared by training and live detection.

**Inputs:** Normalised PCM audio segment.

**Outputs:** `Fingerprint` (feature vector + metadata: duration, peak level).

**Must NOT:** Perform matching, access the microphone directly, or depend on network.

---

## SignalMatcher

**Responsibility:** Compare a candidate fingerprint against each fingerprint in the stored profile. Return best-match similarity.

**Inputs:** Candidate `Fingerprint`, `PanicSignalProfile`.

**Outputs:** Raw similarity score (0.0–1.0) and index of best-matching training sample.

**Must NOT:** Apply threshold logic, manage cooldown, or trigger browser actions.

---

## ConfidenceEngine

**Responsibility:** Convert raw similarity into a confidence score. Enforce match threshold and post-trigger cooldown to prevent repeated fires.

**Inputs:** Similarity score, current time, cooldown state, configured threshold.

**Outputs:** `MatchResult` (confidence, shouldTrigger boolean).

**Must NOT:** Hide browsers, access audio hardware, or persist state beyond cooldown timer.

---

## TriggerEngine

**Responsibility:** Single gate between detection and action. Accepts qualified match events and dispatches exactly one hide action per cooldown window.

**Inputs:** `MatchResult` where `shouldTrigger == true`.

**Outputs:** `TriggerEvent` to `BrowserControlService`.

**Must NOT:** Perform detection, score confidence, or execute actions other than dispatching the hide trigger.

---

## BrowserDetectionService

**Responsibility:** Identify the frontmost application and determine whether it is a supported browser.

**Inputs:** Active application snapshot (bundle identifier, process name).

**Outputs:** `BrowserTarget` (supported / unsupported / none).

**Must NOT:** Hide windows, enumerate all open windows, or interact with browsers beyond identification.

**Supported bundle IDs (representative):**

| Browser | Bundle ID |
|---|---|
| Safari | `com.apple.Safari` |
| Chrome | `com.google.Chrome` |
| Arc | `company.thebrowser.Browser` |
| Brave | `com.brave.Browser` |
| Edge | `com.microsoft.edgemac` |

---

## BrowserControlService

**Responsibility:** Hide the frontmost window of a confirmed supported browser using Accessibility APIs.

**Inputs:** `BrowserTarget`, Accessibility permission state.

**Outputs:** Success / failure result.

**Must NOT:** Quit applications, close tabs, manipulate non-browser apps, or operate without Accessibility permission.

---

## LocalProfileStore

**Responsibility:** Persist and load `PanicSignalProfile`, user preferences (launch at login, listening paused), and onboarding completion flag.

**Inputs:** Profile data, preference updates.

**Outputs:** Loaded profile or nil, preference values.

**Must NOT:** Store raw audio, sync to cloud, or encrypt with account-linked keys.

---

## LaunchAtLoginService

**Responsibility:** Register and unregister Ahem as a login item via native macOS APIs (`SMAppService` or equivalent).

**Inputs:** Enable / disable toggle.

**Outputs:** Registration state.

**Must NOT:** Launch arbitrary applications or require network.

---

# Audio Detection Strategy

Version 1 uses **local user-trained fingerprint matching**.

The user records three samples of their panic signal (typically an exaggerated "AHEM!" or cough). Each sample is converted into a fingerprint — a compact numerical representation of the sound's acoustic features. Fingerprints are stored in a `PanicSignalProfile`. During live listening, candidate sounds are fingerprinted and compared against this profile.

**Explicit constraints:**

- No speech recognition
- No cloud processing
- No permanent raw audio storage
- No transcription
- Raw training samples are discarded immediately after fingerprint extraction

The algorithm is intentionally simple and deterministic for v1. It prioritises speed and replaceability over maximum accuracy.

---

# Training Flow

1. User records **three** panic signal samples via guided onboarding UI.
2. Each sample is passed to `FingerprintExtractor` and converted into a `Fingerprint`.
3. The three fingerprints are combined into a single `PanicSignalProfile` (aggregate of individual fingerprints + creation timestamp).
4. Raw audio buffers for all samples are **discarded** — only fingerprints persist.
5. `LocalProfileStore` writes the profile to local disk.
6. Optional validation step: user performs the signal once; pipeline confirms detection before onboarding completes.

Re-train replaces the existing profile atomically. Only one profile exists at any time.

---

# Live Detection Flow

1. `AudioEngineService` streams microphone input locally on a background queue.
2. `Event Detector` ignores quiet background audio below an energy threshold.
3. Short, loud candidate sounds are isolated into fixed-duration segments.
4. `FingerprintExtractor` produces a candidate fingerprint from each segment.
5. `SignalMatcher` compares the candidate against all fingerprints in the stored `PanicSignalProfile`.
6. `ConfidenceEngine` calculates a confidence score from the best similarity and applies the match threshold.
7. `TriggerEngine` fires only if confidence ≥ threshold and cooldown has elapsed.
8. Cooldown timer (configurable constant, not user-facing) prevents repeated triggers from a single utterance or echo.

When listening is paused, the pipeline stops at step 1. No buffers are processed.

---

# Browser Hiding Flow

1. `TriggerEngine` emits a trigger event.
2. `BrowserDetectionService` reads the currently active (frontmost) application.
3. If the active app is a supported browser (Safari, Chrome, Arc, Brave, Edge), proceed. Otherwise, do nothing — no error UI, no fallback action.
4. `BrowserControlService` hides the frontmost window of that browser via Accessibility APIs.
5. On failure (permission revoked, API error), log locally and surface status in menu bar if persistent. Do not retry aggressively.

Hide means minimise/conceal the window — not quit the application, not close tabs.

---

# Permissions

| Permission | Purpose | Required for |
|---|---|---|
| **Microphone** | Capture audio for training and live detection | `AudioEngineService` |
| **Accessibility** | Hide windows of other applications | `BrowserControlService` |

Both permissions must be explained in plain language **before** the system dialog or Settings deep-link is shown. Onboarding blocks until each is granted. If revoked at runtime, listening pauses and the menu bar reflects the degraded state with recovery instructions.

---

# Performance Targets

| Metric | Target |
|---|---|
| Trigger response (confident detection → browser hidden) | **< 100 ms** |
| Maximum acceptable trigger response | **200 ms** |
| Audio processing overhead | Lightweight enough to run continuously on Apple Silicon without measurable CPU impact in normal use |
| UI thread | Must never block audio processing; all capture and detection on background queues |

Measurement point for latency: from `ConfidenceEngine` emitting `shouldTrigger` to `BrowserControlService` completing the hide call.

---

# Privacy Constraints

- No accounts
- No cloud services or outbound network calls
- No permanent audio recordings on disk
- No speech transcription
- No microphone data analytics or telemetry
- Local `PanicSignalProfile` only — fingerprints, not audio

Audio buffers exist only in memory for the duration of processing and are not written to disk, crash logs, or third-party SDKs.

---

# Failure Modes

| Failure | System behaviour |
|---|---|
| **Microphone permission denied** | Block onboarding at microphone step. If revoked at runtime, stop audio engine, show recovery guidance in menu. |
| **Accessibility permission denied** | Block onboarding at accessibility step. If revoked at runtime, detection may continue but hide is suppressed; menu shows warning. |
| **No trained panic signal** | Redirect to onboarding / re-train. Do not start live listening. |
| **Active app is not a browser** | Trigger is consumed silently. No hide, no notification. |
| **Confidence too low** | Candidate discarded. No trigger. No user feedback (avoid noise). |
| **Audio engine fails** | Stop listening, set menu status to error, attempt restart on next app activation or user resume. |
| **Browser hide fails** | Log failure locally. Do not retry in a tight loop. Surface persistent failure in menu bar status. |

All failure modes fail quietly from the user's perspective unless recovery action is required.

---

# Testing Strategy

Each component exposes a protocol boundary. Concrete implementations are swappable with mocks.

| Component | Test approach |
|---|---|
| `FingerprintExtractor` | Unit tests with fixture audio segments → expected fingerprint dimensions and stability. |
| `SignalMatcher` | Unit tests: known fingerprints, known profile → expected similarity scores. |
| `ConfidenceEngine` | Unit tests: score at/above/below threshold, cooldown enforcement, edge cases (zero similarity). |
| `TriggerEngine` | Unit tests: verify single dispatch per cooldown, no dispatch below threshold. |
| `BrowserDetectionService` | Unit tests with mock active-app snapshots for each supported and unsupported bundle ID. |
| `BrowserControlService` | Mock implementation records hide calls; verify correct target and no-op for unsupported apps. |
| `PermissionService` | Mock implementation simulates granted/denied/revoked states. |
| `AudioEngineService` | Inject mock candidate buffers into `Event Detector` downstream; bypass hardware in CI. |
| **End-to-end** | Manual test on device: train signal, open supported browser, perform signal, confirm hide within latency target. |

CI runs all unit and integration tests with mocks. Hardware-dependent tests are manual or run on a dedicated test machine.

---

# Future Replaceability

The detection layer is bounded by two protocols:

- `FingerprintExtractorProtocol` — audio segment in, fingerprint out
- `SignalMatcherProtocol` — fingerprint + profile in, similarity out

`TrainingService`, `ConfidenceEngine`, and `TriggerEngine` depend on these protocols, not concrete types. Replacing fingerprint matching with SoundAnalysis, Core ML, or another on-device model requires new implementations of these two protocols only.

The following remain unchanged across a detection swap:

- Onboarding flow and UI
- Permission handling
- Menu bar and app coordination
- Browser detection and control
- Local profile store (profile schema may gain fields; migration is a separate concern)
- Launch at login

---

# Out of Scope

The following are explicitly excluded from this architecture:

- Multiple panic signals
- Multiple actions
- Speech recognition
- Cloud models or remote inference
- Browser extensions
- Custom workflows or automation rules
- AI / LLM features
- App Store distribution (architecture does not preclude it later; not in MVP scope)
- Accounts, authentication, or subscription infrastructure

Any proposal touching the above requires a new product version and revision of `Docs/PRODUCT.md` and `Docs/NON_NEGOTIABLES.md`.
