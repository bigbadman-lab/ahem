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
        appState.status.menuPresentation(
            hasFingerprint: coordinator.hasStoredFingerprint,
            isTrainingSessionActive: coordinator.isTrainingSessionActive
        )
    }

    var body: some View {
        Group {
            statusBlock

            Divider()

            actionsSection

            Divider()

            Button("Preferences…") {
                presentPreferences()
            }

            Button("About Ahem") {
                presentAbout()
            }

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
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.statusLine)
                .font(.headline)

            if presentation.showsLastTrained, let lastTrainedAt = appState.lastTrainedAt {
                Text("Last trained")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.formatLastTrained(lastTrainedAt))
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionsSection: some View {
        if let primaryAction = presentation.primaryAction {
            Button(presentation.primaryActionTitle) {
                performPrimaryAction(primaryAction)
            }
            .disabled(coordinator.isTrainingSessionActive)
        }

        if let secondaryAction = presentation.secondaryAction {
            Button(presentation.secondaryActionTitle) {
                performPrimaryAction(secondaryAction)
            }
            .disabled(coordinator.isTrainingSessionActive)
        }

        if presentation.showsListeningToggle {
            Button(presentation.listeningToggleTitle) {
                coordinator.pauseListening()
            }
            .disabled(coordinator.isTrainingSessionActive)
        }

        if presentation.showsResumeToggle {
            Button("Resume Listening") {
                coordinator.resumeListening()
            }
            .disabled(coordinator.isTrainingSessionActive)
        }
    }

    private func performPrimaryAction(_ action: MenuBarPrimaryAction) {
        switch action {
        case .trainPanicCough, .trainAgain:
            presentTraining()
        case .resumeListening:
            coordinator.resumeListening()
        case .retryListening:
            coordinator.retryListening()
        case .grantMicrophonePermission:
            coordinator.requestMicrophonePermission()
        }
    }

    private func presentTraining() {
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Train your cough")
        coordinator.prepareTrainingUI()
        openWindow(id: TrainingWindowID.value)
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Train your cough")
    }

    private func presentPreferences() {
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Preferences")
        openWindow(id: PreferencesWindowID.value)
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Preferences")
    }

    private func presentAbout() {
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "About Ahem")
        openWindow(id: AboutWindowID.value)
        AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "About Ahem")
    }

    private static func formatLastTrained(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) {
            return "Today at \(time)"
        }

        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day) at \(time)"
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
        switch appState.status {
        case .listening, .panicDetected:
            return "Ahem — Ready"
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

        switch request {
        case .onboarding:
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Welcome to Ahem")
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
                existing.orderFrontRegardless()
            } else {
                openWindow(id: OnboardingWindowID.value)
            }
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Welcome to Ahem")

        case .training:
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Train your cough")
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
                existing.orderFrontRegardless()
            } else {
                openWindow(id: TrainingWindowID.value)
            }
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Train your cough")
        }

        coordinator.markStartupSetupPresented()
    }
}
