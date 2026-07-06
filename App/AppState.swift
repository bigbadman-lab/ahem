import Combine

enum AppStatus: Equatable {
    case starting
    case microphonePermissionNeeded
    case listening
    case microphonePermissionDenied
    case audioError(String)
    case training(sample: Int, total: Int)
    case trainingComplete
    case trainingFailed(String)
    case panicDetected
}

extension AppStatus {
    var menuBarLabel: String {
        switch self {
        case .starting:
            return "Starting…"
        case .microphonePermissionNeeded:
            return "Microphone Permission Needed"
        case .listening, .panicDetected:
            return "Listening"
        case .microphonePermissionDenied:
            return "Microphone Permission Denied"
        case .audioError:
            return "Audio Error"
        case .training(let sample, let total):
            return "Training \(sample)/\(total)"
        case .trainingComplete:
            return "Training Complete"
        case .trainingFailed:
            return "Training Failed"
        }
    }

    var isTrainingSessionActive: Bool {
        switch self {
        case .training, .trainingComplete:
            return true
        default:
            return false
        }
    }
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
}
