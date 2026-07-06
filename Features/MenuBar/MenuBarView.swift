import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var appState: AppState
    let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appState = ObservedObject(wrappedValue: coordinator.appState)
    }

    var body: some View {
        Group {
            Text(appState.status.menuBarLabel)
            Divider()
            Button("Quit") {
                coordinator.quit()
            }
        }
        .onAppear {
            coordinator.start()
        }
    }
}
