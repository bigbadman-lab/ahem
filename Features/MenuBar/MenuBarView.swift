import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var appState: AppState
    let coordinator: AppCoordinator

    @Environment(\.openWindow) private var openWindow

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appState = ObservedObject(wrappedValue: coordinator.appState)
    }

    private var presentation: MenuBarPresentation {
        appState.menuDisplayStatus.menuPresentation(
            hasFingerprint: coordinator.hasStoredFingerprint,
            isTrainingSessionActive: coordinator.isTrainingSessionActive
        )
    }

    var body: some View {
        Group {
            statusSection

            if presentation.showsLastTrained, let lastTrainedAt = appState.lastTrainedAt {
                lastTrainedSection(date: lastTrainedAt)
            }

            Divider()

            primaryActionSection
            secondaryActionsSection

            Divider()

            Button("Quit") {
                coordinator.quit()
            }
        }
        .padding(.horizontal, AhemLayout.menuHorizontalPadding)
        // Startup is triggered from MenuBarStatusLabel (always present).
        // Do not present setup windows from menu open — that made first launch wait for a click.
    }

    @ViewBuilder
    private var statusSection: some View {
        Text(presentation.statusLine)
            .font(.headline)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func lastTrainedSection(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last trained")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                Text("•")
                    .foregroundStyle(.secondary)
                Text(date.formatted(date: .omitted, time: .shortened))
            }
            .font(.subheadline)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var primaryActionSection: some View {
        if let primaryAction = presentation.primaryAction {
            Button(presentation.primaryActionTitle) {
                performPrimaryAction(primaryAction)
            }
            .disabled(coordinator.isTrainingSessionActive)
        }
    }

    @ViewBuilder
    private var secondaryActionsSection: some View {
        if presentation.showsListeningToggle {
            Button(presentation.listeningToggleTitle) {
                coordinator.pauseListening()
            }
            .disabled(coordinator.isTrainingSessionActive)
        }

        Button("Preferences…") {
            presentPreferences()
        }

        Button("About Ahem") {
            presentAbout()
        }

        // TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.
        Button("Copy Diagnostics") {
            coordinator.copyDiagnosticsToClipboard()
        }

        if let confirmation = appState.diagnosticsCopyConfirmation {
            Text(confirmation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func performPrimaryAction(_ action: MenuBarPrimaryAction) {
        switch action {
        case .trainPanicCough, .trainAgain:
            presentTraining()
        case .resumeListening:
            coordinator.resumeListening()
        case .grantMicrophonePermission:
            coordinator.requestMicrophonePermission()
        }
    }

    private func presentTraining() {
        bringAppForwardForSetupWindow()
        coordinator.prepareTrainingUI()
        openWindow(id: TrainingWindowID.value)
    }

    private func presentPreferences() {
        bringAppForwardForSetupWindow()
        openWindow(id: PreferencesWindowID.value)
    }

    private func presentAbout() {
        bringAppForwardForSetupWindow()
        openWindow(id: AboutWindowID.value)
    }
}

/// Always-visible menu bar label. Starts the coordinator at launch and presents
/// setup windows without requiring the user to open the menu.
struct MenuBarStatusLabel: View {
    @ObservedObject private var appState: AppState
    let coordinator: AppCoordinator

    @Environment(\.openWindow) private var openWindow

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appState = ObservedObject(wrappedValue: coordinator.appState)
    }

    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel(menuBarAccessibilityLabel)
            .onAppear {
                coordinator.start()
                presentPendingStartupSetupIfNeeded()
            }
            .onChange(of: appState.setupPresentationRequest) { _, request in
                guard request != nil else { return }
                presentPendingStartupSetupIfNeeded()
            }
    }

    private var menuBarAccessibilityLabel: String {
        switch appState.menuDisplayStatus {
        case .listening, .panicDetected:
            return "Ahem — Listening"
        case .paused:
            return "Ahem — Paused"
        case .training, .trainingComplete:
            return "Ahem — Training"
        case .microphonePermissionNeeded, .microphonePermissionDenied:
            return "Ahem — Microphone Permission Required"
        case .needsTraining, .starting:
            return "Ahem — Setup Needed"
        default:
            return "Ahem"
        }
    }

    private func presentPendingStartupSetupIfNeeded() {
        guard let request = appState.setupPresentationRequest else { return }
        guard !coordinator.didConsumeStartupSetupPresentation else {
            #if DEBUG
            print("[Onboarding] Already presented — skipping duplicate")
            #endif
            appState.setupPresentationRequest = nil
            return
        }

        bringAppForwardForSetupWindow()

        switch request {
        case .onboarding:
            if appState.onboardingPhase == .idle {
                coordinator.prepareOnboarding()
            }
            if let existing = NSApp.windows.first(where: {
                $0.title.localizedCaseInsensitiveContains("Welcome to Ahem") && $0.isVisible
            }) {
                #if DEBUG
                print("[Onboarding] Already presented — bringing existing window forward")
                #endif
                existing.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: OnboardingWindowID.value)
            }

        case .training:
            if appState.trainingUIPhase == .idle {
                coordinator.prepareTrainingUI()
            }
            if let existing = NSApp.windows.first(where: {
                $0.title.localizedCaseInsensitiveContains("Train your cough") && $0.isVisible
            }) {
                #if DEBUG
                print("[Onboarding] Already presented — bringing existing training window forward")
                #endif
                existing.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: TrainingWindowID.value)
            }
        }

        coordinator.markStartupSetupPresented()
    }
}

@MainActor
private func bringAppForwardForSetupWindow() {
    // Accessory / LSUIElement apps need a brief activation so setup windows appear in front.
    let previousPolicy = NSApp.activationPolicy()
    if previousPolicy != .regular {
        NSApp.setActivationPolicy(.regular)
    }
    NSApp.activate(ignoringOtherApps: true)

    // Restore accessory shortly after the window is ordered front.
    if previousPolicy != .regular {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
