import Combine

enum AppStatus: Equatable {
    case starting
    case microphonePermissionNeeded
    case listening
    case microphonePermissionDenied
    case audioError(String)
}

extension AppStatus {
    var menuBarLabel: String {
        switch self {
        case .starting:
            return "Starting…"
        case .microphonePermissionNeeded:
            return "Microphone Permission Needed"
        case .listening:
            return "Listening"
        case .microphonePermissionDenied:
            return "Microphone Permission Denied"
        case .audioError:
            return "Audio Error"
        }
    }
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
}
