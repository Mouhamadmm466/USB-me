import SwiftUI

// MARK: - Private by design

struct PrivacyPage: View {
    let onContinue: @MainActor () -> Void

    var body: some View {
        OnboardingScaffold {
            VStack(spacing: Spacing.xxxl) {
                VStack(spacing: Spacing.xl) {
                    OrbView(mode: .idle)
                        .frame(width: 150, height: 150)
                    OnboardingHeadline(
                        title: "Private by design",
                        message: "Voice Agent hears, understands and answers entirely on this iPhone. What you say is never sent anywhere."
                    )
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionTitle("What it can do")
                    CapabilityGrid()
                }

                VStack(alignment: .leading, spacing: Spacing.l) {
                    SectionTitle("What it never does")
                    PromiseRow(
                        systemImage: "hand.raised.fill",
                        title: "Act without your OK",
                        detail: "Messages, calls and changes wait for you to confirm, by voice or with a tap."
                    )
                    PromiseRow(
                        systemImage: "icloud.slash",
                        title: "Upload your voice",
                        detail: "Speech becomes text on this iPhone and stays here."
                    )
                }
            }
        } actions: {
            Button(action: onContinue) { Text("Continue") }
                .buttonStyle(.prominent)
        }
    }
}

/// Six things the assistant can do, as quiet tiles.
private struct CapabilityGrid: View {
    private let items: [(String, String)] = [
        ("Messages", "message.fill"),
        ("Calls", "phone.fill"),
        ("Calendar", "calendar"),
        ("Reminders", "checklist"),
        ("Files", "folder.fill"),
        ("Apps", "square.grid.2x2.fill"),
    ]

    @ScaledMetric(relativeTo: .subheadline) private var minimumTile: CGFloat = 96

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTile), spacing: Spacing.s + 2)], spacing: Spacing.s + 2) {
            ForEach(items, id: \.0) { title, image in
                VStack(spacing: Spacing.s) {
                    Image(systemName: image)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.jade)
                        .frame(height: 24)
                        .accessibilityHidden(true)
                    Text(title)
                        .textStyle(.subheadline, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .background(Palette.surface, in: .rounded(Radius.large))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textStyle(.title3, weight: .semibold)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Download the models

struct ModelsPage: View {
    let state: ModelDownloadViewState
    let actions: ModelDownloadActions
    let onContinue: @MainActor () -> Void

    var body: some View {
        OnboardingScaffold {
            VStack(spacing: Spacing.xxl) {
                OnboardingHeadline(
                    title: "Download the voice models",
                    message: "\(Formatting.bytes(state.totalBytes)) in all, downloaded once. After that, Voice Agent works without a connection."
                )

                if state.isInProgress || state.isPaused {
                    OverallProgress(state: state)
                }

                ModelDownloadsView(state: state, actions: actions, style: .card)

                ModelDownloadHints(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            primaryAction
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if state.allInstalled {
            Button(action: onContinue) { Text("Continue") }
                .buttonStyle(.prominent)
        } else if state.isInProgress {
            Button(action: actions.pauseAll) { Text("Pause") }
                .buttonStyle(.secondary)
            Text("Downloads pick up where they left off if interrupted.")
                .textStyle(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        } else if state.isPaused {
            Button(action: actions.resumeAll) { Text("Resume") }
                .buttonStyle(.prominent)
        } else if state.hasFailure {
            Button(action: actions.downloadAll) { Text("Try again") }
                .buttonStyle(.prominent)
                .disabled(state.network == .offline)
        } else {
            Button(action: actions.downloadAll) { Text("Download \(Formatting.bytes(state.remainingBytes))") }
                .buttonStyle(.prominent)
                .disabled(state.network == .offline || !state.hasEnoughSpace)
        }
    }
}

/// Overall progress across every pack.
private struct OverallProgress: View {
    let state: ModelDownloadViewState

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.isPaused ? "Paused" : "Downloading")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(Formatting.percent(state.overallFraction))
                    .textStyle(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
            }
            ProgressBar(value: state.overallFraction, tint: state.isPaused ? Palette.mist : Palette.jade, height: 8)
            HStack {
                Text(Formatting.bytes(state.downloadedBytes, of: state.totalBytes))
                Spacer()
                if !state.isPaused,
                   let rate = state.bytesPerSecond,
                   let left = Formatting.timeRemaining(bytes: state.remainingBytes, bytesPerSecond: rate) {
                    Text(left)
                }
            }
            .textStyle(.footnote)
            .monospacedDigit()
            .foregroundStyle(Palette.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.isPaused ? "Download paused" : "Downloading models")
        .accessibilityValue("\(Formatting.percent(state.overallFraction)), \(Formatting.bytes(state.downloadedBytes, of: state.totalBytes))")
    }
}

// MARK: - Ready

struct ReadyPage: View {
    let onStart: @MainActor () -> Void

    var body: some View {
        OnboardingScaffold {
            VStack(spacing: Spacing.xxxl) {
                VStack(spacing: Spacing.xl) {
                    OrbView(mode: .idle)
                        .frame(width: 150, height: 150)
                    OnboardingHeadline(
                        title: "Ready when you are",
                        message: "Tap the microphone and say what you need."
                    )
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionTitle("Try saying")
                    VStack(spacing: Spacing.s) {
                        ExamplePhrase(text: "Text Alex I\u{2019}m running late")
                        ExamplePhrase(text: "What\u{2019}s on my calendar tomorrow?")
                        ExamplePhrase(text: "Remind me to call Mom at 6")
                    }
                }

                PromiseRow(
                    systemImage: "mic.fill",
                    title: "Microphone access comes next",
                    detail: "iOS asks the first time you tap the microphone. Speech is processed on this iPhone and never uploaded."
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button(action: onStart) { Text("Start") }
                .buttonStyle(.prominent)
        }
    }
}

private struct ExamplePhrase: View {
    let text: String

    var body: some View {
        Text("\u{201C}\(text)\u{201D}")
            .textStyle(.callout, weight: .medium)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m + 2)
            .background(Palette.surface, in: .rounded(Radius.large))
    }
}
