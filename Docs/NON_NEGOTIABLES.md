# Non-Negotiables

The constitution for Ahem. Every product and engineering decision is measured against these principles. When in doubt, refer here — not to momentum, not to convenience, not to what other apps do.

---

## 1. One Trigger

Version 1 supports exactly one user-trained panic signal.

No additional trigger types are permitted in the MVP. No keyword lists, no gesture shortcuts, no backup sounds, no profiles. The user trains one sound. That is the trigger. Expanding beyond this fractures the product's identity and adds configuration surface that Version 1 does not need.

---

## 2. One Action

Version 1 performs exactly one action: hide the currently active browser.

Nothing else. No dimming the screen, no locking the Mac, no closing tabs, no switching desktops. One detection, one outcome. Predictability is the feature.

---

## 3. Local First

All detection happens on the user's Mac.

No cloud processing. No server dependency. The core loop — listen, detect, hide — must work with the network disabled. Ahem is a utility, not a service.

---

## 4. Privacy by Design

No permanent audio recordings. No speech transcription. No audio leaves the device. No account required.

Trust is not a setting; it is the architecture. Users grant microphone access for one reason. Honour that reason and nothing more.

---

## 5. Native macOS

Ahem must feel like a first-party macOS utility.

Prefer native APIs over third-party libraries whenever practical. Menu bar presence, system permissions, window management, and login items should use platform conventions users already understand. If it looks or behaves like a port, it fails this principle.

---

## 6. Instant Response

The product should feel instantaneous.

Target detection latency should be under 100 milliseconds. The maximum acceptable latency is 200 milliseconds. Every engineering decision should favour responsiveness — model size, buffer length, polling interval, permission checks. A panic signal that arrives late is not a panic signal.

---

## 7. Invisible Utility

Ahem lives in the menu bar.

It should stay out of the user's way. No unnecessary windows. No unnecessary notifications. The app earns its place by working silently in the background and appearing only when the user needs it.

---

## 8. Minimal Interface

Every screen must have a clear purpose. Every button must justify its existence.

If something can be removed without harming the experience, remove it. Onboarding, the menu, and any error state should contain the minimum viable UI to complete the task. Decoration is not design.

---

## 9. No Feature Creep

Version 1 is not an automation platform.

Do not add:

- Multiple triggers
- Multiple actions
- AI features
- Browser extensions
- Cloud sync
- Accounts
- Themes
- Plugins
- Custom workflows

These belong to future versions only if the core experience succeeds. Scope expansion before the single trigger → hide loop is proven is how utilities become platforms nobody asked for.

---

## 10. Every Feature Must Earn Its Place

Before any feature is implemented, ask:

**Does this make the first 60 seconds of using Ahem noticeably better?**

If the answer is no, it does not belong in Version 1. Ahem is judged in the moment of need — download, train, trigger, browser gone. Everything else is a distraction until that loop is flawless.

---

## Decision Filter

Every product and engineering decision must be evaluated against these principles before implementation.

If a proposed change violates any non-negotiable, it does not ship — regardless of how small the change seems, how easy it is to build, or how compelling the use case sounds in isolation. Revisit the proposal only after the core experience is complete, proven, and loved.

When two valid approaches exist, choose the one that best satisfies Principles 3, 6, and 8: local, fast, minimal.
