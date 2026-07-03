import Combine

enum AppStatus {
    case starting
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
}
