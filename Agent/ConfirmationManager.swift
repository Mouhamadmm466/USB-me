import Core
import Foundation
import Telemetry

/// How the user answered a confirmation prompt.
public enum ConfirmationReply: String, Sendable, Equatable, SafeLabelConvertible {
    /// Clear approval. The only reply that can release a side effect.
    case affirm
    /// Clear rejection.
    case reject
    /// "wait", "hold on": keep the action pending, do nothing.
    case defer_ = "defer"
    /// Carries new content ("yes but make it 30 minutes"): the action must be revised and
    /// re-confirmed. Never approval.
    case modify
    /// Hesitation, mixed signals ("yes no", "no, go ahead"), or noise.
    case unclear
}

/// Deterministic confirmation classifier (PRD §9, §15 "confirmation ambiguity").
///
/// Conservative by construction: an utterance is `affirm` only if *every* word belongs to the
/// affirmation or neutral vocabulary and there is no rejection, deferral or hesitation word.
/// Any unknown content word makes it a `modify` (sent to the model to revise the action, never
/// approval); mixed signals are `unclear`.
public struct ConfirmationClassifier: Sendable {
    public init() {}

    public func classify(_ text: String, pendingTool: ToolID?) -> ConfirmationReply {
        let words = Self.normalize(text)
        guard !words.isEmpty else { return .unclear }

        var affirm = 0, reject = 0, defer_ = 0, unclear = 0, content = 0
        var index = 0
        // Set after a negator ("don't", "do not", "please don't"): the next approval verb is negated.
        var negationPending = false
        let affirmLexicon = Self.affirmPhrases.union(Self.toolAffirmPhrases[pendingTool ?? .composeMessage] ?? [])
        while index < words.count {
            var matched = false
            for length in stride(from: min(5, words.count - index), through: 1, by: -1) {
                let phrase = words[index..<(index + length)].joined(separator: " ")
                // Order matters: negated verbs ("don't send") must win over affirm verbs ("send").
                if Self.rejectPhrases.contains(phrase) {
                    reject += 1
                    negationPending = Self.negators.contains(where: { phrase.hasSuffix($0) })
                } else if Self.deferPhrases.contains(phrase) {
                    defer_ += 1
                    negationPending = false
                } else if Self.unclearPhrases.contains(phrase) {
                    unclear += 1
                    negationPending = false
                } else if affirmLexicon.contains(phrase) {
                    if negationPending { reject += 1 } else { affirm += 1 }
                    negationPending = false
                } else if Self.neutralPhrases.contains(phrase) {
                    // Filler: neither approves nor rejects; keeps a pending negation alive ("don't just send it").
                } else {
                    continue
                }
                index += length
                matched = true
                break
            }
            if !matched {
                content += 1
                index += 1
            }
        }

        if content > 0 { return .modify }
        if affirm == 0, reject == 0, defer_ == 0 { return .unclear }
        if unclear > 0 { return .unclear }
        if defer_ > 0 { return affirm > 0 ? .unclear : .defer_ }
        if affirm > 0, reject > 0 { return .unclear }
        if reject > 0 { return .reject }
        return .affirm
    }

