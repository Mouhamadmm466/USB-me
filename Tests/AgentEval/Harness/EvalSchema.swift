import Core
import Foundation

// MARK: - Case schema (one JSON object per line in Tests/AgentEval/Cases/*.jsonl)

/// One deterministic evaluation case: a fixture world, a fixed "now", and 1+ user turns with
/// expectations about what the *whole agent* (model + validator + resolver + confirmation
/// manager + executor) did after each turn.
public struct EvalCase: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Top-level area, e.g. "contacts", "calls", "messages", "calendar", "reminders", "multi_turn",
    /// "unsupported", "injection", "confirmation", "answers", "files", "apps".
    public let category: String
    public let subcategory: String
    /// e.g. "canonical", "release_safety", "negation", "asr_noise", "duplicate_names".
    public let tags: [String]
    /// Fixture id (file Tests/AgentEval/Fixtures/<fixture>.json).
    public let fixture: String
    /// Local wall-clock time "YYYY-MM-DDTHH:MM:SS" interpreted in `timezone`.
    public let now: String
    /// IANA identifier, e.g. "America/New_York".
    public let timezone: String
    public let turns: [EvalTurn]
    public let safety: EvalSafety?

    public init(id: String, category: String, subcategory: String, tags: [String], fixture: String,
                now: String, timezone: String, turns: [EvalTurn], safety: EvalSafety?) {
        self.id = id
        self.category = category
        self.subcategory = subcategory
        self.tags = tags
        self.fixture = fixture
        self.now = now
        self.timezone = timezone
        self.turns = turns
        self.safety = safety
    }
}

public struct EvalTurn: Codable, Sendable, Equatable {
    /// What the user said (already a finalized utterance).
    public let user: String
    public let expect: TurnExpectation

    public init(user: String, expect: TurnExpectation) {
        self.user = user
        self.expect = expect
    }
}

/// What the agent visibly did after a turn.
public enum ObservedOutcome: String, Codable, Sendable, CaseIterable {
    /// Spoke an informational answer; no action created or executed.
    case answered
    /// Asked the user a question (model-authored or deterministic) and is waiting for the answer.
    case clarificationRequested = "clarification_requested"
    /// Created or revised a PendingAction and asked for confirmation.
    case confirmationRequested = "confirmation_requested"
    /// A tool actually executed this turn (read-only auto-execution or a confirmed action).
    case executed
    /// The user cancelled/rejected the pending action.
    case cancelled
    /// Declined as unsupported.
    case unsupported
    /// A permission is needed and was not granted.
    case permissionRequired = "permission_required"
    /// The confirmation answer was unclear; the assistant asked again and kept the action pending.
    case reprompted
    /// The user asked to wait; the action stays pending.
    case deferred
    /// Nothing happened (e.g. empty input).
    case noAction = "no_action"
}

public struct TurnExpectation: Codable, Sendable, Equatable {
    /// Acceptable outcomes (any of). Required.
    public let outcome: [ObservedOutcome]
    /// Tool of the pending/executed/clarified action, when relevant.
    public let tool: ToolID?
    /// Expectations on the *resolved* action (see `ArgumentExpectations`).
    public let args: ArgumentExpectations?
    public let clarificationReason: ClarificationReason?
    /// Expected PendingAction version after this turn (e.g. 2 after a modification).
    public let pendingVersion: Int?
    /// Cumulative number of consequential side effects (risk >= 1 executions) expected after this turn.
    public let sideEffects: Int?

    enum CodingKeys: String, CodingKey {
        case outcome, tool, args
        case clarificationReason = "clarification_reason"
        case pendingVersion = "pending_version"
        case sideEffects = "side_effects"
    }

    public init(outcome: [ObservedOutcome], tool: ToolID? = nil, args: ArgumentExpectations? = nil,
                clarificationReason: ClarificationReason? = nil, pendingVersion: Int? = nil, sideEffects: Int? = nil) {
        self.outcome = outcome
        self.tool = tool
        self.args = args
        self.clarificationReason = clarificationReason
        self.pendingVersion = pendingVersion
        self.sideEffects = sideEffects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept a single outcome string or an array of outcomes.
        if let single = try? c.decode(ObservedOutcome.self, forKey: .outcome) {
            outcome = [single]
        } else {
            outcome = try c.decode([ObservedOutcome].self, forKey: .outcome)
        }
        tool = try c.decodeIfPresent(ToolID.self, forKey: .tool)
        args = try c.decodeIfPresent(ArgumentExpectations.self, forKey: .args)
        clarificationReason = try c.decodeIfPresent(ClarificationReason.self, forKey: .clarificationReason)
        pendingVersion = try c.decodeIfPresent(Int.self, forKey: .pendingVersion)
        sideEffects = try c.decodeIfPresent(Int.self, forKey: .sideEffects)
    }
}

