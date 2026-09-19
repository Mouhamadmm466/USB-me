import Foundation

/// Who a call or message goes to. `contactIdentifier` and `phoneNumber` come from a native
/// Contacts lookup (or, for dictated numbers, from digits verified to appear in the transcript) —
/// never from model output (PRD §18).
public struct ContactTarget: Codable, Sendable, Hashable {
    public let contactIdentifier: String?
    public let displayName: String
    public let phoneNumber: String
    public let phoneLabel: String?

    public init(contactIdentifier: String?, displayName: String, phoneNumber: String, phoneLabel: String?) {
        self.contactIdentifier = contactIdentifier
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.phoneLabel = phoneLabel
    }
}

/// A calendar event reference obtained from EventKit (never from the model).
public struct EventReference: Codable, Sendable, Hashable {
    public let eventIdentifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?

    public init(eventIdentifier: String, title: String, startDate: Date, endDate: Date, isAllDay: Bool = false, location: String? = nil) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
    }
}

public struct EventDraft: Codable, Sendable, Hashable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?

    public init(title: String, startDate: Date, endDate: Date, isAllDay: Bool = false, location: String? = nil) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
    }
}

public struct EventChanges: Codable, Sendable, Hashable {
    public let newTitle: String?
    public let newStartDate: Date?
    public let newEndDate: Date?
    public let newLocation: String?

    public init(newTitle: String? = nil, newStartDate: Date? = nil, newEndDate: Date? = nil, newLocation: String? = nil) {
        self.newTitle = newTitle
        self.newStartDate = newStartDate
        self.newEndDate = newEndDate
        self.newLocation = newLocation
    }

    public var isEmpty: Bool { newTitle == nil && newStartDate == nil && newEndDate == nil && newLocation == nil }
}

public struct ReminderDraft: Codable, Sendable, Hashable {
    public let title: String
    public let dueDate: Date?
    /// False when only a day was given ("tomorrow"): the reminder is date-only.
    public let dueHasTime: Bool

    public init(title: String, dueDate: Date?, dueHasTime: Bool) {
        self.title = title
        self.dueDate = dueDate
        self.dueHasTime = dueHasTime
    }
}

/// A file inside a user-authorized scope. `relativePath` comes from enumerating that scope,
/// never from the model.
public struct FileReference: Codable, Sendable, Hashable {
    public let scopeIdentifier: String
    public let relativePath: String
    public let displayName: String

    public init(scopeIdentifier: String, relativePath: String, displayName: String) {
        self.scopeIdentifier = scopeIdentifier
        self.relativePath = relativePath
        self.displayName = displayName
    }
}

public struct DateRange: Codable, Sendable, Hashable {
    public let start: Date
    public let end: Date
    /// Human description produced by the date parser ("tomorrow", "this week").
    public let spokenDescription: String

    public init(start: Date, end: Date, spokenDescription: String) {
        self.start = start
        self.end = end
        self.spokenDescription = spokenDescription
    }
}

/// A fully validated and natively resolved action. This is what `PendingAction` carries and what
/// the executor runs; it contains no unresolved model text except user-authored content fields
/// (message body, titles) that were length- and charset-validated.
public enum ResolvedAction: Codable, Sendable, Hashable {
    case searchContacts(query: String)
    case initiateCall(ContactTarget)
    case composeMessage(ContactTarget, body: String)
    case getCalendarEvents(DateRange)
    case createCalendarEvent(EventDraft)
    case updateCalendarEvent(EventReference, EventChanges)
    case createReminder(ReminderDraft)
    case searchFiles(query: String)
    case openFile(FileReference)
    case openSupportedApp(SupportedApp, query: String?)

    public var tool: ToolID {
        switch self {
        case .searchContacts: .searchContacts
        case .initiateCall: .initiateCall
        case .composeMessage: .composeMessage
        case .getCalendarEvents: .getCalendarEvents
        case .createCalendarEvent: .createCalendarEvent
        case .updateCalendarEvent: .updateCalendarEvent
        case .createReminder: .createReminder
        case .searchFiles: .searchFiles
        case .openFile: .openFile
        case .openSupportedApp: .openSupportedApp
        }
    }

    public var riskLevel: RiskLevel { ToolCatalog.spec(for: tool).riskLevel }
}
