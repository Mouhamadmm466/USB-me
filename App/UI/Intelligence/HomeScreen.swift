import Intelligence
import SwiftUI

/// Home: what today actually asks of you.
///
/// Ordered by what it would cost to miss: things already late, then today, then the questions the
/// system has been holding, then what is coming, then the projects those things belong to. Nothing
/// here is a feed to scroll — when there is nothing to show, the screen says so plainly instead of
/// filling space.
struct HomeScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                greeting

                if !state.overdue.isEmpty {
                    ItemSection(title: "Late", tone: .danger, items: state.overdue, open: intents.openEntity)
                }
                if !state.today.isEmpty {
                    ItemSection(title: "Today", tone: .jade, items: state.today, open: intents.openEntity)
                }
                if !state.questions.isEmpty {
                    QuestionSection(questions: state.questions, intents: intents)
                }
                if !state.soon.isEmpty {
                    ItemSection(title: "This week", tone: .neutral, items: state.soon, open: intents.openEntity)
                }
                if !state.projects.isEmpty {
                    projectStrip
                }
                if state.isLoaded, !state.hasAnything {
                    EmptyStateCard(
                        systemImage: "sparkles",
                        title: "Nothing yet",
                        message: "Tell me about your work — a project, a deadline, who's involved — and it will show up here.",
                        actionTitle: "Talk to it",
                        action: intents.ask
                    )
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: Measure.content, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: state)
        }
        .background(Palette.canvas)
        .refreshable { await intents.refresh() }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(Self.dayName())
                .textStyle(.footnote, weight: .semibold)
                .foregroundStyle(Palette.inkSecondary)
                .textCase(.uppercase)
            Text(headline)
                .textStyle(.largeTitle)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// One honest sentence about the day, built from counts — never a generated pleasantry.
    private var headline: String {
        if !state.overdue.isEmpty {
            return state.overdue.count == 1 ? "One thing is late." : "\(state.overdue.count) things are late."
        }
        if !state.today.isEmpty {
            return state.today.count == 1 ? "One thing today." : "\(state.today.count) things today."
        }
        if !state.questions.isEmpty { return "A couple of things to check." }
        if !state.soon.isEmpty { return "Nothing today. Something this week." }
        return state.isLoaded ? "Nothing on today." : "Catching up…"
    }

    private var projectStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Projects", tone: .neutral)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                    ForEach(state.projects.prefix(6)) { project in
                        Button { intents.openEntity(project.id) } label: {
                            ProjectTile(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.screenMargin)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -Spacing.screenMargin)
        }
    }

    private static func dayName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Sections

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
            IconTile(systemImage: systemImage, tone: .jade, size: 44)
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

#Preview("Home") {
    HomeScreen(state: .preview, intents: .inert)
}

extension IntelligenceViewState {
    /// Sample state for previews and the design gallery.
    static var preview: IntelligenceViewState {
        var state = IntelligenceViewState()
        state.isLoaded = true
        state.overdue = [
            Item(id: UUID(), title: "Send Sarah the deck", meta: "due yesterday", kind: .commitment,
                 tone: .danger, systemImage: EntityKind.commitment.systemImage, isOverdue: true),
        ]
        state.today = [
            Item(id: UUID(), title: "Standup", meta: "9:30 AM", kind: .event, tone: .jade,
                 systemImage: EntityKind.event.systemImage),
            Item(id: UUID(), title: "Write the release note", meta: "Beta launch", kind: .task, tone: .jade,
                 systemImage: EntityKind.task.systemImage),
        ]
        state.soon = [
            Item(id: UUID(), title: "Ship the beta", meta: "due Friday", kind: .goal, tone: .neutral,
                 systemImage: EntityKind.goal.systemImage),
        ]
        state.questions = [
            Question(id: UUID(), sentence: "Sarah is responsible for design?",
                     explanation: "I worked it out from what I've seen. You haven't confirmed it.",
                     replaces: "Sarah is responsible for research"),
        ]
        state.projects = [
            ProjectRow(id: UUID(), title: "Beta launch", status: "active", tone: .jade, openWork: 4,
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
