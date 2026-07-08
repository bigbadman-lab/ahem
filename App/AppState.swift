import Combine
import Foundation

enum OnboardingPhase: Equatable {
    case idle
    case welcome
    case permissionDenied
    case training
    case completion
}

/// TEMP-friendly launch presentation request for setup windows.
enum SetupPresentationRequest: Equatable {
    case onboarding
    case training
}

enum TrainingUIPhase: Equatable {
    case idle
    case welcome
    case countdown(sample: Int, total: Int, secondsRemaining: Int)
    case listening(sample: Int, total: Int)
    case preparingNextSample(completedSample: Int, total: Int)
    case succeeded
    case succeededListeningActive
    case failed(String)
}

enum AppStatus: Equatable {
    case starting
    case microphonePermissionNeeded
    case listening
    case paused
    case microphonePermissionDenied
    case audioError(String)
    case needsTraining
    case training(sample: Int, total: Int)
    case trainingComplete
    case trainingFailed(String)
    case panicDetected
}

enum MenuBarPrimaryAction: Equatable {
    case trainPanicCough
    case trainAgain
    case resumeListening
    case grantMicrophonePermission
}

struct MenuBarPresentation: Equatable {
    let statusLine: String
    let primaryAction: MenuBarPrimaryAction?
    let primaryActionTitle: String
    let showsListeningToggle: Bool
    let listeningToggleTitle: String
    let showsResumeToggle: Bool
    let showsLastTrained: Bool
}

extension AppStatus {
    var isTrainingSessionActive: Bool {
        switch self {
        case .training, .trainingComplete:
            return true
        default:
            return false
        }
    }

    func menuPresentation(
        hasFingerprint: Bool,
        isTrainingSessionActive: Bool
    ) -> MenuBarPresentation {
        if isTrainingSessionActive {
            return MenuBarPresentation(
                statusLine: "🟡 Training",
                primaryAction: nil,
                primaryActionTitle: "",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )
        }

        switch self {
        case .listening, .panicDetected:
            return MenuBarPresentation(
                statusLine: "🟢 Ready",
                primaryAction: hasFingerprint ? .trainAgain : .trainPanicCough,
                primaryActionTitle: hasFingerprint ? "Train Again…" : "Train your cough…",
                showsListeningToggle: true,
                listeningToggleTitle: "Pause Listening",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )

        case .paused:
            return MenuBarPresentation(
                statusLine: "⏸ Paused",
                primaryAction: hasFingerprint ? .trainAgain : .trainPanicCough,
                primaryActionTitle: hasFingerprint ? "Train Again…" : "Train your cough…",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: true,
                showsLastTrained: hasFingerprint
            )

        case .needsTraining, .starting:
            return MenuBarPresentation(
                statusLine: "⚪ Training Needed",
                primaryAction: .trainPanicCough,
                primaryActionTitle: "Train your cough…",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: false,
                showsLastTrained: false
            )

        case .microphonePermissionNeeded, .microphonePermissionDenied:
            return MenuBarPresentation(
                statusLine: "⚠︎ Microphone Permission Required",
                primaryAction: .grantMicrophonePermission,
                primaryActionTitle: "Grant Microphone Permission…",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )

        case .audioError:
            return MenuBarPresentation(
                statusLine: "⚠︎ Audio Error",
                primaryAction: hasFingerprint ? .trainAgain : .trainPanicCough,
                primaryActionTitle: hasFingerprint ? "Train Again…" : "Train your cough…",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )

        case .training, .trainingComplete:
            return MenuBarPresentation(
                statusLine: "🟡 Training",
                primaryAction: nil,
                primaryActionTitle: "",
                showsListeningToggle: false,
                listeningToggleTitle: "",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )

        case .trainingFailed:
            return MenuBarPresentation(
                statusLine: hasFingerprint ? "🟢 Ready" : "⚪ Training Needed",
                primaryAction: hasFingerprint ? .trainAgain : .trainPanicCough,
                primaryActionTitle: hasFingerprint ? "Train Again…" : "Train your cough…",
                showsListeningToggle: hasFingerprint,
                listeningToggleTitle: "Pause Listening",
                showsResumeToggle: false,
                showsLastTrained: hasFingerprint
            )
        }
    }
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    /// User-facing menu status. May lag/`hold` behind `status` during resume retries to avoid flicker.
    @Published var menuDisplayStatus: AppStatus = .starting
    @Published var onboardingPhase: OnboardingPhase = .idle
    @Published var trainingUIPhase: TrainingUIPhase = .idle
    @Published var trainingInputLevel: Double = 0
    @Published var lastTrainedAt: Date?
    // TEMP: Release diagnostics — remove when Debug vs Release comparison is complete.
    @Published var diagnosticsCopyConfirmation: String?
    /// One-shot launch request to open setup UI; cleared after presentation.
    @Published var setupPresentationRequest: SetupPresentationRequest?
}