    // MARK: - Normalization

    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        var cleaned = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'" {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map { word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return Self.contractions[trimmed] ?? trimmed
        }.filter { !$0.isEmpty }
        .flatMap { $0.split(separator: " ").map(String.init) }
    }

    static let contractions: [String: String] = [
        "dont": "don't", "do n't": "don't", "cant": "can't", "wont": "won't", "im": "i'm",
        "thats": "that's", "lets": "let's", "ok": "okay", "k": "okay", "kay": "okay", "yea": "yeah",
        "ya": "yeah", "yah": "yeah", "nah": "no", "naw": "no", "nope": "no", "yup": "yes", "yep": "yes",
        "alright": "all right", "nevermind": "never mind", "mhm": "yes", "uhhuh": "yes",
    ]

    // MARK: - Lexicons (all lowercase, normalized)

    static let affirmPhrases: Set<String> = [
        "yes", "yeah", "sure", "okay", "all right", "correct", "right", "confirm", "confirmed",
        "affirmative", "absolutely", "definitely", "of course", "certainly", "exactly", "perfect",
        "great", "good", "fine", "sounds good", "sounds great", "looks good", "that's right",
        "that's correct", "that is right", "that is correct", "go ahead", "go for it", "do it",
        "please do", "yes please", "sure thing", "let's do it", "let's go", "proceed", "continue",
        "i'm sure", "why not", "you bet", "yes do it", "yes go ahead", "do that", "go on",
        "that works", "works for me", "i confirm", "approved", "approve",
    ]

    /// Verbs that approve only the matching kind of action ("send it" approves a message, not a call).
    static let toolAffirmPhrases: [ToolID: Set<String>] = [
        .composeMessage: ["send", "send it", "send that", "send the message", "send the text", "text it", "text them", "text him", "text her"],
        .initiateCall: ["call", "call them", "call him", "call her", "call now", "dial", "dial it", "place the call", "make the call", "call it"],
        .createCalendarEvent: ["add", "add it", "add that", "create", "create it", "schedule", "schedule it", "book it", "save", "save it", "put it on"],
        .updateCalendarEvent: ["update", "update it", "save", "save it", "apply", "apply it", "make the change"],
        .createReminder: ["add", "add it", "create", "create it", "set", "set it", "save", "save it", "remind me"],
    ]

    static let rejectPhrases: Set<String> = [
        "no", "no thanks", "no thank you", "cancel", "cancel it", "cancel that", "cancel this", "stop",
        "stop it", "don't", "do not", "don't do it", "don't do that", "never mind", "forget it",
        "forget about it", "forget that", "abort", "not now", "negative", "i changed my mind",
        "changed my mind", "scratch that", "leave it", "skip it", "skip", "please don't", "i don't want to",
        "i don't want that", "no way", "absolutely not", "definitely not", "don't bother", "drop it",
        "don't send", "don't send it", "don't send that", "do not send", "don't call", "do not call",
        "don't add", "don't add it", "don't create", "don't create it", "don't save", "don't update",
        "don't text", "hang up", "no don't", "not that", "wrong",
    ]

    static let deferPhrases: Set<String> = [
        "wait", "wait a second", "wait a minute", "wait a sec", "hold on", "hold on a second", "hang on",
        "hang on a second", "one sec", "one second", "one moment", "just a sec", "just a second",
        "just a moment", "not yet", "give me a second", "give me a sec", "give me a minute",
        "give me a moment", "let me think", "let me think about it", "hold that thought", "a moment",
        "a second", "hold it", "pause",
    ]

    static let negators = ["don't", "do not", "not", "never"]

    static let unclearPhrases: Set<String> = [
        "maybe", "perhaps", "possibly",
        "probably", "i guess", "i guess so", "i think so", "i don't know", "not sure", "i'm not sure",
        "what", "huh", "pardon", "sorry", "what did you say", "say that again", "repeat that", "repeat",
        "come again", "who", "what was that", "i don't think so", "kind of", "sort of", "whatever",
        "if you want", "up to you", "meh",
    ]

    /// Filler and politeness words that neither approve nor reject.
    static let neutralPhrases: Set<String> = [
        "please", "thanks", "thank you", "thank", "you", "now", "then", "so", "well", "oh", "ah",
        "just", "it", "that", "this", "the", "a", "an", "and", "is", "it's", "that's", "go", "ahead",
        "for", "me", "i", "we", "can", "could", "would", "will", "do", "message", "text", "event",
        "reminder", "call", "one", "right now", "already", "again", "really", "very", "much", "my",
        "your", "said", "i said",
        // Pure fillers: alone they carry no signal (→ unclear), next to an answer they are ignored.
        "hmm", "hm", "hmmm", "um", "umm", "uh", "uhh", "er", "erm", "eh",
    ]
}

/// Tracks confirmation state for the current pending action and enforces versioned approval.
public struct ConfirmationManager: Sendable {
    public let classifier = ConfirmationClassifier()
    public let config: ConfirmationConfig

    public init(config: ConfirmationConfig = ConfirmationConfig()) {
        self.config = config
    }

    public enum Decision: Equatable, Sendable {
        case approve(ConfirmationToken)
        case reject
        case defer_
        case modify
        case reprompt(attempt: Int)
        case cancelAfterUnclear
        case expired
    }

    /// Applies a spoken/typed reply to the session's pending action.
    public func decide(reply text: String, session: inout SessionState, now: Date) -> Decision {
        guard var pending = session.pendingAction, pending.confirmationStatus == .pending else { return .expired }
        if pending.isExpired(at: now) {
            pending.reject()
            session.pendingAction = nil
            session.confirmationState = .none
            return .expired
        }
        switch classifier.classify(text, pendingTool: pending.tool) {
        case .affirm:
            guard let token = pending.approve(at: now) else { return .expired }
            session.pendingAction = pending
            session.confirmationState = .approved
            return .approve(token)
        case .reject:
            pending.reject()
            session.pendingAction = nil
            session.confirmationState = .rejected
            return .reject
        case .defer_:
            return .defer_
        case .modify:
            return .modify
        case .unclear:
            let attempts: Int
            if case let .awaitingResponse(reprompts) = session.confirmationState { attempts = reprompts + 1 } else { attempts = 1 }
            if attempts > config.maxUnclearReprompts {
                pending.reject()
                session.pendingAction = nil
                session.confirmationState = .rejected
                return .cancelAfterUnclear
            }
            session.confirmationState = .awaitingResponse(reprompts: attempts)
            return .reprompt(attempt: attempts)
        }
    }

    /// Approval from the visual action card. Must match the exact id and version on screen.
    public func approveFromCard(id: UUID, version: Int, session: inout SessionState, now: Date) -> ConfirmationToken? {
        guard var pending = session.pendingAction, pending.id == id, pending.version == version else { return nil }
        guard let token = pending.approve(at: now) else { return nil }
        session.pendingAction = pending
        session.confirmationState = .approved
        return token
    }
}
