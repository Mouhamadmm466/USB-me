import Foundation

/// Resolves a date the way the user said it ("next Friday", "tomorrow at 3") into an instant.
///
/// Implemented outside this module by V1's deterministic parser: the model never does calendar
/// arithmetic, it only repeats the phrase, and Swift decides what it means. Used both when a
/// memory is written and when an utterance is linked to what is already known.
public protocol DatePhraseResolving: Sendable {
    func resolve(_ phrase: String, now: Date) -> Date?
}
