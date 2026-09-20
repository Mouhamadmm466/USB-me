import Intelligence
import SwiftUI

/// One thing in the user's world, and everything the system holds about it.
struct EntityDetailViewState: Equatable, Identifiable {
    struct Fact: Identifiable, Equatable {
        let id: UUID
        var sentence: String
        /// "You told me yesterday." — always present, because an unexplained fact is a liability.
        var explanation: String
        var isGuess: Bool
        var isWaiting: Bool
    }

    let id: UUID
    var title: String
    var kind: EntityKind
    var status: String
    var tone: Tone = .neutral
    /// "due Friday", "part of Beta launch", "design lead".
    var meta: [String] = []
    var facts: [Fact] = []
    var related: [IntelligenceViewState.Item] = []
    var activity: [IntelligenceViewState.ActivityRow] = []
    var isLoading = false
}

struct EntityDetailIntents {
    var confirmFact: @MainActor (_ assertionID: UUID) -> Void = { _ in }
    var forgetFact: @MainActor (_ assertionID: UUID) -> Void = { _ in }
    var openEntity: @MainActor (_ entityID: UUID) -> Void = { _ in }
    var forgetEntity: @MainActor (_ entityID: UUID) -> Void = { _ in }

    static let inert = EntityDetailIntents()
}

struct EntityDetailScreen: View {
    let state: EntityDetailViewState
    let intents: EntityDetailIntents

    @State private var isConfirmingForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header
                if !state.facts.isEmpty { factsSection }
                if !state.related.isEmpty { relatedSection }
                if !state.activity.isEmpty { historySection }
                forgetButton
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: Measure.content, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        // The screen leads with the name in full; repeating it in the bar would just be noise.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget \(state.title)?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { intents.forgetEntity(state.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything I know about it goes too. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                IconTile(systemImage: state.kind.systemImage, tone: state.tone, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .textStyle(.title2)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.kind.displayName.lowercased() + (state.status.isEmpty ? "" : " · \(state.status)"))
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            if !state.meta.isEmpty {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(state.meta, id: \.self) { line in
                        StatusPill(line, tone: .neutral)
                    }
                }
            }
        }
        .padding(.top, Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("What I know")
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(state.facts.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { Hairline().padding(.leading, Spacing.l) }
                    FactRow(fact: fact, intents: intents)
                }
            }
            .background(Palette.surface, in: .rounded(Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Connected")
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(state.related.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline().padding(.leading, 56) }
                    Button { intents.openEntity(item.id) } label: { ItemRow(item: item) }
                        .buttonStyle(RowButtonStyle())
                }
            }
            .background(Palette.surface, in: .rounded(Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("History")
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(state.activity) { row in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Image(systemName: row.kind.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(row.kind.tone.textColor)
                            .frame(width: 18)
                        Text(row.headline)
                            .textStyle(.footnote)
                            .foregroundStyle(row.isUndone ? Palette.inkTertiary : Palette.inkSecondary)
                            .strikethrough(row.isUndone, color: Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.s)
                        Text(row.timeText)
                            .textStyle(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var forgetButton: some View {
        Button(role: .destructive) { isConfirmingForget = true } label: {
            Label("Forget this", systemImage: "trash")
                .textStyle(.body, weight: .medium)
        }
        .buttonStyle(.capsule(.destructive, size: .medium))
    }
}

private struct FactRow: View {
    let fact: EntityDetailViewState.Fact
    let intents: EntityDetailIntents

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(fact.sentence)
                .textStyle(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s) {
                Text(fact.explanation)
                    .textStyle(.footnote)
                    .foregroundStyle(fact.isGuess ? Palette.amberText : Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if fact.isWaiting {
                HStack(spacing: Spacing.s) {
                    Button("Yes") { intents.confirmFact(fact.id) }
                        .buttonStyle(.capsule(.prominent, size: .small, fullWidth: false))
                    Button("No") { intents.forgetFact(fact.id) }
                        .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Forget") { intents.forgetFact(fact.id) }
        .contextMenu {
            Button("Forget this", systemImage: "trash", role: .destructive) { intents.forgetFact(fact.id) }
        }
    }
}

#Preview("Entity") {
    NavigationStack {
        EntityDetailScreen(
            state: EntityDetailViewState(
                id: UUID(), title: "Beta launch", kind: .project, status: "active", tone: .clay,
                meta: ["4 open", "next: Friday"],
                facts: [
                    .init(id: UUID(), sentence: "Beta launch is due Friday",
                          explanation: "You told me yesterday.", isGuess: false, isWaiting: false),
                    .init(id: UUID(), sentence: "Sarah works on Beta launch (design)",
                          explanation: "I worked it out from what I've seen. You haven't confirmed it.",
                          isGuess: true, isWaiting: true),
                ],
                related: IntelligenceViewState.preview.today,
                activity: IntelligenceViewState.preview.activity
            ),
            intents: .inert
        )
    }
}
