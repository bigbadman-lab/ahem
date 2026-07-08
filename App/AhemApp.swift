import SwiftUI

@main
struct AhemApp: App {
    @StateObject private var appState: AppState
    @StateObject private var coordinator: AppCoordinator

    init() {
        let appState = AppState()
        let coordinator = AppCoordinator(appState: appState)

        _appState = StateObject(wrappedValue: appState)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("Ahem")
        }
        .menuBarExtraStyle(.menu)

        Window("Welcome to Ahem", id: OnboardingWindowID.value) {
            OnboardingView(coordinator: coordinator)
        }
        .defaultSize(width: AhemLayout.windowMinWidth + 20, height: AhemLayout.trainingWindowMinHeight + 40)

        Window("Train your cough", id: TrainingWindowID.value) {
            TrainingView(coordinator: coordinator)
        }
        .defaultSize(width: AhemLayout.windowMinWidth + 20, height: AhemLayout.trainingWindowMinHeight + 40)

        Window("Preferences", id: PreferencesWindowID.value) {
            PreferencesView(coordinator: coordinator)
        }
        .defaultSize(
            width: AhemLayout.preferencesWindowMinWidth,
            height: AhemLayout.preferencesWindowMinHeight
        )

        Window("About Ahem", id: AboutWindowID.value) {
            AboutView()
        }
        .defaultSize(width: AhemLayout.aboutWindowMinWidth, height: AhemLayout.aboutWindowMinHeight)
    }
}
