import AppKit
import SwiftUI

struct PreferencesView: View {
    let coordinator: AppCoordinator

    @ObservedObject private var preferences: UserPreferencesStore
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _preferences = ObservedObject(wrappedValue: coordinator.preferences)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch Ahem at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        updateLaunchAtLogin(isEnabled)
                    }

                Button("Retrain Panic Cough…") {
                    presentTraining()
                }
                .disabled(coordinator.isTrainingSessionActive)

                Toggle(
                    "Play confirmation sound after successful training",
                    isOn: $preferences.playConfirmationSoundAfterTraining
                )
            } header: {
                Text("General")
            }

            if let launchAtLoginError {
                Section {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(AhemLayout.windowContentPadding / 2)
        .frame(
            minWidth: AhemLayout.preferencesWindowMinWidth,
            minHeight: AhemLayout.preferencesWindowMinHeight
        )
        .onAppear {
            refreshLaunchAtLoginState()
        }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLogin = coordinator.isLaunchAtLoginEnabled
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        launchAtLoginError = nil

        do {
            try coordinator.setLaunchAtLoginEnabled(isEnabled)
            refreshLaunchAtLoginState()
        } catch {
            launchAtLoginError = "Could not update Launch at Login. Try again in System Settings."
            refreshLaunchAtLoginState()
        }
    }

    private func presentTraining() {
        NSApp.activate(ignoringOtherApps: true)
        coordinator.prepareTrainingUI()
        openWindow(id: TrainingWindowID.value)
    }
}

enum PreferencesWindowID {
    static let value = "preferences"
}
