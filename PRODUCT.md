# Product

Ahem is a native macOS menu bar utility that listens for a user-trained panic signal and instantly hides the active browser window when that signal is detected. Version 1 does one thing: recognise your sound, hide your browser. No accounts, no cloud, no configuration beyond training the trigger.

# Vision

Ahem becomes the reflex you reach for in awkward moments — a single, reliable gesture that makes your screen safe without thinking. Long term, the product stays intentionally small: one unforgettable interaction, executed instantly on-device, with no feature creep into automation platforms or general-purpose assistants.

# Design Principles

- **One trigger** — The user trains exactly one panic signal. No profiles, no alternate sounds, no keyword lists.
- **One action** — Detection always performs the same action: hide the currently active browser window.
- **Local-first** — Audio is processed on the Mac. No network calls for detection, training, or execution.
- **Native macOS** — Menu bar presence, system permissions, and OS integrations follow macOS conventions. No web wrapper, no Electron shell.
- **Instant response** — From signal detection to hidden browser, latency must feel immediate (target: perceptually instant, engineering budget &lt;200ms end-to-end where feasible).
- **No unnecessary features** — If a capability does not serve the single trigger → hide-browser loop, it does not ship in v1.

# MVP Scope

Version 1 includes:

| Capability | Requirement |
|---|---|
| **Menu bar app** | Persistent menu bar icon; no dock icon required. App runs in background after launch. |
| **User-trained panic signal** | Onboarding captures 3–5 samples of the user's chosen sound. Model/template stored locally and used for continuous matching. |
| **Browser hiding** | On match, hide (not quit) the frontmost browser window. Window state is preserved; user can restore via normal OS/window controls. |
| **Local processing** | All audio capture, feature extraction, and matching run on-device. No external APIs. |
| **Browser support** | Chrome, Safari, Arc, Brave, Edge — detected by bundle ID / process name. Only the active (key) window of a supported browser is hidden. |
| **Launch at Login** | Optional toggle (on by default after onboarding) to start Ahem automatically at login. |

Additional v1 requirements:

- Microphone permission (required for listening).
- Accessibility permission (required to hide windows of other applications).
- Re-train panic signal from the menu at any time.
- Pause/resume listening from the menu.
- Minimal error states when permissions are revoked or no supported browser is frontmost.

# User Journey

1. **Download** — User obtains the `.dmg` from getahem.com and installs Ahem to `/Applications`.
2. **First launch** — App appears in the menu bar. Onboarding starts automatically (no main window).
3. **Permissions** — User grants Microphone, then Accessibility, in sequence with clear rationale for each.
4. **Train** — User records their panic signal (guided prompts, visual feedback per sample).
5. **Success** — Confirmation screen; listening begins immediately.
6. **Daily use** — User works with a supported browser in the foreground. On panic signal, browser hides. User restores the window when ready.
7. **Return visits** — Menu bar icon indicates listening state. User can pause, re-train, or quit from the menu.

# Onboarding

Onboarding is a linear, non-skippable flow shown once on first launch (and again only if user chooses "Re-train" or permissions are reset).

### Welcome

- Single screen: product name, one-line purpose ("Train your Mac to recognise your panic signal"), primary CTA **Get Started**.
- No account creation, no analytics opt-in, no feature tour.

### Microphone permission

- Explain: Ahem needs the microphone to listen for your panic signal. Audio never leaves your Mac and is not recorded to disk.
- Trigger system Microphone permission dialog.
- Block progress until granted. If denied, show recovery instructions (System Settings → Privacy & Security → Microphone).

### Accessibility permission

- Explain: Ahem needs Accessibility access to hide your browser window when the signal is detected.
- Deep-link or instruct user to System Settings → Privacy & Security → Accessibility.
- Block progress until Ahem is enabled. If denied, show recovery instructions.

### Train panic signal

- Prompt user to choose a short, distinctive sound (e.g. a cough, snap, or spoken syllable — user decides).
- Capture 3–5 samples with visual waveform or level meter and per-sample confirmation.
- Allow re-record of individual samples before continuing.
- On completion, persist the trained model locally and validate with a test prompt: "Make your signal now" → confirm detection fires (optional but recommended for confidence).

### Success screen

- Confirm training complete. Listening is now active.
- Offer **Launch at Login** toggle (default: on).
- Single CTA **Done** — dismisses onboarding; menu bar icon reflects active listening state.

# Menu Bar

Clicking the menu bar icon opens a compact menu:

| Item | Behaviour |
|---|---|
| **Status** | Non-interactive label: "Listening" or "Paused". |
| **Pause / Resume** | Toggles listening without quitting the app. |
| **Re-train panic signal** | Restarts the training flow (permissions skipped if still granted). |
| **Launch at Login** | Checkbox; reflects and toggles login item state. |
| **About Ahem** | Version number, link to getahem.com. |
| **Quit Ahem** | Terminates the app. |

Not in the menu for v1: settings panels, browser pickers, sensitivity sliders, keyboard shortcuts editor, or account links.

# Privacy

- **No accounts.** No sign-up, login, or user identity.
- **No cloud processing.** Detection and training never send audio or features to a server.
- **No speech transcription.** Ahem matches acoustic patterns; it does not convert speech to text.
- **No permanent audio recordings.** Samples used during training are stored only as the local matching model/features, not as replayable audio files. Runtime audio buffers are ephemeral.
- **Everything stays on the Mac.** Trained model, preferences, and permission state are local only.

# Out of Scope

The following are explicitly **not** included in Version 1:

- Multiple triggers (one signal only)
- Custom actions (hide browser is the only action)
- Cloud sync (settings or models across devices)
- Accounts (authentication, profiles, subscriptions)
- Browser extension (detection or control via extension)
- AI features (LLM, cloud ML, generative anything)
- Analytics dashboard (in-app or web)
- Themes (icon variants, appearance customisation)
- Automation platform (Shortcuts integration, webhooks, scripting API, IFTTT-style rules)

# Success Criteria

Version 1 is successful when:

1. **Onboarding completion** — A new user can go from first launch to active listening in under 3 minutes, including permissions and training.
2. **Reliable detection** — The trained panic signal triggers hide action ≥95% of the time in normal ambient noise (home/office), with false positives &lt;1 per hour of active listening.
3. **Instant hide** — Browser window hides within 200ms of confirmed signal detection on Apple Silicon Macs (M-series) with a supported browser frontmost.
4. **Browser coverage** — Hide works correctly for Chrome, Safari, Arc, Brave, and Edge when each is the active application.
5. **Permission resilience** — App surfaces clear, recoverable states when Microphone or Accessibility is revoked; no silent failure.
6. **Zero network dependency** — Full core loop (listen → detect → hide) operates with network disabled.
7. **Launch at Login** — Toggle correctly registers and unregisters the login item; app auto-starts and resumes listening after reboot when enabled.
8. **Privacy guarantee** — No outbound network traffic during training or runtime (verifiable via inspection); no audio files written to disk outside the app sandbox's model store.
