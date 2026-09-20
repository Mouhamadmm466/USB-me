import Foundation
import Intelligence

/// What a V2 evaluation case is made of.
///
/// One case is a small world (documents and facts), a fixed clock, and a script of things the user
/// says or asks — each with expectations about what the intelligence should then hold, retrieve,
/// plan or refuse. Cases are hand-written rather than generated, because what is being measured is
/// meaning, not coverage of a grammar.
public struct IntelligenceEvalCase: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// memory · recall · retrieval · planning · safety · attention
    public var suite: String
    public var tags: [String]
    /// Local wall clock, "YYYY-MM-DDTHH:MM:SS", read in `timezone`.
    public var now: String
    public var timezone: String
    public var setup: [SetupStep]
    public var script: [ScriptStep]

    public init(
        id: String, suite: String, tags: [String] = [], now: String, timezone: String = "America/New_York",
        setup: [SetupStep] = [], script: [ScriptStep] = []
    ) {
        self.id = id
        self.suite = suite
        self.tags = tags
        self.now = now
        self.timezone = timezone
        self.setup = setup
        self.script = script
    }

    /// Hand-written cases leave out what does not matter, so decoding fills the rest in. Synthesized
    /// `Codable` would demand every key, which would make the files noise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        suite = try container.decode(String.self, forKey: .suite)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        now = try container.decode(String.self, forKey: .now)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? "America/New_York"
        setup = try container.decodeIfPresent([SetupStep].self, forKey: .setup) ?? []
        script = try container.decodeIfPresent([ScriptStep].self, forKey: .script) ?? []
    }
}

/// The world before the script runs.
public struct SetupStep: Codable, Sendable, Equatable {
    /// A document the user has shared.
    public var document: DocumentSetup?
    /// Something already known, written directly (no model involved).
    public var fact: FactSetup?
    /// An entity that exists with dates and a status.
    public var entity: EntitySetup?

    public struct DocumentSetup: Codable, Sendable, Equatable {
        public var name: String
        public var text: String
        public var project: String?
        /// Days before "now" that it was imported.
        public var daysAgo: Int?
    }

    public struct FactSetup: Codable, Sendable, Equatable {
        public var subject: String
        public var subjectKind: String
        public var predicate: String
        public var object: String?
        public var objectKind: String?
        public var text: String?
        /// A date phrase resolved against the case's clock ("next friday", "+3d", "-2d").
        public var when: String?
        /// Days before "now" that it was said. Lets a case play out over time.
        public var daysAgo: Int?
        public var type: String?
    }

    public struct EntitySetup: Codable, Sendable, Equatable {
        public var kind: String
        public var title: String
        public var status: String?
        public var project: String?
        public var due: String?
        public var starts: String?
    }
}

/// One thing the user says or asks, and what should be true afterwards.
public struct ScriptStep: Codable, Sendable, Equatable {
    /// What the user said. Drives extraction when `proposals` is absent and a model is available.
    public var user: String?
    /// What the extractor is taken to have proposed. Lets the pipeline, policy and store be scored
    /// without a model in the loop — the deterministic half of the suite.
    public var proposals: [MemoryProposal]?
    public var expect: Expectation

    public init(user: String? = nil, proposals: [MemoryProposal]? = nil, expect: Expectation) {
        self.user = user
        self.proposals = proposals
        self.expect = expect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        proposals = try container.decodeIfPresent([MemoryProposal].self, forKey: .proposals)
        expect = try container.decodeIfPresent(Expectation.self, forKey: .expect) ?? Expectation()
    }
}

/// What must be true after a step. Every field is optional; a case asserts only what it is about.
public struct Expectation: Codable, Sendable, Equatable {
    /// Statements that must be active.
    public var holds: [ExpectedStatement]?
    /// Statements that must not be active (superseded, ended, never written).
    public var absent: [ExpectedStatement]?
    /// Statements that must be waiting on the user rather than applied.
    public var asks: [ExpectedStatement]?
    /// Fragments the turn context must contain for this utterance.
    public var contextContains: [String]?
    /// Fragments the turn context must not contain.
    public var contextOmits: [String]?
    /// The document the best passage must come from.
    public var passageFrom: String?
    /// Text the best passage must contain.
    public var passageContains: String?
    /// Capabilities the plan's scope must allow.
    public var planAllows: [String]?
    /// Capabilities the plan's scope must refuse, whatever the request looks like.
    public var planForbids: [String]?
    /// The top attention item's title.
    public var attentionFirst: String?
    /// What the attention reason must contain.
    public var attentionReason: String?

    public init(
        holds: [ExpectedStatement]? = nil,
        absent: [ExpectedStatement]? = nil,
        asks: [ExpectedStatement]? = nil,
        contextContains: [String]? = nil,
        contextOmits: [String]? = nil,
        passageFrom: String? = nil,
        passageContains: String? = nil,
        planAllows: [String]? = nil,
        planForbids: [String]? = nil,
        attentionFirst: String? = nil,
        attentionReason: String? = nil
    ) {
        self.holds = holds
        self.absent = absent
        self.asks = asks
        self.contextContains = contextContains
        self.contextOmits = contextOmits
        self.passageFrom = passageFrom
        self.passageContains = passageContains
        self.planAllows = planAllows
        self.planForbids = planForbids
        self.attentionFirst = attentionFirst
        self.attentionReason = attentionReason
    }
}

/// A statement named the way a person would: by the titles, not by identifiers.
public struct ExpectedStatement: Codable, Sendable, Equatable {
    public var subject: String
    public var predicate: String
    public var object: String?
    /// Compared case-insensitively; for dates, the resolved day.
    public var value: String?

    public init(subject: String, predicate: String, object: String? = nil, value: String? = nil) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.value = value
    }

    public var description: String {
        [subject, predicate, object, value].compactMap { $0 }.joined(separator: " ")
    }
}
