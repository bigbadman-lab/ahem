# Build Plan

Implementation order for the Ahem macOS MVP. Work milestones sequentially. Each milestone must meet its exit criteria before the next begins.

**Source of truth:**

- `Docs/PRODUCT.md`
- `Docs/NON_NEGOTIABLES.md`
- `Docs/ARCHITECTURE.md`
- `Docs/STATE_MACHINE.md`

---

# Milestone 0 — Project Foundation

**Goal:** Create the native macOS app skeleton.

**Includes:**
- SwiftUI macOS app target
- Menu bar app behaviour (`LSUIElement` or equivalent — no Dock icon)
- `AppCoordinator` stub with lifecycle hooks
- Folder structure aligned with `Docs/ARCHITECTURE.md` components
- App launches without errors

**Exit criteria:**
- Ahem launches as a menu bar utility.
- No Dock icon visible.
- No crashes on cold start or quit.

**Depends on:** Nothing.

**Doc alignment:** `Docs/ARCHITECTURE.md` (Overview, AppCoordinator), `Docs/NON_NEGOTIABLES.md` (Native macOS, Invisible Utility).

---

# Milestone 1 — Menu Bar Shell

**Goal:** Create the first usable menu bar interface.

**Includes:**
- Menu bar icon and dropdown menu
- Status label (static placeholder acceptable)
- **Start Setup** menu item
- **Pause / Resume** placeholder (disabled or no-op)
- **Re-train** placeholder (disabled or no-op)
- **Share your first Ahem** placeholder (disabled or no-op)
- **Quit**

**Exit criteria:**
- The app feels like a real menu bar utility even before detection exists.
- All menu items render; placeholders do not crash.

**Depends on:** Milestone 0.

**Doc alignment:** `Docs/PRODUCT.md` (Menu Bar), `Docs/ARCHITECTURE.md` (MenuBarController).

---

# Milestone 2 — Permission System

**Goal:** Implement permission checks and onboarding gates.

**Includes:**
- `PermissionService` for Microphone and Accessibility
- Permission status queries on launch
- Permission explanation screens (no system dialog before explanation)
- State transitions per `Docs/STATE_MACHINE.md`: `FreshInstall` → `NeedsMicrophonePermission` → `NeedsAccessibilityPermission`

**Exit criteria:**
- The app correctly knows whether it needs microphone permission, Accessibility permission, or training.
- Denied permissions block progress with recovery instructions.
- Revoked permissions transition to the correct setup state.

**Depends on:** Milestone 1.

**Doc alignment:** `Docs/STATE_MACHINE.md` (permission states, Transition Rules), `Docs/ARCHITECTURE.md` (PermissionService), `Docs/PRODUCT.md` (Onboarding permission steps).

---

# Milestone 3 — Onboarding Flow

**Goal:** Implement the full onboarding experience.

**Includes:**
- Welcome screen
- Permission steps (wired to Milestone 2)
- Training intro screen
- Success screen with launch-at-login placeholder
- **Share your first Ahem** prompt placeholder on success
- Linear flow: no skip, no back-navigation to unrelated settings

**Exit criteria:**
- A user can move through setup without audio detection being functional yet.
- Onboarding completion flag persists.
- Menu bar status reflects setup progress (`Needs Setup`, `Training`).

**Depends on:** Milestone 2.

**Doc alignment:** `Docs/PRODUCT.md` (Onboarding, User Journey), `Docs/STATE_MACHINE.md` (setup states), `Docs/ARCHITECTURE.md` (OnboardingCoordinator).

---

# Milestone 4 — Training Capture

**Goal:** Capture three local panic signal samples.

**Includes:**
- `AudioEngineService` for training capture only
- Three-sample recording flow with progress (1/3, 2/3, 3/3)
- Re-record per sample
- Basic validation: silence, too short, too long
- Temporary in-memory raw audio only
- No permanent raw recording storage

**Exit criteria:**
- The app can record three usable training samples locally.
- Invalid samples are rejected with clear feedback.
- `Training` state entered and exited per state machine.

