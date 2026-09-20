import Agent
import Intelligence
import SwiftUI

/// A job, before and while it runs.
///
/// Before: every step it intends to take, so saying yes is saying yes to exactly these. While:
/// the same list, with the live step marked — the card never becomes a spinner, because the point
/// is that the user can see what is being done on their behalf.
struct JobCardView: View {
    let card: JobCard
    let onApprove: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onOpenArtifact: @MainActor (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card(tone: tone, padding: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                header
                steps
                if let message = card.message, !message.isEmpty, card.state != .running {
                    Text(message)
                        .textStyle(.footnote)
                        .foregroundStyle(card.state == .failed ? Palette.danger : Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Job: \(card.title)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            IconTile(systemImage: icon, tone: tone, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .textStyle(.headline)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(card.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    stepMark(step, index: index)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.summary)
                            .textStyle(.subheadline)
                            .foregroundStyle(step.state == .completed ? Palette.inkSecondary : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if step.needsConfirmation {
                            Text("asks you first")
                                .textStyle(.caption)
                                .foregroundStyle(Palette.amberText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Spacing.xs)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: card.steps.map(\.state))
    }

    @ViewBuilder
    private func stepMark(_ step: JobCard.Step, index: Int) -> some View {
        switch step.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.clay)
                .imageScale(.small)
        case .running:
            ProgressView().controlSize(.mini)
        case .failed, .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Palette.danger)
                .imageScale(.small)
        case .blocked:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Palette.amber)
                .imageScale(.small)
        case .proposed, .approved:
            Text("\(index + 1)")
                .textStyle(.caption, weight: .semibold)
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch card.state {
        case .proposed:
            HStack(spacing: Spacing.s) {
                Button("Go ahead", action: onApprove)
                    .buttonStyle(.capsule(.prominent, size: .medium, fullWidth: false))
                Button("Not now", action: onCancel)
                    .buttonStyle(.capsule(.secondary, size: .medium, fullWidth: false))
                Spacer(minLength: 0)
            }
        case .running, .approved:
            HStack(spacing: Spacing.s) {
                Button("Stop", action: onCancel)
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                Spacer(minLength: 0)
            }
        case .completed:
            if let artifactID = card.artifactID {
                Button { onOpenArtifact(artifactID) } label: {
                    Label("Read it", systemImage: "doc.text")
                }
                .buttonStyle(.capsule(.prominent, size: .medium, fullWidth: false))
            }
        case .blocked where card.blocker?.isWaitingOnUser == true:
            EmptyView()
        case .blocked, .failed, .cancelled:
            Button("Try again", action: onApprove)
                .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
        }
    }

    private var icon: String {
        switch card.state {
        case .completed: "checkmark.seal"
        case .failed: "exclamationmark.triangle"
        case .blocked: "pause.circle"
        case .cancelled: "xmark.circle"
        default: "list.bullet.rectangle"
        }
    }

    private var tone: Tone {
        switch card.state {
        case .proposed: .sky
        case .running, .approved: .clay
        case .completed: .clay
        case .failed: .danger
        case .blocked: .amber
        case .cancelled: .neutral
        }
    }

    private var subtitle: String {
        switch card.state {
        case .proposed: card.steps.count == 1 ? "1 step, nothing done yet" : "\(card.steps.count) steps, nothing done yet"
        case .running, .approved: card.message ?? "Working…"
        case .completed: "Done"
        case .blocked: card.blocker?.isWaitingOnUser == true ? "Waiting on you" : "Paused"
        case .failed: "Didn't finish"
        case .cancelled: "Stopped"
        }
    }
}

#Preview("Job — proposed") {
    JobCardView(
        card: JobCard(
            id: UUID(), title: "Midterm study plan", request: "make me a study plan",
            steps: [
                .init(id: UUID(), summary: "Find what the midterm covers", state: .proposed, needsConfirmation: false),
                .init(id: UUID(), summary: "Write the plan", state: .proposed, needsConfirmation: false),
            ],
            state: .proposed
        ),
        onApprove: {}, onCancel: {}, onOpenArtifact: { _ in }
    )
    .padding()
}

#Preview("Job — running") {
    JobCardView(
        card: JobCard(
            id: UUID(), title: "Beta review prep", request: "prep me for the review",
            steps: [
                .init(id: UUID(), summary: "Check the time and who's coming", state: .completed, needsConfirmation: false),
                .init(id: UUID(), summary: "Pull what's open on the beta", state: .running, needsConfirmation: false),
                .init(id: UUID(), summary: "Text Sarah the summary", state: .proposed, needsConfirmation: true),
            ],
            state: .running, message: "Running: Pull what's open on the beta (step 2 of 3)"
        ),
        onApprove: {}, onCancel: {}, onOpenArtifact: { _ in }
    )
    .padding()
}
