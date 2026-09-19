import Foundation
import Telemetry

/// The closed V1 tool vocabulary (PRD §10). Anything outside this enum cannot be expressed by the
/// constrained decoder, cannot pass the validator, and cannot reach the executor.
public enum ToolID: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case searchContacts = "search_contacts"
    case initiateCall = "initiate_call"
    case composeMessage = "compose_message"
    case getCalendarEvents = "get_calendar_events"
    case createCalendarEvent = "create_calendar_event"
    case updateCalendarEvent = "update_calendar_event"
    case createReminder = "create_reminder"
    case searchFiles = "search_files"
    case openFile = "open_file"
    case openSupportedApp = "open_supported_app"
}

/// Permission domains used by tools. Requested just in time (PRD §11).
public enum PermissionKind: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case microphone
    case contacts
    case calendar
    case reminders
    /// User-selected folders via the document picker (security-scoped bookmarks).
    case fileScope
}

/// Apps that `open_supported_app` may open. Each maps to a fixed, Swift-owned URL; the model only
/// ever chooses an enum case, never a URL (PRD §18).
public enum SupportedApp: String, CaseIterable, Codable, Sendable, Hashable, SafeLabelConvertible {
    case maps
    case music
    case messages
    case mail
    case calendar
    case settings
    case appStore = "app_store"
    case shortcuts

    public var displayName: String {
        switch self {
        case .maps: "Maps"
        case .music: "Music"
        case .messages: "Messages"
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .settings: "Settings"
        case .appStore: "the App Store"
        case .shortcuts: "Shortcuts"
        }
    }
}

public enum PhoneLabel: String, CaseIterable, Codable, Sendable, Hashable {
    case mobile, home, work, other
}

public enum ToolArgumentKind: Sendable, Equatable {
    /// Free text copied or composed from the user's words. Length-limited.
    case text(maxLength: Int)
    /// A phone number the user dictated. Validated to 3–20 digits and checked against the transcript.
    case phoneNumber
    case integer(ClosedRange<Int>)
    /// Closed vocabulary.
    case choice([String])
}

public struct ToolArgumentSpec: Sendable, Equatable {
    public let name: String
    public let kind: ToolArgumentKind
    public let isRequired: Bool
    public let promptDescription: String

    public init(_ name: String, _ kind: ToolArgumentKind, required: Bool, _ promptDescription: String) {
        self.name = name
        self.kind = kind
        isRequired = required
        self.promptDescription = promptDescription
    }
}

public struct ToolSpec: Sendable, Equatable {
    public let id: ToolID
    public let promptDescription: String
    /// Ordered. The constrained decoder emits arguments in exactly this order.
    public let arguments: [ToolArgumentSpec]
    public let riskLevel: RiskLevel
    public let requiredPermissions: [PermissionKind]
    /// Groups of argument names of which at least one must be present.
    public let atLeastOneOf: [[String]]

    public func argument(named name: String) -> ToolArgumentSpec? {
        arguments.first { $0.name == name }
    }
}

/// A validated-for-shape but still *untrusted* tool call proposed by the model.
public struct ProposedToolCall: Sendable, Equatable, Codable {
    public let tool: ToolID
    public let arguments: [String: ToolArgumentValue]

    public init(tool: ToolID, arguments: [String: ToolArgumentValue]) {
        self.tool = tool
        self.arguments = arguments
    }

    public func string(_ key: String) -> String? {
        if case let .string(value)? = arguments[key] { return value }
        return nil
    }

    public func integer(_ key: String) -> Int? {
        if case let .integer(value)? = arguments[key] { return value }
        return nil
    }
}

public enum ToolArgumentValue: Sendable, Equatable, Hashable, Codable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .integer(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}

/// Single source of truth for tool schemas: drives the prompt, the grammar, the validator,
/// the risk policy and the permission checks.
public enum ToolCatalog {
    public static let dateHint = "as the user said it, e.g. \"tomorrow at 3pm\", \"next friday\", \"in 2 hours\""

