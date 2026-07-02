# State Machine

Allowed application states and transitions for the Ahem macOS MVP. All runtime behaviour must conform to this document. If a transition is not listed here, it is forbidden.

**State categories:**

- **Setup states** — onboarding, permissions, training. User-facing. Block live detection.
- **Operational states** — ready, listening, paused. User-facing. Control whether detection runs.
- **Pipeline states** — candidate detected through cooldown. Internal. Occur within `Listening`. Do not change menu bar label.
- **Failure states** — error, training failed. User-facing. Require recovery.

---

# FreshInstall

**Meaning:** First launch. No onboarding completed, no persisted preferences, no profile.

**Entry conditions:**
- App launches and `LocalProfileStore` reports no onboarding completion flag.

**Allowed transitions:**
- → `NeedsMicrophonePermission` (user taps **Get Started** on welcome screen)

**UI behaviour:**
- Welcome screen: product name, one-line purpose, **Get Started** CTA.
- Menu bar icon visible. Status: **Needs Setup**.

**Must NOT:**
- Request permissions before welcome screen is shown.
- Start audio engine.
- Attempt browser control.

---

# NeedsMicrophonePermission

**Meaning:** Onboarding in progress. Microphone access is missing or not yet requested.

**Entry conditions:**
- Onboarding started and microphone permission is not granted.
- OR microphone permission revoked while app was operational.

**Allowed transitions:**
- → `NeedsAccessibilityPermission` (microphone granted)
- → `NeedsMicrophonePermission` (microphone denied — remain; show recovery UI)
- → `Error` (unexpected permission query failure)

**UI behaviour:**
- Onboarding screen explaining why microphone is required.
- **Allow Microphone** CTA triggers system permission dialog.
- If denied: inline recovery instructions (System Settings → Privacy & Security → Microphone).
- Menu bar status: **Needs Setup**.

**Must NOT:**
- Capture audio.
- Proceed to accessibility or training steps.

---

# NeedsAccessibilityPermission

**Meaning:** Microphone is granted. Accessibility access is missing or not yet enabled.

**Entry conditions:**
- Microphone permission granted.
- Accessibility permission not granted.

**Allowed transitions:**
- → `NeedsTraining` (accessibility granted, no `PanicSignalProfile` on disk)
- → `Ready` (accessibility granted, valid profile exists — re-train path with permissions intact)
- → `NeedsAccessibilityPermission` (accessibility denied — remain; show recovery UI)
- → `Error` (unexpected permission query failure)

**UI behaviour:**
- Onboarding screen explaining why Accessibility is required.
- Instructions or deep-link to System Settings → Privacy & Security → Accessibility.
- If denied: inline recovery instructions.
- Menu bar status: **Needs Setup**.

**Must NOT:**
- Hide browser windows.
- Skip to training if accessibility is not granted.

---

# NeedsTraining

**Meaning:** Required permissions are granted. No valid `PanicSignalProfile` exists.

**Entry conditions:**
- Microphone and Accessibility permissions granted.
- `LocalProfileStore` has no profile or profile is invalid/corrupt.

**Allowed transitions:**
- → `Training` (user begins recording samples)
- → `NeedsMicrophonePermission` (microphone revoked)
- → `NeedsAccessibilityPermission` (accessibility revoked)

**UI behaviour:**
- Training intro screen: explain the three-sample requirement.
- **Start Training** CTA.
- Menu bar status: **Needs Setup** (or **Training** once user taps start — see `Training`).

**Must NOT:**
- Enter `Listening` without a completed profile.
- Auto-start recording without user action.

---

# Training

**Meaning:** User is actively recording the three required panic signal samples.

**Entry conditions:**
- User started training from `NeedsTraining`, onboarding, or **Re-train** menu action.
- Permissions granted.

**Allowed transitions:**
- → `Ready` (three samples captured, fingerprints extracted, profile saved)
- → `TrainingFailed` (extraction fails, insufficient quality, or persistence fails)
- → `NeedsMicrophonePermission` (microphone revoked mid-training)
- → `Paused` (only if re-train initiated from paused operational state — engine stopped, training UI shown)

**UI behaviour:**
- Sample progress indicator (1 of 3, 2 of 3, 3 of 3).
- Record / re-record controls per sample.
- Level meter or waveform feedback.
- Menu bar status: **Training**.

**Must NOT:**
- Persist raw audio to disk.
- Accept fewer than three samples as complete.
- Enter `Listening` directly — must pass through `Ready` first.

---

# TrainingFailed

**Meaning:** Training could not produce a usable `PanicSignalProfile`.

**Entry conditions:**
- Fingerprint extraction failed on one or more samples.
- Profile assembly or disk write failed.
- All three samples captured but quality validation rejected the profile.

**Allowed transitions:**
- → `Training` (user taps **Try Again**)
- → `NeedsTraining` (user dismisses to training intro)

**UI behaviour:**
- Error message with plain-language reason.
- **Try Again** CTA.
- Menu bar status: **Error**.

