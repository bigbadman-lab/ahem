import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var appState: AppState
    let coordinator: AppCoordinator

    @Environment(\.dismissWindow) private var dismissWindow

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appState = ObservedObject(wrappedValue: coordinator.appState)
    }

    var body: some View {
        Group {
            switch appState.onboardingPhase {
            case .welcome, .idle:
                OnboardingWelcomeView {
                    Task {
                        await coordinator.handleOnboardingGetStarted()
                    }
                }

            case .permissionDenied:
                OnboardingPermissionDeniedView(
                    onOpenSystemSettings: coordinator.openMicrophoneSystemSettings,
                    onQuit: coordinator.quit
                )

            case .training:
                TrainingView(coordinator: coordinator, handlesWindowLifecycle: false)

            case .completion:
                OnboardingCompletionView {
                    coordinator.finishOnboarding()
                    dismissWindow(id: OnboardingWindowID.value)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AhemLayout.windowContentPadding)
        .frame(
            minWidth: AhemLayout.windowMinWidth,
            minHeight: AhemLayout.trainingWindowMinHeight
        )
        .keepAhemWindowInFront(titleHint: "Welcome to Ahem")
        .onDisappear {
            coordinator.handleOnboardingWindowClosed()
        }
    }
}

enum OnboardingWindowID {
    static let value = "onboarding"
}

private struct OnboardingWelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            AhemAppIconView()
                .padding(.bottom, 8)

            Text("Ahem")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("for awkward moments.")
                .font(.title3)
                .italic()
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Hide your browser instantly using your own cough.")
                Text("Everything stays on your Mac.")
                Text("No recordings are stored.")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)

            Spacer()

            Button("Get Started", action: onGetStarted)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }
}

private struct OnboardingPermissionDeniedView: View {
    let onOpenSystemSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Microphone Access Required")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("Ahem needs microphone access to learn your unique cough and listen for it locally.\n\nYour audio never leaves your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Open System Settings", action: onOpenSystemSettings)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

            Button("Quit Ahem", action: onQuit)
                .controlSize(.large)
        }
    }
}

private struct OnboardingCompletionView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            AhemAppIconView()
                .padding(.bottom, 8)

            Text("You're all set.")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("Your Mac now knows your cough.\n\nAhem is now listening quietly from your menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}
