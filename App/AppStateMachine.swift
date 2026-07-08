import Foundation

/// Legal app status transitions for Ahem.
enum AppStateMachine {
    struct Options: Equatable {
        var userInitiated: Bool = false
        var force: Bool = false
        /// Allows leaving an active training session to start listening (post-training).
        var postTrainingExit: Bool = false
        /// User explicitly confirmed training completion (final button).
        var userConfirmedTrainingCompletion: Bool = false
    }

    enum Phase: Equatable {
        case starting
        case needsTraining
        case training
        case trainingComplete
        case trainingFailed
        case listening
        case panicDetected
        case paused
        case audioError
        case microphonePermissionNeeded
        case microphonePermissionDenied
    }

    static func phase(of status: AppStatus) -> Phase {
        switch status {
        case .starting:
            return .starting
        case .needsTraining:
            return .needsTraining
        case .training:
            return .training
        case .trainingComplete:
            return .trainingComplete
        case .trainingFailed:
            return .trainingFailed
        case .listening:
            return .listening
        case .panicDetected:
            return .panicDetected
        case .paused:
            return .paused
        case .audioError:
            return .audioError
        case .microphonePermissionNeeded:
            return .microphonePermissionNeeded
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        }
    }

    static func isAllowed(
        from current: AppStatus,
        to next: AppStatus,
        options: Options
    ) -> Bool {
        if options.force {
            return true
        }

        if current == next {
            return true
        }

        let from = phase(of: current)
        let to = phase(of: next)

        // Training sample progress updates stay in training.
        if from == .training, to == .training {
            return true
        }

        switch (from, to) {
        case (.starting, .needsTraining),
             (.starting, .listening),
             (.starting, .audioError),
             (.starting, .microphonePermissionNeeded),
             (.starting, .microphonePermissionDenied):
            return true

        case (.starting, .training):
            return options.userInitiated

        case (.needsTraining, .training):
            return options.userInitiated

        case (.needsTraining, .microphonePermissionNeeded),
             (.needsTraining, .microphonePermissionDenied):
            return true

        case (.training, .listening):
            return options.postTrainingExit

        case (.training, .starting):
            return options.postTrainingExit

        case (.training, .trainingFailed),
             (.training, .trainingComplete):
            return true

        case (.trainingComplete, .listening),
             (.trainingComplete, .starting):
            return options.postTrainingExit || options.userConfirmedTrainingCompletion

        case (.trainingFailed, .training):
            return options.userInitiated

        case (.trainingFailed, .starting),
             (.trainingFailed, .listening):
            return true

        case (.listening, .paused),
             (.listening, .audioError),
             (.listening, .panicDetected):
            return true

        case (.panicDetected, .listening):
            return true

        case (.paused, .starting),
             (.paused, .listening):
            return true

        case (.audioError, .starting):
            return true

        case (.audioError, .training),
             (.audioError, .needsTraining):
            return options.userInitiated

        case (.microphonePermissionNeeded, .needsTraining),
             (.microphonePermissionNeeded, .training):
            return options.userInitiated

        case (.microphonePermissionNeeded, .microphonePermissionDenied),
             (.microphonePermissionNeeded, .starting):
            return true

        case (.microphonePermissionDenied, .microphonePermissionNeeded):
            return options.userInitiated

        default:
            return false
        }
    }

    static func logTransition(from: AppStatus, to: AppStatus, reason: String) {
        print("[StateMachine] \(describe(from)) -> \(describe(to)) | reason: \(reason)")
    }

    static func logBlocked(from: AppStatus, to: AppStatus, reason: String) {
        print("[StateMachine] BLOCKED \(describe(from)) -> \(describe(to)) | reason: \(reason)")
    }

    static func logTimeout(_ message: String, reason: String) {
        print("[StateMachine] \(message) | reason: \(reason)")
    }

    private static func describe(_ status: AppStatus) -> String {
        switch status {
        case .starting:
            return "starting"
        case .needsTraining:
            return "needsTraining"
        case .training(let sample, let total):
            return "training(\(sample)/\(total))"
        case .trainingComplete:
            return "trainingComplete"
        case .trainingFailed(let message):
            return "trainingFailed(\(message))"
        case .listening:
            return "listening"
        case .panicDetected:
            return "panicDetected"
        case .paused:
            return "paused"
        case .audioError(let message):
            return "audioError(\(message))"
        case .microphonePermissionNeeded:
            return "microphonePermissionNeeded"
        case .microphonePermissionDenied:
            return "microphonePermissionDenied"
        }
    }
}
