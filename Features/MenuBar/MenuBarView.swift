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
        .onAppear {
            coordinator.start()
        }
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
        NSApp.activate(ignoringOtherApps: true)
        coordinator.prepareTrainingUI()
        openWindow(id: TrainingWindowID.value)
    }

    private func presentPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PreferencesWindowID.value)
    }

    private func presentAbout() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AboutWindowID.value)
    }
}
