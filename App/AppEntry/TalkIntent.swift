import AppIntents
import SwiftUI

/// What the Action button asks for: the app, open, listening, without a tap.
///
/// The whole point of a local assistant is that the distance between having a thought and saying it
/// is short. A launcher icon, a cold start and a microphone button is three steps; a long press is
/// none. This intent is deliberately the only thing the app exposes to Shortcuts for now — it is the
/// one verb that matters, and a Shortcuts menu full of half-verbs is how apps become confusing.
struct StartTalkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Voice Agent"
    static let description = IntentDescription(
        "Opens Voice Agent and starts listening straight away.",
        categoryName: "Voice"
    )
    /// The app has to be in front: it needs the microphone, and it may need to ask for it.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.shared.wantsListening = true
        return .result()
    }
}

/// Puts the intent in Shortcuts, Spotlight and the Action button's picker without the user having
/// to build a shortcut first.
struct VoiceAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTalkingIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Ask \(.applicationName)",
                "Start listening with \(.applicationName)",
            ],
            shortTitle: "Talk",
            systemImageName: "waveform"
        )
    }
}

/// The one-bit channel between an intent and the running app.
///
/// An intent may run before the app has finished launching, after it is already in front, or while
/// it is mid-sentence. So it sets a flag rather than calling anything, and the app picks the flag up
/// when it is in a position to honour it — which is also what makes the cold-launch case work,
/// where `perform()` happens before the model exists at all.
@MainActor
@Observable
final class LaunchRequest {
    static let shared = LaunchRequest()

    /// Set by the Action button, Siri or a shortcut. Cleared by the app once it has acted on it,
    /// so a second press is a second session rather than a no-op.
    var wantsListening = false

    private init() {}
}
