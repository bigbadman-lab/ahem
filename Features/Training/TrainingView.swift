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
            TrainingSucceededView(onDone: confirmCompletion)

        case .succeededListeningActive:
            TrainingSucceededView(onDone: confirmCompletion)

        case .failed(let message):
            TrainingFailedView(message: message, onTryAgain: startTraining)
        }
    }

    private func startTraining() {
        coordinator.startTraining()
    }

    private func confirmCompletion() {
        coordinator.confirmTrainingCompleteAndStartListening()
        dismissWindow(id: TrainingWindowID.value)
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

    @State private var displayLevel: Double = 0
    @State private var speakBurst: Double = 0
    @State private var idleBreathing = false

    private let speakingThreshold = 0.10

    private var outerRingScale: CGFloat {
        let base: CGFloat = idleBreathing ? 1.03 : 0.98
        let reactive = 1.0 + CGFloat(displayLevel) * 0.62
        let burst = 1.0 + CGFloat(speakBurst) * 0.18
        return base * reactive * burst
    }

    private var midRingScale: CGFloat {
        let base: CGFloat = idleBreathing ? 1.02 : 0.99
        return base * (1.0 + CGFloat(displayLevel) * 0.42)
    }

    private var coreScale: CGFloat {
        1.0 + CGFloat(displayLevel) * 0.75 + CGFloat(speakBurst) * 0.35
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
                    .stroke(
                        Color.accentColor.opacity(0.12 + displayLevel * 0.28),
                        lineWidth: 1.5
                    )
                    .frame(width: 132, height: 132)
                    .scaleEffect(outerRingScale)
                    .blur(radius: CGFloat(displayLevel) * 3.5)

                Circle()
                    .stroke(
                        Color.accentColor.opacity(0.22 + displayLevel * 0.45),
                        lineWidth: 2.5
                    )
                    .frame(width: 100, height: 100)
                    .scaleEffect(midRingScale)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(0.18 + displayLevel * 0.55),
                                Color.accentColor.opacity(0.04 + displayLevel * 0.12),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: 52
                        )
                    )
                    .frame(width: 88, height: 88)
                    .scaleEffect(1.0 + CGFloat(displayLevel) * 0.22)

                Circle()
                    .fill(Color.accentColor.opacity(0.35 + displayLevel * 0.5))
                    .frame(width: 28, height: 28)
                    .shadow(
                        color: Color.accentColor.opacity(0.25 + displayLevel * 0.45),
                        radius: 8 + displayLevel * 18
                    )
                    .scaleEffect(coreScale)
            }
            .frame(width: 150, height: 150)
            .animation(.easeOut(duration: 0.1), value: displayLevel)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: speakBurst)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    idleBreathing = true
                }
            }
            .onDisappear {
                idleBreathing = false
                displayLevel = 0
                speakBurst = 0
            }
            .onChange(of: inputLevel) { _, newValue in
                updateDisplayLevel(newValue)
            }

            Spacer()
        }
    }

    private func updateDisplayLevel(_ raw: Double) {
        let clamped = min(1, max(0, raw))
        let wasSpeaking = displayLevel >= speakingThreshold
        let attack = 0.62
        let release = 0.22
        let alpha = clamped > displayLevel ? attack : release
        let nextLevel = displayLevel * (1 - alpha) + clamped * alpha
        displayLevel = nextLevel

        if nextLevel >= speakingThreshold && !wasSpeaking {
            speakBurst = 1.0
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeOut(duration: 0.35)) {
                    speakBurst = 0
                }
            }
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
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("✓ Training Complete")
                .font(.title)
                .fontWeight(.semibold)

            AhemAppIconView()
                .padding(.vertical, 8)

            Text("Your Mac now knows your cough.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Start Listening", action: onDone)
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
