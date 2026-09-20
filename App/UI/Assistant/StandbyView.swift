import SwiftUI

/// What the assistant has to say for itself when nobody is talking to it.
///
/// This is the whole argument for the app in one view. An assistant that shows a microphone and
/// waits is a feature; one that opens with "you promised Sarah the deck yesterday" is something
/// that has been paying attention. It stays deliberately short — three things and one question at
/// most — because the alternative to a wall of rows is not a longer list, it is asking.
struct AssistantStandby: Equatable {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var title: String
        /// Why it is being raised: "you promised this, yesterday", "due today".
        var reason: String
        var systemImage: String
        var tone: Tone
        /// What to open when it is tapped, when there is something to open.
        var entityID: UUID?
    }

    struct Question: Identifiable, Equatable {
        let id: UUID
        var sentence: String
        var explanation: String
    }

    /// The assistant's own sentence about the day: "One thing is late."
    var headline: String?
    var items: [Item] = []
    /// How many more there are beyond the three shown.
    var moreCount = 0
    /// One thing it worked out and wants confirmed. Never more than one at a time.
    var question: Question?

    var isEmpty: Bool { headline == nil && items.isEmpty && question == nil }

    static let empty = AssistantStandby()
}

struct StandbyView: View {
    let standby: AssistantStandby
    var onOpen: (UUID) -> Void = { _ in }
    var onConfirm: (UUID) -> Void = { _ in }
    var onReject: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(spacing: Spacing.l) {
            if let headline = standby.headline {
                Text(headline)
                    .textStyle(.title3, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !standby.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(standby.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline().padding(.leading, 46) }
                        row(item)
                    }
                }
                .background(Palette.surface, in: .rect(cornerRadius: Radius.large, style: .continuous))
            }

            if standby.moreCount > 0 {
                // Deliberately not a link. The way to see the rest of your world is to ask for the
                // part of it you care about, which is the whole point of the thing.
                Text("\(standby.moreCount) more — ask me what's next.")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkTertiary)
            }

            if let question = standby.question {
                questionCard(question)
            }
        }
    }

    private func row(_ item: AssistantStandby.Item) -> some View {
        Button {
            if let entityID = item.entityID { onOpen(entityID) }
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.tone.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    Text(item.reason)
                        .textStyle(.footnote)
                        .foregroundStyle(item.tone == .danger ? item.tone.textColor : Palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)

                if item.entityID != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item.entityID == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.reason)")
    }

    /// Same surface as the list above it, marked by one glyph. A washed-blue panel would make a
    /// guess look like an alert; this is the assistant checking something, not warning about it.
    private func questionCard(_ question: AssistantStandby.Question) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.sky)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.sentence)
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.explanation)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Spacing.s) {
                    Button("Yes") { onConfirm(question.id) }
                        .buttonStyle(.capsule(.prominent, size: .small, fullWidth: false))
                    Button("No") { onReject(question.id) }
                        .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.large, style: .continuous))
    }
}

#Preview("Standby") {
    StandbyView(standby: AssistantStandby(
        headline: "One thing is late.",
        items: [
            .init(id: UUID(), title: "Send Sarah the deck", reason: "you promised this, yesterday",
                  systemImage: "hand.raised.fill", tone: .danger, entityID: UUID()),
            .init(id: UUID(), title: "Write the release note", reason: "due today",
                  systemImage: "circle.badge.checkmark", tone: .clay, entityID: UUID()),
            .init(id: UUID(), title: "Standup", reason: "starts at 9:30", systemImage: "calendar",
                  tone: .neutral, entityID: UUID()),
        ],
        moreCount: 2,
        question: .init(id: UUID(), sentence: "Sarah Chen is responsible for design lead?",
                        explanation: "I worked it out from what I've seen.")
    ))
    .padding()
    .background(Palette.canvas)
}

/// What the person can do with what the assistant is holding up.
struct StandbyIntents {
    var open: @MainActor (_ entityID: UUID) -> Void = { _ in }
    var confirm: @MainActor (_ questionID: UUID) -> Void = { _ in }
    var reject: @MainActor (_ questionID: UUID) -> Void = { _ in }

    static let inert = StandbyIntents()
}
