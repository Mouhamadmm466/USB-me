import Foundation
import Telemetry

public struct ConversationTurn: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let role: Role
    public let text: String
    public let timestamp: Date

    public init(role: Role, text: String, timestamp: Date) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ContactReference: Codable, Sendable, Hashable {
    public let contactIdentifier: String
    public let displayName: String

    public init(contactIdentifier: String, displayName: String) {
        self.contactIdentifier = contactIdentifier
        self.displayName = displayName
    }
}

public enum PermissionStatus: String, Codable, Sendable, SafeLabelConvertible {
    case notDetermined
    case granted
    case denied
    case restricted
    /// Contacts "limited access" (iOS 18) or calendar write-only access.
    case limited
}

public struct PermissionsSnapshot: Codable, Sendable, Equatable {
    public var statuses: [PermissionKind: PermissionStatus]

    public init(statuses: [PermissionKind: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }
}

/// Entities resolved natively during this conversation, used for safe pronoun resolution
/// ("call him", "move it") and ordinal selection ("the second one").
public struct ResolvedEntities: Codable, Sendable, Equatable {
    public private(set) var contacts: [ContactReference] = []
    public private(set) var events: [EventReference] = []
    public private(set) var files: [FileReference] = []
    private let limit: Int

    public init(limit: Int = 8) {
        self.limit = limit
    }

    public mutating func remember(contact: ContactReference) {
        contacts.removeAll { $0.contactIdentifier == contact.contactIdentifier }
        contacts.insert(contact, at: 0)
        if contacts.count > limit { contacts.removeLast(contacts.count - limit) }
    }

    public mutating func remember(event: EventReference) {
        events.removeAll { $0.eventIdentifier == event.eventIdentifier }
        events.insert(event, at: 0)
        if events.count > limit { events.removeLast(events.count - limit) }
    }

    public mutating func remember(file: FileReference) {
        files.removeAll { $0 == file }
        files.insert(file, at: 0)
        if files.count > limit { files.removeLast(files.count - limit) }
    }

    public mutating func clear() {
        contacts.removeAll()
        events.removeAll()
        files.removeAll()
    }
}

public enum ConfirmationState: Equatable, Sendable {
    case none
    /// A pending action has been presented; `reprompts` counts unclear answers so far.
    case awaitingResponse(reprompts: Int)
    case approved
    case rejected
}

/// Authoritative structured session state (PRD §8). The model receives a compact rendering of
/// this, never an unbounded transcript.
public struct SessionState: Sendable, Equatable {
    public var conversationID: UUID
    public private(set) var recentTurns: [ConversationTurn] = []
    public var currentGoal: String?
    public var pendingAction: PendingAction?
    public var resolvedEntities = ResolvedEntities()
    public var lastContact: ContactReference?
    public var lastCalendarEvent: EventReference?
    public var lastToolResult: ToolResultSummary?
    public var confirmationState: ConfirmationState = .none
    public var permissionsSnapshot = PermissionsSnapshot()
    public var clarification: PendingClarification?
    public let maxRecentTurns: Int

    public init(conversationID: UUID = UUID(), maxRecentTurns: Int = 6) {
        self.conversationID = conversationID
        self.maxRecentTurns = maxRecentTurns
    }

    public mutating func append(_ turn: ConversationTurn) {
        recentTurns.append(turn)
        if recentTurns.count > maxRecentTurns {
            recentTurns.removeFirst(recentTurns.count - maxRecentTurns)
        }
    }

    /// Clears conversational context (new conversation / clear history) but keeps permissions.
    public mutating func reset(conversationID: UUID = UUID()) {
        let permissions = permissionsSnapshot
        self = SessionState(conversationID: conversationID, maxRecentTurns: maxRecentTurns)
        permissionsSnapshot = permissions
    }
}
