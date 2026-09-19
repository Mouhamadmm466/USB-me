import Foundation
import Telemetry

/// Why a turn looks worth remembering. A closed vocabulary, so the reason can be logged and shown
/// without ever logging what the user actually said.
public enum MemoryTrigger: String, CaseIterable, Sendable, Hashable, SafeLabelConvertible {
    case commitment
    case decision
    case deadline
    case relationship
    case preference
    case identity
    case correction
    case knownEntity
    case statedFact

    /// Signals strong enough to justify extraction even from a question ("did I tell you the beta
    /// slipped to Monday?" is still a fact about the beta).
    var isStrong: Bool {
        switch self {
        case .commitment, .decision, .preference, .identity, .correction, .relationship: true
        case .deadline, .knownEntity, .statedFact: false
        }
    }
}

public struct MemoryCandidate: Sendable, Equatable {
    public var triggers: Set<MemoryTrigger>
    public var isWorthwhile: Bool
    /// Rough 0…1 prior on how much is there, used to order background work when several turns queue.
    public var score: Double

    public static let none = MemoryCandidate(triggers: [], isWorthwhile: false, score: 0)
}

/// Decides, without the model, whether a turn is worth running extraction on.
///
/// Extraction costs a decode pass on the one GPU the user's next sentence also needs, so most turns
/// must be rejected here: "what time is it", "set a timer", "thanks" carry nothing to remember. The
/// filter is deliberately literal — word-boundary phrase matching over the user's own words — and
/// errs towards running extraction only when something in the sentence points at the user's world.
public struct MemoryFilter: Sendable {
    /// Names (titles and aliases) already in the store, folded. Mentioning one is itself a signal.
    public var knownNames: Set<String>

    public init(knownNames: Set<String> = []) {
        self.knownNames = Set(knownNames.map { $0.intelligenceFolded })
    }

    public func evaluate(userText: String, assistantText: String? = nil) -> MemoryCandidate {
        let text = " " + userText.intelligenceFolded
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression) + " "
        guard text.count > 3 else { return .none }

        var triggers: Set<MemoryTrigger> = []
        for (trigger, phrases) in Self.phrases where phrases.contains(where: { text.contains(" \($0) ") || text.contains(" \($0)") }) {
            triggers.insert(trigger)
        }
        if Self.weekdays.contains(where: { text.contains(" \($0) ") }) || text.range(of: #" \d{1,2}(st|nd|rd|th)? "#, options: .regularExpression) != nil {
            triggers.insert(.deadline)
        }
        if !knownNames.isEmpty, knownNames.contains(where: { !$0.isEmpty && text.contains(" \($0)") }) {
            triggers.insert(.knownEntity)
        }
        if Self.statedFact(text) { triggers.insert(.statedFact) }

        guard !triggers.isEmpty else { return .none }

        // A question is usually a retrieval, not a memory — unless it states something in passing.
        let isQuestion = userText.hasSuffix("?") || Self.questionOpeners.contains { text.hasPrefix(" \($0) ") }
        let worthwhile = isQuestion ? triggers.contains(where: \.isStrong) : true
        let score = min(1, triggers.reduce(0.0) { $0 + ($1.isStrong ? 0.4 : 0.2) })
        return MemoryCandidate(triggers: triggers, isWorthwhile: worthwhile, score: score)
    }

    /// "X is Y", "X has Y" — a bare assertion about something, which is worth a look when it also
    /// mentions someone or something known.
    private static func statedFact(_ text: String) -> Bool {
        [" is ", " are ", " was ", " has ", " have ", " belongs to ", " runs ", " uses "].contains { text.contains($0) }
    }

    private static let questionOpeners: Set<String> = [
        "what", "when", "where", "who", "why", "how", "which", "is", "are", "do", "does", "did",
        "can", "could", "will", "would", "should", "tell", "show", "remind",
    ]

    private static let weekdays: Set<String> = [
        "today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december", "weekend", "morning", "afternoon", "evening",
    ]

    private static let phrases: [MemoryTrigger: [String]] = [
        .commitment: [
            "i'll", "i will", "i need to", "i have to", "i've got to", "i gotta", "i promised",
            "i owe", "i'm supposed to", "i am supposed to", "i said i'd", "i'm going to", "i am going to",
            "i committed", "get back to", "follow up with", "send them", "owe",
        ],
        .decision: [
            "we decided", "i decided", "we've decided", "i've decided", "we're going with",
            "we are going with", "i'm going with", "we chose", "i chose", "we agreed", "let's go with",
            "we settled on", "the decision", "instead of", "we're not doing", "we ruled out",
        ],
        .deadline: [
            "deadline", "due", "by end of", "eod", "by the end", "no later than", "before the", "next week",
            "this week", "in two weeks", "in a week", "next month", "cutoff",
        ],
        .relationship: [
            "works on", "working on", "is on the", "joined", "left the", "my manager", "my boss",
            "my professor", "my advisor", "my teammate", "my cofounder", "my co-founder", "reports to",
            "is responsible for", "took over", "is leading", "assigned", "owns the", "part of the",
        ],
        .preference: [
            "i prefer", "i like", "i don't like", "i do not like", "i hate", "i love", "i always",
            "i never", "allergic", "i can't stand", "remember that i", "i usually", "i tend to",
            "don't ever", "never schedule", "i'm vegetarian", "i am vegetarian",
        ],
        .identity: [
            "my name is", "i'm called", "i work at", "i work for", "i study", "i'm studying",
            "i am studying", "my email", "my phone", "my number is", "i live in", "my company",
            "my team", "my project", "my goal", "i'm building", "i am building",
        ],
        .correction: [
            "actually", "i meant", "that's wrong", "that's not right", "not quite", "correction",
            "no it's", "no it is", "change that", "scratch that", "isn't anymore", "is no longer",
            "not anymore", "forget that",
        ],
    ]
}
