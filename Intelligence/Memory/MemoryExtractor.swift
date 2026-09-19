import Core
import Foundation
import Telemetry

/// What the extractor is given about a turn. Only the user's own words and what the assistant
/// answered — never tool results, which are data about the world rather than the user saying
/// something about it.
public struct MemoryTurn: Sendable, Equatable {
    public var userText: String
    public var assistantText: String?
    public var turnID: String?
    public var now: Date

    public init(userText: String, assistantText: String? = nil, turnID: String? = nil, now: Date = Date()) {
        self.userText = userText
        self.assistantText = assistantText
        self.turnID = turnID
        self.now = now
    }
}

public protocol MemoryExtracting: Sendable {
    /// Proposals for one turn, or an empty set when there is nothing to remember.
    func propose(from turn: MemoryTurn, known: [IntelligenceEntity]) async throws -> MemoryProposalSet
}

/// Runs Nemotron under the memory grammar to turn a turn into proposed statements.
///
/// It only ever produces proposals: nothing here writes, and everything it emits still has to pass
/// the validator, the policy and entity resolution. The grammar means the model cannot emit a
/// statement the catalog forbids, so the failure mode is an irrelevant memory, never a malformed
/// store.
public struct LanguageModelMemoryExtractor: MemoryExtracting {
    public let model: any LanguageModel
    public var maximumMemories: Int
    public var maximumOutputTokens: Int
    private let logger: PrivacySafeLogger?

    public init(
        model: any LanguageModel,
        maximumMemories: Int = 4,
        maximumOutputTokens: Int = 220,
        logger: PrivacySafeLogger? = nil
    ) {
        self.model = model
        self.maximumMemories = maximumMemories
        self.maximumOutputTokens = maximumOutputTokens
        self.logger = logger
    }

    public func propose(from turn: MemoryTurn, known: [IntelligenceEntity]) async throws -> MemoryProposalSet {
        let request = LLMRequest(
            cacheablePrefix: Self.prefix(maximumMemories: maximumMemories),
            suffix: Self.suffix(turn: turn, known: known),
            grammar: MemoryGrammar.grammar(maximumMemories: maximumMemories),
            maxOutputTokens: maximumOutputTokens,
            // Names and dates are copied from the user's words, so drafting from them is free speed.
            draftSources: [turn.userText, known.map(\.title).joined(separator: " ")]
        )
        var text = ""
        for try await event in model.generate(request) {
            if case let .text(delta) = event { text += delta }
        }
        guard let data = text.data(using: .utf8), !text.isEmpty else { return MemoryProposalSet() }
        do {
            return try JSONDecoder().decode(MemoryProposalSet.self, from: data)
        } catch {
            // Grammar-constrained output should always decode; if it ever does not, the turn is
            // simply not remembered rather than half-remembered.
            logger?.log(.error(domain: "intelligence", code: "memory_decode"))
            return MemoryProposalSet()
        }
    }

    // MARK: - Prompt

    /// The static half, cached by the runtime exactly like the turn prefix.
    public static func prefix(maximumMemories: Int = 4) -> String {
        let instructions = """
        You extract memories from a conversation on the user's phone. Read the latest exchange and \
        reply with exactly one JSON object listing what is worth remembering about the user's world: \
        their people, projects, goals, tasks, commitments, decisions and events.

        \(MemoryGrammar.promptSection())

        Rules:
        1. Only what the user said in this exchange. Never anything from earlier, and never anything you assumed.
        2. Names exactly as the user said them. Dates exactly as the user said them ("next friday"), never a calendar date.
        3. Questions, small talk and requests for the assistant to do something are not memories.
        4. "op":"end" only when the user says something stopped being true.
        5. "confidence" is how sure you are it was actually said: 0.9 when it was stated outright, 0.5 when you are reading between the lines.
        6. At most \(maximumMemories) memories. Nothing worth keeping: {"memories":[]}
        7. Reply with the JSON object only.
        """
        var text = "<|im_start|>system\n" + instructions + "<|im_end|>\n"
        for example in examples {
            text += "<|im_start|>user\n" + example.user + "<|im_end|>\n"
            text += "<|im_start|>assistant\n<think></think>" + example.output + "<|im_end|>\n"
        }
        return text
    }

    static func suffix(turn: MemoryTurn, known: [IntelligenceEntity]) -> String {
        var lines: [String] = []
        if !known.isEmpty {
            // Existing names, so the model reuses them instead of inventing a second spelling.
            lines.append("Already known: " + known.prefix(12).map { "\($0.title) (\($0.kind.rawValue))" }.joined(separator: ", "))
        }
        lines.append("User: " + single(turn.userText, limit: 600))
        if let assistant = turn.assistantText, !assistant.isEmpty {
            lines.append("Assistant: " + single(assistant, limit: 300))
        }
        return "<|im_start|>user\n" + lines.joined(separator: "\n") + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    private static func single(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit))
    }

    struct Example: Sendable {
        let user: String
        let output: String
    }

    /// Few-shot examples. Each output is legal under the generated grammar (enforced by tests).
    static let examples: [Example] = [
        Example(
            user: "User: Abdou is working on the offline app with me, he's doing the voice loop",
            output: #"{"memories":[{"op":"add","subject":{"kind":"person","name":"Abdou"},"predicate":"works_on","object":{"kind":"project","name":"offline app"},"text":"the voice loop"}]}"#
        ),
        Example(
            user: "User: the beta has to ship by next friday",
            output: #"{"memories":[{"op":"add","subject":{"kind":"goal","name":"the beta"},"predicate":"deadline","when":"next friday"}]}"#
        ),
        Example(
            user: "User: Sarah isn't on the beta anymore",
            output: #"{"memories":[{"op":"end","subject":{"kind":"person","name":"Sarah"},"predicate":"works_on","object":{"kind":"project","name":"the beta"}}]}"#
        ),
        Example(
            user: "User: what's on my calendar tomorrow\nAssistant: You have two events tomorrow.",
            output: #"{"memories":[]}"#
        ),
    ]
}

/// Used when learning is switched off, and in tests: proposes nothing, costs nothing.
public struct NoMemoryExtractor: MemoryExtracting {
    public init() {}
    public func propose(from turn: MemoryTurn, known: [IntelligenceEntity]) async throws -> MemoryProposalSet {
        MemoryProposalSet()
    }
}
