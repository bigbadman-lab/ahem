import AppKit
import SwiftUI

struct TrainingView: View {
    @ObservedObject private var appState: AppState
    let coordinator: AppCoordinator
    let handlesWindowLifecycle: Bool

    @Environment(\.dismissWindow) private var dismissWindow

    init(coordinator: AppCoordinator, handlesWindowLifecycle: Bool = true) {
        self.coordinator = coordinator
        self.handlesWindowLifecycle = handlesWindowLifecycle
        _appState = ObservedObject(wrappedValue: coordinator.appState)
    }

    var body: some View {
        VStack(spacing: AhemLayout.windowSectionSpacing) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(handlesWindowLifecycle ? AhemLayout.windowContentPadding : 0)
        .frame(
            minWidth: AhemLayout.windowMinWidth,
            minHeight: AhemLayout.trainingWindowMinHeight
        )
        .onAppear {
            guard handlesWindowLifecycle else { return }
            AhemWindowActivation.bringAppWindowsForward(preferredTitleHint: "Train your cough")
        }
        .onDisappear {
            guard handlesWindowLifecycle else { return }
            coordinator.handleTrainingWindowClosed()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.trainingUIPhase {
        case .idle:
            TrainingWelcomeView(onStart: startTraining)

        case .welcome:
            TrainingWelcomeView(onStart: startTraining)

        case .countdown(let sample, let total, let secondsRemaining):
            TrainingCountdownView(sample: sample, total: total, secondsRemaining: secondsRemaining)

        case .listening(let sample, let total):
            TrainingListeningView(
                sample: sample,
                total: total,
                inputLevel: appState.trainingInputLevel
            )

        case .preparingNextSample(let completedSample, let total):
            TrainingBetweenSamplesView(completedSample: completedSample, total: total)

        case .succeeded:
            TrainingSucceededView(
                listeningIsActive: false,
                onDone: dismiss
            )

        case .succeededListeningActive:
            TrainingSucceededView(
                listeningIsActive: true,
                onDone: dismiss
            )

        case .failed(let message):
            TrainingFailedView(message: message, onTryAgain: startTraining)
        }
    }

    private func startTraining() {
        coordinator.startTraining()
    }

    private func dismiss() {
        dismissWindow(id: TrainingWindowID.value)
    }
}

enum TrainingWindowID {
    static let value = "training"
}

private struct TrainingWelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            AhemAppIconView()
                .padding(.bottom, 8)

            Text("Train your cough")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("Teach your Mac what your unique cough sounds like.\nEverything stays on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Start Training", action: onStart)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}

private struct TrainingCountdownView: View {
    let sample: Int
    let total: Int
    let secondsRemaining: Int

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("\(sample) of \(total)")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Get ready…")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("\(secondsRemaining)")
                .font(.system(size: 72, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: secondsRemaining)

            Spacer()
        }
    }
}

private struct TrainingListeningView: View {
    let sample: Int
    let total: Int
    let inputLevel: Double

    @State private var isPulsing = false

    private var displayLevel: Double {
        min(1, max(0, inputLevel))
    }

    private var indicatorScale: CGFloat {
        let idlePulse: CGFloat = isPulsing ? 1.04 : 0.96
        let reactiveScale = 1.0 + CGFloat(displayLevel) * 0.28
        return idlePulse * reactiveScale
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("\(sample) of \(total)")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Give your best")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("AHEM!")
                .font(.system(size: 48, weight: .semibold, design: .rounded))

            Text("Listening...")
                .font(.title3)
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.08 + displayLevel * 0.2), lineWidth: 1)
                    .frame(width: 80, height: 80)
                    .scaleEffect(1.0 + CGFloat(displayLevel) * 0.45)
                    .animation(.easeOut(duration: 0.12), value: displayLevel)

                Circle()
                    .strokeBorder(
                        .secondary.opacity(0.25 + displayLevel * 0.45),
                        lineWidth: 2 + displayLevel * 2
                    )
                    .background(
                        Circle()
                            .fill(.secondary.opacity(0.05 + displayLevel * 0.2))
                    )
                    .frame(width: 56, height: 56)
                    .scaleEffect(indicatorScale)
                    .animation(.easeOut(duration: 0.1), value: displayLevel)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            }
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }

            Spacer()
        }
    }
}

private struct TrainingBetweenSamplesView: View {
    let completedSample: Int
    let total: Int

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("✓ Great!")
                .font(.title)
                .fontWeight(.semibold)

            if completedSample < total {
                Text(betweenRecordingsMessage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var betweenRecordingsMessage: String {
        switch completedSample {
        case 1:
            return "Let's do that again..."
        case 2:
            return "One more..."
        default:
            return "Let's do that again..."
        }
    }
}

private struct TrainingSucceededView: View {
    let listeningIsActive: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("✓ Training Complete")
                .font(.title)
                .fontWeight(.semibold)

            AhemAppIconView()
                .padding(.vertical, 8)

            Text(listeningIsActive
                ? "Listening is now active."
                : "Your Mac now knows your cough.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: listeningIsActive)

            Spacer()

            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}

private struct TrainingFailedView: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Training Failed")
                .font(.title)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Try Again", action: onTryAgain)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}