**Must NOT:**
- Enter `Listening` or `Ready` without a valid saved profile.
- Silently retry without user action.

---

# Ready

**Meaning:** Valid `PanicSignalProfile` exists. Required permissions granted. Audio engine not yet running.

**Entry conditions:**
- Training completed successfully.
- App launched with valid profile and permissions but monitoring not yet started.
- Transition from `Cooldown` is not applicable here — cooldown returns to `Listening`.

**Allowed transitions:**
- → `Listening` (monitoring started: onboarding complete and not paused, or user resumed)
- → `Paused` (user preference `isPaused == true` on startup)
- → `Training` (user selects **Re-train**)
- → `NeedsMicrophonePermission` (microphone revoked)
- → `NeedsAccessibilityPermission` (accessibility revoked)

**UI behaviour:**
- No onboarding window (unless re-train initiated).
- Menu bar status: **Ready**.
- Menu shows **Pause** disabled or hidden; **Resume** available only if coming from paused path.

**Must NOT:**
- Process live detection candidates (engine not running).
- Hide browsers.

---

# Listening

**Meaning:** Audio engine is running. Ahem is monitoring the microphone locally for panic signal candidates.

**Entry conditions:**
- Valid profile and permissions.
- `isPaused == false`.
- Audio engine started successfully.

**Allowed transitions:**
- → `CandidateDetected` (event detector isolates a loud candidate)
- → `Paused` (user selects **Pause**)
- → `Error` (audio engine failure)
- → `NeedsMicrophonePermission` (microphone revoked)
- → `Training` (user selects **Re-train** — stops engine first)

**UI behaviour:**
- No visible window.
- Menu bar status: **Listening**.
- Menu shows **Pause** (not Resume).

**Must NOT:**
- Block the audio thread with UI work.
- Show notifications on candidate rejection.
- Hide browsers outside the `Triggering` pipeline path.

---

# CandidateDetected

**Meaning:** A short, loud sound candidate has been isolated from the audio stream.

**Entry conditions:**
- `Listening` active.
- Event detector segments audio above energy threshold into a candidate buffer.

**Allowed transitions:**
- → `Matching` (candidate buffer passed to fingerprint extractor)
- → `Listening` (candidate discarded: too short, clipped, or invalid)
- → `Error` (extraction precondition failure)

**UI behaviour:**
- No UI change. Menu bar remains **Listening**.

**Must NOT:**
- Trigger browser hide.
- Persist candidate audio.
- Display notifications.

---

# Matching

**Meaning:** Candidate fingerprint is being compared against the stored `PanicSignalProfile`.

**Entry conditions:**
- Valid candidate fingerprint produced from `CandidateDetected`.

**Allowed transitions:**
- → `Triggering` (confidence ≥ threshold and cooldown elapsed)
- → `Listening` (confidence < threshold — candidate rejected)
- → `Cooldown` (confidence ≥ threshold but cooldown active — trigger suppressed, timer unchanged)

**UI behaviour:**
- No UI change. Menu bar remains **Listening**.

**Must NOT:**
- Hide browsers without passing through `Triggering`.
- Fire multiple triggers for a single candidate.
- Emit user-visible feedback on rejection.

---

# Triggering

**Meaning:** Confidence threshold met. Ahem is resolving the active app and attempting to hide the browser.

**Entry conditions:**
- `MatchResult.shouldTrigger == true`.
- Cooldown not active.

**Allowed transitions:**
- → `Cooldown` (hide succeeded, hide skipped because active app is not a supported browser, or hide failed)
- → `Error` (Accessibility permission lost during hide attempt)

**UI behaviour:**
- No UI change. Menu bar remains **Listening**.
- Browser window hides (if supported browser is frontmost).

**Must NOT:**
- Perform detection on new candidates concurrently (pipeline is single-flight per cooldown policy).
- Quit the browser application.
- Hide non-browser applications.
- Retry hide in a tight loop on failure.

---

# Cooldown

**Meaning:** A trigger recently fired. Repeat triggers are suppressed for a fixed interval.

**Entry conditions:**
- `Triggering` completed (success, non-browser no-op, or hide failure).

**Allowed transitions:**
- → `Listening` (cooldown timer elapsed; audio engine still running)
- → `Paused` (user pauses during cooldown)
- → `Error` (audio engine failure during cooldown)

**UI behaviour:**
- No UI change. Menu bar remains **Listening**.
- New candidates may still be processed but `Matching` must not emit triggers until cooldown completes.

**Must NOT:**
- Reset cooldown on rejected candidates.
- Extend cooldown indefinitely.
- Show cooldown status in the menu.

---

# Paused

**Meaning:** User manually paused monitoring. Audio engine is stopped.

**Entry conditions:**
- User selected **Pause** from menu bar.
- OR `isPaused == true` persisted preference on startup (after resolving to `Ready`, remain in `Paused`).

**Allowed transitions:**
- → `Listening` (user selects **Resume** and audio engine starts)
- → `Training` (user selects **Re-train**)
- → `NeedsMicrophonePermission` (microphone revoked)
- → `NeedsAccessibilityPermission` (accessibility revoked)