**Depends on:** Milestone 3.

**Doc alignment:** `Docs/ARCHITECTURE.md` (TrainingService, AudioEngineService, Training Flow), `Docs/NON_NEGOTIABLES.md` (Privacy by Design), `Docs/STATE_MACHINE.md` (`Training`, `TrainingFailed`).

---

# Milestone 5 — Fingerprint Profile

**Goal:** Convert training samples into a local `PanicSignalProfile`.

**Includes:**
- `FingerprintExtractor`
- `PanicSignalProfile` model
- `LocalProfileStore` (save, load, delete)
- Store only compact fingerprint data
- Discard raw samples immediately after fingerprint extraction

**Exit criteria:**
- A valid panic signal profile can be created, saved, loaded, and deleted.
- No raw audio persists on disk after training completes.
- Re-train replaces profile atomically.

**Depends on:** Milestone 4.

**Doc alignment:** `Docs/ARCHITECTURE.md` (FingerprintExtractor, LocalProfileStore, Audio Detection Strategy), `Docs/PRODUCT.md` (Privacy).

---

# Milestone 6 — Live Detection

**Goal:** Detect candidate sounds from live microphone input.

**Includes:**
- `AudioEngineService` continuous capture on background queue
- `EventDetector` (energy threshold, segment isolation)
- `CandidateDetected` state integration
- Ignore quiet background noise
- Isolate short, loud candidates

**Exit criteria:**
- The app can identify possible panic signal candidates without triggering actions.
- Audio processing does not block the main thread.
- Engine starts from `Listening` and stops on `Paused`.

**Depends on:** Milestone 5.

**Doc alignment:** `Docs/ARCHITECTURE.md` (Core Pipeline, Live Detection Flow), `Docs/STATE_MACHINE.md` (`Listening`, `CandidateDetected`), `Docs/NON_NEGOTIABLES.md` (Instant Response).

---

# Milestone 7 — Matching + Confidence

**Goal:** Compare live candidates against the stored profile.

**Includes:**
- `SignalMatcher`
- `ConfidenceEngine`
- Threshold logic (constant, not user-configurable in v1)
- Match accepted / rejected paths
- Cooldown logic
- `Matching`, `Triggering`, `Cooldown` state integration

**Exit criteria:**
- The app can reliably decide whether a candidate should trigger.
- Rejected candidates produce no UI noise.
- Cooldown prevents repeat triggers.
- Unit tests for matcher and confidence scoring pass.

**Depends on:** Milestone 6.

**Doc alignment:** `Docs/ARCHITECTURE.md` (SignalMatcher, ConfidenceEngine, TriggerEngine, Testing Strategy), `Docs/STATE_MACHINE.md` (pipeline states, Transition Rules).

---

# Milestone 8 — Browser Detection + Hide

**Goal:** Hide the active supported browser.

**Includes:**
- `BrowserDetectionService`
- `BrowserControlService`
- Supported browser bundle IDs: Safari, Chrome, Arc, Brave, Edge
- Active app detection via frontmost application
- Hide supported browser frontmost window via Accessibility APIs
- Do nothing if active app is not a supported browser

**Exit criteria:**
- When triggered manually (test hook), the active supported browser hides.
- Non-browser frontmost app: no hide, no error UI.
- Hide failure surfaces in menu bar status.

**Depends on:** Milestone 2 (Accessibility permission). Can be built in parallel with Milestones 6–7 if permissions are granted in dev.

**Doc alignment:** `Docs/ARCHITECTURE.md` (Browser Hiding Flow, BrowserDetectionService, BrowserControlService), `Docs/PRODUCT.md` (MVP Scope browser support).

---

# Milestone 9 — End-to-End MVP

**Goal:** Connect the full pipeline.

**Includes:**
- Training → profile storage → live detection → confidence → browser hide → cooldown
- `TriggerEngine` wiring detection to browser control
- Pause / resume from menu bar
- Re-train from menu bar
- Startup resolution per `Docs/STATE_MACHINE.md`
- `Ready` → `Listening` on launch when not paused

