import Foundation
import Telemetry

/// How the system came to hold a statement (PRD §9).
public enum MemoryType: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    /// The user said it.
    case explicit
    /// Found in a source the user authorized (calendar, a document, a connected service).
    case observed
    /// The model concluded it from patterns. Lowest authority, always marked.
    case inferred
    /// Computed from other state (progress, overdue, free time). Recomputable, never authoritative.
    case derived

    public var safeLabelText: String { rawValue }
}

/// Which statement wins when two disagree (PRD §12). Higher always beats lower; equal is resolved
/// by recency. An inference can never overwrite something the user said.
public enum Authority: Int, CaseIterable, Codable, Sendable, Comparable, SafeLabelConvertible {
    case inference = 1
    case observation = 2
    case authoritativeSource = 3
    case userStatement = 4
    case userCorrection = 5

    public static func < (lhs: Authority, rhs: Authority) -> Bool { lhs.rawValue < rhs.rawValue }
    public var safeLabelText: String { "authority\(rawValue)" }

    public static func `default`(for type: MemoryType) -> Authority {
        switch type {
        case .explicit: .userStatement
        case .observed: .observation
        case .inferred: .inference
        case .derived: .inference
        }
    }
}

public enum AssertionState: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    /// Waiting for the user to confirm (policy asked).
    case proposed
    case active
    /// Replaced by a newer, at-least-equal-authority statement.
    case superseded
    /// Was true, no longer is ("Sarah left the project"): kept with `validTo` for history.
    case ended
    case rejected
    case expired

    public var safeLabelText: String { rawValue }
    public var isCurrent: Bool { self == .active }
}

/// Where a statement came from. Used for "why do you know that?" and to keep untrusted sources
/// from ever gaining user authority.
public enum SourceType: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case conversation
    case userEdit = "user_edit"
    case calendar
    case contacts
    case reminders
    case document
    case artifact
    case web
    case connector
    case share
    case system

    public var safeLabelText: String { rawValue }

    /// Sources that are the user speaking for themselves; everything else is data about the world.
    public var isUserVoice: Bool { self == .conversation || self == .userEdit }
}

public struct Provenance: Sendable, Equatable, Codable {
    public var sourceType: SourceType
    /// Identifier inside that source: a conversation turn id, an EventKit identifier, a document id.
    public var sourceID: String?
    /// Short quote that produced the statement, shown as "you told me: …". Never a whole document.
    public var excerpt: String?

    public init(sourceType: SourceType, sourceID: String? = nil, excerpt: String? = nil) {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.excerpt = excerpt.map { String($0.prefix(240)) }
    }

    public static let userEdit = Provenance(sourceType: .userEdit)
    public static let system = Provenance(sourceType: .system)
}

/// The value of an attribute statement. Dates keep the phrase the user actually said, so the
/// read-back can be "next Friday" while the stored value is an exact date resolved in Swift.
public enum AssertionValue: Sendable, Equatable, Codable {
    case text(String)
    case date(Date, phrase: String?)
    case number(Double)
    case flag(Bool)

    public var displayText: String {
        switch self {
        case let .text(value): value
        case let .date(date, phrase): phrase ?? ISO8601DateFormatter().string(from: date)
        case let .number(value): value == value.rounded() ? String(Int(value)) : String(value)
        case let .flag(value): value ? "yes" : "no"
        }
    }

    public var dateValue: Date? {
        if case let .date(date, _) = self { return date }
        return nil
    }

    public var textValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }
}

/// One statement about the world: a relationship (subject → predicate → object), an attribute
/// (subject → predicate → value) or a note. Everything the intelligence knows is a row of these,
/// with provenance, authority and a lifetime — which is what makes corrections, "why do you know
/// that?" and history possible.
public struct Assertion: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var subjectID: UUID
    public var predicate: Predicate
    public var objectID: UUID?
    public var value: AssertionValue?
    public var type: MemoryType
    public var authority: Authority
    public var confidence: Double
    public var importance: Double
    public var userConfirmed: Bool
    public var state: AssertionState
    public var supersededBy: UUID?
    public var provenance: Provenance
    public var validFrom: Date
    public var validTo: Date?
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAccessedAt: Date?

    public init(
        id: UUID = UUID(),
        subjectID: UUID,
        predicate: Predicate,
        objectID: UUID? = nil,
        value: AssertionValue? = nil,
        type: MemoryType = .explicit,
        authority: Authority? = nil,
        confidence: Double = 0.9,
        importance: Double = 0.5,
        userConfirmed: Bool = false,
        state: AssertionState = .active,
        supersededBy: UUID? = nil,
        provenance: Provenance,
        validFrom: Date = Date(),
        validTo: Date? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.predicate = predicate
        self.objectID = objectID
        self.value = value
        self.type = type
        self.authority = authority ?? .default(for: type)
        self.confidence = confidence
        self.importance = importance
        self.userConfirmed = userConfirmed
        self.state = state
        self.supersededBy = supersededBy
        self.provenance = provenance
        self.validFrom = validFrom
        self.validTo = validTo
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
    }

    public var isRelationship: Bool { objectID != nil }

    /// "You told me yesterday", "I found that in your calendar", "I inferred that — you haven't
    /// confirmed it." Deterministic, never model prose.
    public func explanation(now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = Self.relativeDay(createdAt, now: now, calendar: calendar)
        switch (type, provenance.sourceType) {
        case (.explicit, _): return "You told me\(when)."
        case (.observed, .calendar): return "I found it in your calendar\(when)."
        case (.observed, .contacts): return "It is in your contacts."
        case (.observed, .reminders): return "I found it in your reminders\(when)."
        case (.observed, .document), (.observed, .artifact): return "I read it in a document you shared\(when)."
        case (.observed, .web): return "I read it on a page I looked up\(when)."
        case (.observed, .connector): return "I found it in a connected service\(when)."
        case (.observed, .share): return "It came from something you shared with me\(when)."
        case (.inferred, _):
            return userConfirmed ? "I worked it out and you confirmed it." : "I worked it out from what I've seen. You haven't confirmed it."
        case (.derived, _): return "I calculated it from your current state."
        default: return "I recorded it\(when)."
        }
    }

    private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return " today"
        case 1: return " yesterday"
        case 2...6: return " this week"
        case 7...30: return " earlier this month"
        default: return ""
        }
    }
}