    public static let all: [ToolSpec] = [
        ToolSpec(
            id: .searchContacts,
            promptDescription: "Look up a person in the user's contacts (e.g. to answer what their number is).",
            arguments: [
                ToolArgumentSpec("name", .text(maxLength: 80), required: true, "the person's name exactly as the user said it"),
            ],
            riskLevel: .readOnly,
            requiredPermissions: [.contacts],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .initiateCall,
            promptDescription: "Start a phone call.",
            arguments: [
                ToolArgumentSpec("contact_query", .text(maxLength: 80), required: false, "who to call, exactly as the user said it"),
                ToolArgumentSpec("phone_number", .phoneNumber, required: false, "only if the user dictated digits"),
                ToolArgumentSpec("phone_label", .choice(PhoneLabel.allCases.map(\.rawValue)), required: false, "only if the user named one"),
            ],
            riskLevel: .externalCommunication,
            requiredPermissions: [.contacts],
            atLeastOneOf: [["contact_query", "phone_number"]]
        ),
        ToolSpec(
            id: .composeMessage,
            promptDescription: "Write a text message for the user to send.",
            arguments: [
                ToolArgumentSpec("contact_query", .text(maxLength: 80), required: false, "recipient, exactly as the user said it"),
                ToolArgumentSpec("phone_number", .phoneNumber, required: false, "only if the user dictated digits"),
                ToolArgumentSpec("message", .text(maxLength: 500), required: true, "the text to send, written in the user's own first-person voice"),
            ],
            riskLevel: .externalCommunication,
            requiredPermissions: [.contacts],
            atLeastOneOf: [["contact_query", "phone_number"]]
        ),
        ToolSpec(
            id: .getCalendarEvents,
            promptDescription: "Read the user's calendar for a day or range.",
            arguments: [
                ToolArgumentSpec("when", .text(maxLength: 60), required: true, "day or range " + dateHint),
            ],
            riskLevel: .readOnly,
            requiredPermissions: [.calendar],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .createCalendarEvent,
            promptDescription: "Add a new event to the user's calendar.",
            arguments: [
                ToolArgumentSpec("title", .text(maxLength: 100), required: true, "short event title"),
                ToolArgumentSpec("start", .text(maxLength: 60), required: true, "start " + dateHint),
                ToolArgumentSpec("end", .text(maxLength: 60), required: false, "end time if the user gave one"),
                ToolArgumentSpec("duration_minutes", .integer(5...1440), required: false, "length in minutes if the user gave one"),
                ToolArgumentSpec("location", .text(maxLength: 100), required: false, "place if the user gave one"),
            ],
            riskLevel: .reversibleLocalWrite,
            requiredPermissions: [.calendar],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .updateCalendarEvent,
            promptDescription: "Change an existing calendar event (move it, rename it, change its length or place).",
            arguments: [
                ToolArgumentSpec("event_query", .text(maxLength: 100), required: true, "which event: words from its title, or \"it\" for the event just discussed"),
                ToolArgumentSpec("new_start", .text(maxLength: 60), required: false, "new start " + dateHint),
                ToolArgumentSpec("new_end", .text(maxLength: 60), required: false, "new end time"),
                ToolArgumentSpec("new_duration_minutes", .integer(5...1440), required: false, "new length in minutes"),
                ToolArgumentSpec("new_title", .text(maxLength: 100), required: false, "new title"),
                ToolArgumentSpec("new_location", .text(maxLength: 100), required: false, "new place"),
            ],
            riskLevel: .reversibleLocalWrite,
            requiredPermissions: [.calendar],
            atLeastOneOf: [["new_start", "new_end", "new_duration_minutes", "new_title", "new_location"]]
        ),
        ToolSpec(
            id: .createReminder,
            promptDescription: "Create a reminder.",
            arguments: [
                ToolArgumentSpec("title", .text(maxLength: 120), required: true, "what to be reminded about"),
                ToolArgumentSpec("due", .text(maxLength: 60), required: false, "when " + dateHint),
            ],
            riskLevel: .reversibleLocalWrite,
            requiredPermissions: [.reminders],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .searchFiles,
            promptDescription: "Search the folders the user has shared with this app.",
            arguments: [
                ToolArgumentSpec("query", .text(maxLength: 80), required: true, "words from the file name"),
            ],
            riskLevel: .readOnly,
            requiredPermissions: [.fileScope],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .openFile,
            promptDescription: "Open a file from the folders the user has shared with this app.",
            arguments: [
                ToolArgumentSpec("file_query", .text(maxLength: 120), required: true, "words from the file name"),
            ],
            riskLevel: .readOnly,
            requiredPermissions: [.fileScope],
            atLeastOneOf: []
        ),
        ToolSpec(
            id: .openSupportedApp,
            promptDescription: "Open one of these apps: " + SupportedApp.allCases.map(\.rawValue).joined(separator: ", ") + ".",
            arguments: [
                ToolArgumentSpec("app", .choice(SupportedApp.allCases.map(\.rawValue)), required: true, "which app"),
                ToolArgumentSpec("query", .text(maxLength: 80), required: false, "maps only: place to search for"),
            ],
            riskLevel: .readOnly,
            requiredPermissions: [],
            atLeastOneOf: []
        ),
    ]

    private static let byID: [ToolID: ToolSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func spec(for id: ToolID) -> ToolSpec {
        guard let spec = byID[id] else { preconditionFailure("ToolCatalog is missing \(id.rawValue)") }
        return spec
    }
}
