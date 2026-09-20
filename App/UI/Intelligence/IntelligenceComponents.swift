import Intelligence
import SwiftUI

/// The pieces the intelligence screens are built from: rows, cards, tiles and the sample state the
/// previews and the design gallery draw. They outlived the Home tab they were written for — the
/// main screen's standby list and the Settings screens use the same vocabulary.
private struct SectionHeader: View {
    let title: String
    var tone: Tone = .neutral
    var count: Int?

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(title)
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
            if let count {
                Text("\(count)")
                    .textStyle(.footnote, weight: .semibold)
                    .foregroundStyle(tone.textColor)
            }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ItemSection: View {
    let title: String
    let tone: Tone
    let items: [IntelligenceViewState.Item]
    let open: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title, tone: tone, count: items.count)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline().padding(.leading, 56) }
                    Button { open(item.id) } label: { ItemRow(item: item) }
                        .buttonStyle(RowButtonStyle())
                }
            }
            .background(Palette.surface, in: .rounded(Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }
}

struct ItemRow: View {
    let item: IntelligenceViewState.Item

    var body: some View {
        HStack(spacing: Spacing.m) {
            IconTile(systemImage: item.systemImage, tone: item.tone, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .textStyle(.body, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let meta = item.meta {
                    Text(meta)
                        .textStyle(.footnote)
                        .foregroundStyle(item.isOverdue ? Palette.danger : Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .textStyle(.footnote, weight: .semibold)
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// What needs the user, in the order it needs them — each row carrying the reason it is here.
private struct AttentionSection: View {
    let rows: [IntelligenceViewState.AttentionRow]
    let open: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Needs you", tone: rows.first?.tone ?? .neutral, count: rows.count)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Hairline().padding(.leading, 56) }
                    Button { if let id = row.entityID { open(id) } } label: {
                        HStack(spacing: Spacing.m) {
                            IconTile(systemImage: row.systemImage, tone: row.tone, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .textStyle(.body, weight: .medium)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(row.reason)
                                    .textStyle(.footnote)
                                    .foregroundStyle(row.tone == .danger ? Palette.danger : Palette.inkSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: Spacing.s)
                            if row.entityID != nil {
                                Image(systemName: "chevron.right")
                                    .textStyle(.footnote, weight: .semibold)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                    .disabled(row.entityID == nil)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(Palette.surface, in: .rounded(Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
    }
}

private struct QuestionSection: View {
    let questions: [IntelligenceViewState.Question]
    let intents: IntelligenceIntents

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Check with you", tone: .sky, count: questions.count)
            ForEach(questions) { question in
                QuestionCard(question: question, intents: intents)
            }
        }
    }
}

struct QuestionCard: View {
    let question: IntelligenceViewState.Question
    let intents: IntelligenceIntents

    var body: some View {
        Card(tone: .sky, padding: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    IconTile(systemImage: "questionmark", tone: .sky, size: 32)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(question.sentence)
                            .textStyle(.body, weight: .medium)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(question.explanation)
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                        if let replaces = question.replaces {
                            Text("Replaces: \(replaces)")
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.amberText)
                                .padding(.top, Spacing.xxs)
                        }
                    }
                }
                HStack(spacing: Spacing.s) {
                    Button("Yes") { intents.confirm(question.id) }
                        .buttonStyle(.capsule(.prominent, size: .small, fullWidth: false))
                    Button("No") { intents.reject(question.id) }
                        .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ProjectTile: View {
    let project: IntelligenceViewState.ProjectRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            IconTile(systemImage: "folder", tone: project.tone, size: 30)
            Text(project.title)
                .textStyle(.callout, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(project.nextDue.map { "Next: \($0)" } ?? "\(project.openWork) open")
                .textStyle(.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
        }
        .padding(Spacing.l)
        .frame(width: 168, height: 148, alignment: .leading)
        .background(Palette.surface, in: .rounded(Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Palette.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: Spacing.m) {
            IconTile(systemImage: systemImage, tone: .clay, size: 44)
            Text(title)
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
            Text(message)
                .textStyle(.callout)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxxl)
        .padding(.horizontal, Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// A row that presses like a list row: a quiet fill, no scaling.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.fill : .clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension IntelligenceViewState {
    /// Sample state for previews and the design gallery.
    static var preview: IntelligenceViewState {
        var state = IntelligenceViewState()
        state.isLoaded = true
        state.attention = [
            AttentionRow(id: UUID(), title: "Send Sarah the deck", reason: "you promised this, yesterday",
                         kind: .promise, tone: .danger, systemImage: AttentionKind.promise.systemImage,
                         entityID: UUID()),
            AttentionRow(id: UUID(), title: "Write the release note", reason: "due today",
                         kind: .today, tone: .clay, systemImage: AttentionKind.today.systemImage,
                         entityID: UUID()),
            AttentionRow(id: UUID(), title: "Ship the beta", reason: "due Friday, nothing started",
                         kind: .unstarted, tone: .amber, systemImage: AttentionKind.unstarted.systemImage,
                         entityID: UUID()),
        ]
        state.questions = [
            Question(id: UUID(), sentence: "Sarah is responsible for design?",
                     explanation: "I worked it out from what I've seen. You haven't confirmed it.",
                     replaces: "Sarah is responsible for research"),
        ]
        state.projects = [
            ProjectRow(id: UUID(), title: "Beta launch", status: "active", tone: .clay, openWork: 4,
                       commitments: 1, people: ["Sarah", "Abdou"], nextDue: "Friday", nextDueTitle: "Ship the beta"),
            ProjectRow(id: UUID(), title: "Thesis", status: "paused", tone: .neutral, openWork: 2,
                       commitments: 0, people: ["Prof. Diallo"], nextDue: nil, nextDueTitle: nil),
        ]
        state.activity = [
            ActivityRow(id: UUID(), kind: .learned, headline: "Abdou works on Beta launch",
                        detail: "You told me today.", timeText: "just now", canUndo: true, isUndone: false,
                        entityID: nil),
        ]
        state.memory = Memory(
            kinds: [.init(kind: .project, count: 2), .init(kind: .person, count: 5), .init(kind: .task, count: 12)],
            facts: 48, questions: 1, inferred: 3, sizeText: "96 KB"
        )
        return state
    }
}
