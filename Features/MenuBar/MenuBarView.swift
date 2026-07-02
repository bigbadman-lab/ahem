import SwiftUI

struct MenuBarView: View {
    let coordinator: AppCoordinator

    var body: some View {
        Text("Ahem is running.")
        Divider()
        Button("Quit") {
            coordinator.quit()
        }
    }
}
