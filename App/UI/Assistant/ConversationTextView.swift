import Core
import SwiftUI

/// What was heard and what the assistant says, centred under the orb.
/// The live partial transcript is secondary and cross-fades as recognition revises it;
/// it is replaced by the final utterance once recognition settles.
struct ConversationTextView: View {
    let state: AgentState
    let partialTranscript: String?
    let lastUserUtterance: String?
    let assistantText: String?
    /// A card is showing: text steps down a size to leave it room.
    var isCompact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: isCompact ? Spacing.s : Spacing.m) {
            if let partial = partialTranscript.nonEmpty {
                Text(partial)
                    .textStyle(isCompact ? .body : .title3, weight: .regular)
                    .foregroundStyle(Palette.inkSecondary)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: partial)
                    .accessibilityLabel("You\u{2019}re saying: \(partial)")
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            } else if let utterance = lastUserUtterance.nonEmpty {
                Text("\u{201C}\(utterance)\u{201D}")
                    .textStyle(isCompact ? .subheadline : .callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityLabel("You said: \(utterance)")
                    .transition(.opacity)
            } else if state == .idle, assistantText.nonEmpty == nil {
                Text("Try \u{201C}Text Alex I\u{2019}m running late\u{201D} or \u{201C}What\u{2019}s on tomorrow?\u{201D}")
                    .textStyle(.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .transition(.opacity)
            }

            if let reply = assistantText.nonEmpty {
                Text(reply)
                    .textStyle(isCompact ? .body : .title3, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("Assistant: \(reply)")
                    .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Measure.text)
    }
}

extension Optional where Wrapped == String {
    /// The string, or nil when it is nil or only whitespace.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
