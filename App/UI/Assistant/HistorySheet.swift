import Core
import SwiftUI

/// The recent conversation as a transcript. Your words are ink; the assistant's sit on a
/// quiet surface.
///
/// Presented from Settings, next to the switch that decides whether history is kept at all — which
/// is the only place it is reachable from. The talking screen has a microphone and a keyboard on
/// it and nothing else; a transcript there invites reading back rather than saying the next thing.
struct HistoryTranscript: View {
    let turns: [ConversationTurn]

    init(turns: [ConversationTurn]) {
        self.turns = turns
        DesignSystemAppearance.install()
    }

    var body: some View {
        Group {
                if turns.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: Spacing.s + 2) {
                            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                                if let stamp = timestamp(before: index) {
                                    Text(stamp)
                                        .textStyle(.caption, weight: .medium)
                                        .foregroundStyle(Palette.inkTertiary)
                                        .padding(.top, index == 0 ? 0 : Spacing.m)
                                        .padding(.bottom, Spacing.xs)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                TurnBubble(turn: turn)
                            }
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.l)
                    }
                    .defaultScrollAnchor(.bottom)
                    .hardTopScrollEdge()
                }
        }
        .background(Palette.canvas)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.inkTertiary)
                .accessibilityHidden(true)
            Text("No conversation yet")
                .textStyle(.headline)
                .foregroundStyle(Palette.ink)
            Text("Tap the microphone and ask for something. It will appear here.")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A time header before the first turn and after gaps of more than ten minutes.
    private func timestamp(before index: Int) -> String? {
        let date = turns[index].timestamp
        if index > 0, date.timeIntervalSince(turns[index - 1].timestamp) < 600 { return nil }
        let day: String
        if Calendar.current.isDateInToday(date) {
            day = "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return "\(day) \(date.formatted(date: .omitted, time: .shortened))"
    }
}

private struct TurnBubble: View {
    let turn: ConversationTurn

    var body: some View {
        let isUser = turn.role == .user
        HStack {
            if isUser { Spacer(minLength: 48) }
            Text(turn.text)
                .textStyle(.body)
                .foregroundStyle(isUser ? Palette.inkInverse : Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Palette.ink : Palette.surface, in: .rounded(Radius.large))
            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Assistant"): \(turn.text)")
    }
}

#Preview("History") {
    Color.clear.sheet(isPresented: .constant(true)) {
        HistorySheet(turns: GallerySamples.turns)
    }
}

private extension View {
    /// On iOS 26 the bar's glass buttons otherwise refract the ink bubbles scrolled beneath them.
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

/// The transcript as a sheet, for the design gallery.
struct HistorySheet: View {
    let turns: [ConversationTurn]

    var body: some View {
        NavigationStack {
            HistoryTranscript(turns: turns)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