**Exit criteria:**
- A user can install Ahem, train a panic signal, make the signal, and hide their active browser.
- Full loop works with network disabled.
- Trigger response within 200ms maximum (100ms target — measure and log).

**Depends on:** Milestones 5, 7, 8.

**Doc alignment:** All docs. This milestone is the integration proof for `Docs/PRODUCT.md` Success Criteria.

---

# Milestone 10 — Polish + Launch Readiness

**Goal:** Make the MVP feel premium.

**Includes:**
- Copy polish across onboarding and menu
- Native macOS UI polish (spacing, typography, system conventions)
- Error states for all failure modes in `Docs/ARCHITECTURE.md`
- First successful trigger moment (subtle confirmation acceptable; no unnecessary notifications)
- **Share your first Ahem** flow (placeholder → functional minimum: share text or link)
- `LaunchAtLoginService` wired to menu toggle
- App icon
- Basic update/distribution notes (DMG, notarisation checklist — docs only, no App Store)

**Exit criteria:**
- The app is ready for private beta distribution.
- All `Docs/PRODUCT.md` onboarding steps complete in under 3 minutes in manual testing.
- No known broken core path.

**Depends on:** Milestone 9.

**Doc alignment:** `Docs/PRODUCT.md` (User Journey, Menu Bar, Launch at Login), `Docs/NON_NEGOTIABLES.md` (Minimal Interface, Every Feature Must Earn Its Place).

---

# Rules for Every Milestone

- **One milestone at a time.** Do not start Milestone N+1 until Milestone N exit criteria are met.
- **No skipped exit criteria.** Every bullet in exit criteria must be verifiable before moving on.
- **No new features without updating `Docs/PRODUCT.md` first.** If it is not in the PRD, it does not ship.
- **No changes that violate `Docs/NON_NEGOTIABLES.md`.** Run the Decision Filter on every PR.
- **Keep commits small and descriptive.** One logical change per commit where practical.
- **Prefer simple native macOS APIs.** AVFoundation, Accessibility, `SMAppService`, SwiftUI.
- **Do not optimise before the basic flow works.** Correctness and clarity before micro-optimisation.
- **Do not polish broken flows.** Fix the core path first; polish belongs in Milestone 10.

---

# Commit Strategy

Use conventional prefixes. One concern per commit.

| Prefix | Use for |
|---|---|
| `docs:` | PRODUCT, NON_NEGOTIABLES, ARCHITECTURE, STATE_MACHINE, BUILD_PLAN, README |
| `app:` | AppCoordinator, app lifecycle, folder structure, launch behaviour |
| `permissions:` | PermissionService, permission UI, recovery flows |
| `onboarding:` | OnboardingCoordinator, welcome, success, training intro |
| `audio:` | AudioEngineService, training capture, EventDetector |
| `detection:` | FingerprintExtractor, SignalMatcher, ConfidenceEngine, TriggerEngine, profile store |
| `browser:` | BrowserDetectionService, BrowserControlService |
| `polish:` | Copy, icons, error states, launch at login, share flow, distribution notes |

**Examples:**
- `app: add menu bar shell with status label`
- `permissions: gate onboarding on microphone access`
- `detection: add cooldown after trigger`

Do not mix prefixes in a single commit unless the change is genuinely atomic (e.g. rename that touches one module).

---

# Definition of Done

A milestone is **done** only when:

1. **It builds** — clean compile, no warnings introduced that indicate broken behaviour.
2. **It runs** — verified manually on a Mac with microphone and Accessibility available.
3. **It matches the relevant docs** — behaviour aligns with `Docs/PRODUCT.md`, `Docs/NON_NEGOTIABLES.md`, `Docs/ARCHITECTURE.md`, and `Docs/STATE_MACHINE.md` for that milestone's scope.
4. **It has no known broken core path** — exit criteria met; no open bugs on the milestone's primary user flow.
5. **It has been committed to GitHub** — changes pushed to the remote branch; not only local commits.

If any criterion fails, the milestone is not done. Do not proceed.
