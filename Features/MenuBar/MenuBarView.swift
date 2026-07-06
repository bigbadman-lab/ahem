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

    private var trainButtonTitle: String {
        coordinator.hasStoredFingerprint ? "Train Again" : "Train Panic Signal"
    }

    var body: some View {
        Group {
            Text(appState.status.menuBarLabel)
            Divider()
            Button(trainButtonTitle) {
                presentTraining()
            }
            .disabled(coordinator.isTrainingSessionActive)
            Divider()
            Button("Quit") {
                coordinator.quit()
            }
        }
        .onAppear {
            coordinator.start()
        }
    }

    private func presentTraining() {
        NSApp.activate(ignoringOtherApps: true)
        coordinator.prepareTrainingUI()
        openWindow(id: TrainingWindowID.value)
    }
}