**UI behaviour:**
- No visible window.
- Menu bar status: **Paused**.
- Menu shows **Resume** (not Pause).

**Must NOT:**
- Process audio or run detection pipeline.
- Hide browsers (even if stale trigger event queued — discard it).

---

# Error

**Meaning:** A recoverable system-level failure occurred. Core loop cannot run until resolved.

**Entry conditions:**
- Audio engine unrecoverable error.
- Permission query failure.
- Persistent browser hide failure.
- Corrupt profile that cannot be loaded.

**Allowed transitions:**
- → `Listening` (engine restarted successfully after audio failure)
- → `NeedsMicrophonePermission` (microphone revoked)
- → `NeedsAccessibilityPermission` (accessibility revoked)
- → `NeedsTraining` (profile missing or corrupt)
- → `TrainingFailed` (if error originated in training)
- → `Paused` (user pauses from error recovery menu)

**UI behaviour:**
- Menu bar status: **Error**.
- Menu shows brief error description and recovery action where applicable.
- No modal alerts unless recovery requires user navigation to System Settings.

**Must NOT:**
- Crash or quit silently.
- Continue listening if audio engine is in a failed state.
- Send error data off-device.

---

# Transition Rules

| Event | Transition |
|---|---|
| **Permission granted** | Advance to next setup state: microphone → accessibility → training (if no profile) or `Ready` (if profile exists). |
| **Permission denied** | Remain on current permission state. Show recovery UI. Do not advance onboarding. |
| **Permission revoked** | Immediately stop audio engine. From any operational or pipeline state → corresponding `NeedsMicrophonePermission` or `NeedsAccessibilityPermission`. Discard in-flight pipeline state. |
| **Training completed** | `Training` → `Ready`. Persist profile. Set onboarding completion flag. |
| **Training failed** | `Training` → `TrainingFailed`. Discard partial profile writes. |
| **User pauses monitoring** | `Listening` or `Cooldown` → `Paused`. Stop audio engine. Persist `isPaused = true`. |
| **User resumes monitoring** | `Paused` → `Listening` (via `Ready` resolution if engine cold-start required). Persist `isPaused = false`. |
| **Candidate sound detected** | `Listening` → `CandidateDetected`. |
| **Candidate rejected** | `CandidateDetected` → `Listening` (invalid segment) OR `Matching` → `Listening` (low confidence). |
| **Match accepted** | `Matching` → `Triggering` (confidence ≥ threshold, cooldown clear). |
| **Match rejected** | `Matching` → `Listening`. |
| **Browser hidden successfully** | `Triggering` → `Cooldown`. |
| **Active app is not a browser** | `Triggering` → `Cooldown`. No hide. No user notification. |
| **Cooldown completed** | `Cooldown` → `Listening`. |
| **Audio engine failure** | Any state with engine running → `Error`. Stop pipeline. |

**Global rules:**

- Only one pipeline flight at a time: no overlapping `CandidateDetected` → `Triggering` sequences.
- Re-train from menu: stop engine if running → `Training`. Permissions re-checked but not re-requested if still granted.
- Quit: permitted from any state. No special shutdown state.

---

# Startup Resolution

On launch, `AppCoordinator` resolves state in strict order:

1. **Check microphone permission.**
   - Not granted → `NeedsMicrophonePermission` (or `FreshInstall` → welcome if first launch).
2. **Check Accessibility permission.**
   - Not granted → `NeedsAccessibilityPermission`.
3. **Check whether a local `PanicSignalProfile` exists and is valid.**
   - Missing or corrupt → `NeedsTraining`.
4. **If all are valid → enter `Ready`.**
5. **If `isPaused == false` → enter `Listening`.**
   - Start audio engine.
   - If `Launch at Login` enabled, this step applies on every login launch the same way.

If step 5 engine start fails → `Error`.

First launch with no onboarding flag: show `FreshInstall` welcome before step 1 permission UI.

---

# Menu Bar State Display

User-facing menu bar status labels. Internal pipeline states (`CandidateDetected`, `Matching`, `Triggering`, `Cooldown`) always display as **Listening**.

| App state(s) | Menu bar label |
|---|---|
| `FreshInstall`, `NeedsMicrophonePermission`, `NeedsAccessibilityPermission`, `NeedsTraining` | **Needs Setup** |
| `Training` | **Training** |
| `Ready` | **Ready** |
| `Listening`, `CandidateDetected`, `Matching`, `Triggering`, `Cooldown` | **Listening** |
| `Paused` | **Paused** |
| `Error`, `TrainingFailed` | **Error** |

Icon MAY reflect label subtly (e.g. muted icon for Paused/Error) but label text is authoritative.

---

# Non-Goals

The MVP state machine does not support:

- Multiple active panic signals or per-signal state
- Multiple trigger actions or action selection state
- Background cloud state or remote state reconciliation
- Account-based state sync across devices
- Browser extension state or cross-process state sharing
- Remote configuration or feature-flag driven state overrides

Any of the above requires a new product version and a new state machine document.
