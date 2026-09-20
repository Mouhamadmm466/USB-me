import Foundation
import Telemetry

/// The things the personal intelligence can hold (PRD §7). A closed vocabulary: the model can only
/// ever propose one of these kinds, and every kind has a defined set of legal statements about it
/// (`PredicateCatalog`).
public enum EntityKind: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case person
    case project
    case goal
    case task
    case commitment
    case decision
    case event
    case document
    case artifact
    /// Where knowledge came from: a file, a web page, a shared item, a connected service.
    case source
    /// A configured connector (Gmail, GitHub …).
    case connection
    case plan
    case planStep = "plan_step"
    case conversation

    public var safeLabelText: String { rawValue }

    /// Kinds the memory extractor may create from a conversation (plans, artifacts, sources,
    /// connections and conversations are created by the system, never proposed as "memories").
    public static let learnable: Set<EntityKind> = [.person, .project, .goal, .task, .commitment, .decision, .event]

    public var displayName: String {
        switch self {
        case .person: "Person"
        case .project: "Project"
        case .goal: "Goal"
        case .task: "Task"
        case .commitment: "Commitment"
        case .decision: "Decision"
        case .event: "Event"
        case .document: "Document"
        case .artifact: "Artifact"
        case .source: "Source"
        case .connection: "Connection"
        case .plan: "Plan"
        case .planStep: "Plan step"
        case .conversation: "Conversation"
        }
    }

    /// Statuses this kind may have; the first is the default.
    public var statuses: [EntityStatus] {
        switch self {
        case .project: [.active, .paused, .completed, .archived]
        case .goal: [.active, .achieved, .abandoned]
        case .task: [.open, .inProgress, .done, .blocked, .cancelled]
        case .commitment: [.open, .fulfilled, .cancelled]
        case .decision: [.made, .reversed]
        case .event: [.scheduled, .cancelled]
        case .plan, .planStep: [.proposed, .approved, .running, .blocked, .completed, .failed, .cancelled]
        default: [.active, .archived]
        }
    }
}

public enum EntityStatus: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case active, paused, completed, archived
    case achieved, abandoned
    case open, inProgress = "in_progress", done, blocked, cancelled
    case fulfilled
    case made, reversed
    case scheduled
    case proposed, approved, running, failed

    public var safeLabelText: String { rawValue }

    /// Work that still counts as outstanding for attention and progress.
    public var isOutstanding: Bool {
        switch self {
        case .active, .open, .inProgress, .blocked, .scheduled, .paused, .proposed, .approved, .running: true
        default: false
        }
    }
}

/// A node of the user's world. Its columns are a materialized view of the currently winning
/// assertions about it (`IntelligenceStore.materialize`), so queries stay simple and fast while
/// provenance and history live in the assertion log.
public struct IntelligenceEntity: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var kind: EntityKind
    public var title: String
    /// One line of context ("design", "Beta launch"), shown in lists.
    public var subtitle: String?
    public var status: EntityStatus
    /// Other names the user (or a source) uses for this entity; used by entity resolution.
    public var aliases: [String]
    public var projectID: UUID?
    public var startsAt: Date?
    public var endsAt: Date?
    public var dueAt: Date?
    /// 0…1, used for ranking in attention and retrieval.
    public var importance: Double
    /// Kind-specific extras (e.g. a decision's rationale, an event's calendar identifier).
    public var attributes: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: EntityKind,
        title: String,
        subtitle: String? = nil,
        status: EntityStatus? = nil,
        aliases: [String] = [],
        projectID: UUID? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        dueAt: Date? = nil,
        importance: Double = 0.5,
        attributes: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.status = status ?? kind.statuses.first ?? .active
        self.aliases = aliases
        self.projectID = projectID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.dueAt = dueAt
        self.importance = importance
        self.attributes = attributes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Every name this entity answers to, for matching and search.
    public var searchNames: [String] { [title] + aliases }
}

/// The user themselves: a fixed person entity every assertion about "me" hangs off.
public enum IntelligenceIdentity {
    public static let userEntityID = UUID(uuidString: "00000000-0000-4000-A000-000000000001")!
    public static let userTitle = "You"
}
