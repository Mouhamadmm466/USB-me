import Foundation
import Telemetry

/// What kind of thing happened. Closed vocabulary: the Activity feed groups by it, and it is the
/// only part of an entry that is ever logged.
public enum ActivityKind: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// Something was added to what the system knows.
    case learned
    /// The system asked before keeping something.
    case asked
    /// The user said yes.
    case confirmed
    /// The user said no, or corrected it.
    case corrected
    /// A statement stopped being true.
    case ended
    /// Something was imported (a document, a share, a connected service).
    case imported
    /// The agent did something in the world.
    case acted

    public var displayName: String {
        switch self {
        case .learned: "Learned"
        case .asked: "Asked"
        case .confirmed: "Confirmed"
        case .corrected: "Corrected"
        case .ended: "No longer true"
        case .imported: "Imported"
        case .acted: "Did"
        }
    }
}

/// How to take back what an entry describes.
///
/// Undo is part of the record, not a reconstruction after the fact: the entry itself says what to
/// do, so a change can always be reversed even after a restart.
public enum UndoAction: Sendable, Equatable, Codable {
    /// Reject the statement, and remove the entities it brought into existence — but only those,
    /// since an entity the user made themselves is not the system's to delete.
    case reject(UUID, forgetting: [UUID] = [])
    /// Put back a statement that was ended.
    case restore(UUID)
    /// Remove an entity the system created.
    case forget(UUID)
    /// Nothing to undo — the entry is a record of something the user themselves did.
    case none
}

/// One line of "here is what happened", with the handle needed to undo it.
public struct ActivityEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var kind: ActivityKind
    /// The deterministic sentence: "Abdou works on Offline App". Never model prose.
    public var headline: String
    /// Why the system holds it: "You told me today."
    public var detail: String?
    public var entityID: UUID?
    public var assertionID: UUID?
    public var undo: UndoAction
    public var createdAt: Date
    public var undoneAt: Date?

    public init(
        id: UUID = UUID(),
        kind: ActivityKind,
        headline: String,
        detail: String? = nil,
        entityID: UUID? = nil,
        assertionID: UUID? = nil,
        undo: UndoAction = .none,
        createdAt: Date = Date(),
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.entityID = entityID
        self.assertionID = assertionID
        self.undo = undo
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }

    public var isUndone: Bool { undoneAt != nil }
    public var canUndo: Bool { undo != .none && undoneAt == nil }
}

extension LearnedMemory {
    /// The activity entry for something a turn learned, including how to take it back.
    public func activityEntry(at date: Date = Date()) -> ActivityEntry {
        let kind: ActivityKind
        let undo: UndoAction
        switch outcome {
        case let .recorded(id), let .reinforced(id):
            kind = .learned
            undo = .reject(id, forgetting: createdEntityIDs)
        case let .proposed(id), let .conflicted(id, _):
            kind = .asked
            undo = .reject(id, forgetting: createdEntityIDs)
        case let .ended(id):
            kind = .ended
            undo = .restore(id)
        case let .endProposed(id):
            kind = .asked
            undo = .restore(id)
        }
        return ActivityEntry(
            kind: kind, headline: sentence, detail: explanation, entityID: subjectID,
            assertionID: outcome.assertionID, undo: undo, createdAt: date
        )
    }
}
