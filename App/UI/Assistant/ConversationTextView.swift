import Core
import SwiftUI

/// What the assistant says, centred under the orb.
///
/// What the *person* said is deliberately not here — neither the live partial transcript nor the
/// settled utterance. Watching your own words appear a beat behind you is the thing that makes
/// dictation feel like dictation: it invites you to read and correct instead of talk. The orb
/// already says it is listening, and the reply says it was understood. Both are still announced to
/// VoiceOver, where the transcript is the only way to know the microphone heard anything.
struct ConversationTextView: View {
    let state: AgentState
    let partialTranscript: String?
    let lastUserUtterance: String?
    let assistantText: String?
    /// A card is showing: text steps down a size to leave it room.
    var isCompact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        VStack(spacing: isCompact ? Spacing.s : Spacing.m) {
            if voiceOverEnabled, let heard = partialTranscript.nonEmpty ?? lastUserUtterance.nonEmpty {
                Text(heard)
                    .textStyle(isCompact ? .body : .callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityLabel("You said: \(heard)")
                    .accessibilityAddTraits(.updatesFrequently)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: assistantText)
    }
}

extension Optional where Wrapped == String {
    /// The string, or nil when it is nil or only whitespace.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