/// Expectations on the resolved action. Every field is optional; only present fields are scored.
/// Date-times are local "YYYY-MM-DDTHH:MM" in the case timezone; dates are "YYYY-MM-DD".
public struct ArgumentExpectations: Codable, Sendable, Equatable {
    // Contacts / calls / messages
    public var recipientID: String?
    public var recipientPhone: String?
    public var messageContains: [String]?
    public var messageNotContains: [String]?
    public var contactResultIDs: [String]?
    // Calendar / reminders
    public var titleContains: [String]?
    public var start: String?
    public var end: String?
    public var durationMinutes: Int?
    public var location: String?
    public var eventID: String?
    public var newStart: String?
    public var newEnd: String?
    public var newTitleContains: [String]?
    public var due: String?
    public var dueDateOnly: Bool?
    public var rangeStart: String?
    public var rangeEnd: String?
    // Files / apps
    public var fileID: String?
    public var app: SupportedApp?
    public var queryContains: [String]?

    enum CodingKeys: String, CodingKey {
        case recipientID = "recipient_id"
        case recipientPhone = "recipient_phone"
        case messageContains = "message_contains"
        case messageNotContains = "message_not_contains"
        case contactResultIDs = "contact_result_ids"
        case titleContains = "title_contains"
        case start, end
        case durationMinutes = "duration_minutes"
        case location
        case eventID = "event_id"
        case newStart = "new_start"
        case newEnd = "new_end"
        case newTitleContains = "new_title_contains"
        case due
        case dueDateOnly = "due_date_only"
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case fileID = "file_id"
        case app
        case queryContains = "query_contains"
    }

    public init() {}
}

public struct EvalSafety: Codable, Sendable, Equatable {
    /// Any consequential (risk >= 1) execution in this case is a safety failure.
    public let forbidSideEffects: Bool?
    /// Upper bound on consequential executions for the whole case.
    public let maxSideEffects: Int?

    enum CodingKeys: String, CodingKey {
        case forbidSideEffects = "forbid_side_effects"
        case maxSideEffects = "max_side_effects"
    }

    public init(forbidSideEffects: Bool?, maxSideEffects: Int?) {
        self.forbidSideEffects = forbidSideEffects
        self.maxSideEffects = maxSideEffects
    }
}

// MARK: - Fixture schema (Tests/AgentEval/Fixtures/<id>.json)

public struct EvalFixture: Codable, Sendable, Equatable {
    public let id: String
    public let contacts: [FixtureContact]
    /// Events with local "YYYY-MM-DDTHH:MM" times in the case timezone.
    public let events: [FixtureEvent]
    public let files: [FixtureFile]
    /// File scopes the user has authorized via the document picker.
    public let authorizedFileScopes: [String]
    /// PermissionKind rawValue -> PermissionStatus rawValue. Missing = granted.
    public let permissions: [String: String]
    /// PermissionKind rawValue -> status returned when the permission is requested.
    public let permissionResponses: [String: String]?
    /// Whether the device can send texts / place calls (false simulates an iPod-like device).
    public let canSendText: Bool?
    public let canPlaceCalls: Bool?

    enum CodingKeys: String, CodingKey {
        case id, contacts, events, files
        case authorizedFileScopes = "authorized_file_scopes"
        case permissions
        case permissionResponses = "permission_responses"
        case canSendText = "can_send_text"
        case canPlaceCalls = "can_place_calls"
    }
}

public struct FixtureContact: Codable, Sendable, Equatable {
    public let id: String
    public let given: String
    public let family: String?
    public let nickname: String?
    public let organization: String?
    public let phones: [FixturePhone]
}

public struct FixturePhone: Codable, Sendable, Equatable {
    public let label: String?
    public let number: String
}

public struct FixtureEvent: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let start: String
    public let end: String
    public let allDay: Bool?
    public let location: String?
    /// Free text that may contain adversarial content (prompt-injection tests).
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, title, start, end
        case allDay = "all_day"
        case location, notes
    }
}

public struct FixtureFile: Codable, Sendable, Equatable {
    public let scope: String
    /// Relative path inside the scope; used as the file id in expectations.
    public let path: String
    public let modified: String?
    public let bytes: Int64?
}

// MARK: - Observations produced by the runner

public struct TurnObservation: Codable, Sendable, Equatable {
    public let outcome: ObservedOutcome
    public let tool: ToolID?
    /// The pending action (if one is awaiting confirmation) or the action executed this turn.
    public let action: ResolvedAction?
    public let pendingVersion: Int?
    public let clarificationReason: ClarificationReason?
    public let spokenText: String
    /// Consequential (risk >= 1) side effects executed during this turn.
    public let consequentialExecutions: [ResolvedAction]
    /// Read-only executions during this turn.
    public let readOnlyExecutions: [ResolvedAction]
    /// Raw model outputs produced during this turn (debugging only; never logged in production).
    public let modelOutputs: [String]
    public let modelLatencyMilliseconds: Double

    public init(outcome: ObservedOutcome, tool: ToolID?, action: ResolvedAction?, pendingVersion: Int?,
                clarificationReason: ClarificationReason?, spokenText: String,
                consequentialExecutions: [ResolvedAction], readOnlyExecutions: [ResolvedAction],
                modelOutputs: [String], modelLatencyMilliseconds: Double) {
        self.outcome = outcome
        self.tool = tool
        self.action = action
        self.pendingVersion = pendingVersion
        self.clarificationReason = clarificationReason
        self.spokenText = spokenText
        self.consequentialExecutions = consequentialExecutions
        self.readOnlyExecutions = readOnlyExecutions
        self.modelOutputs = modelOutputs
        self.modelLatencyMilliseconds = modelLatencyMilliseconds
    }
}
