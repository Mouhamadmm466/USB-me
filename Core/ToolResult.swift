import Foundation
import Telemetry

public struct ContactSummary: Codable, Sendable, Hashable {
    public let contactIdentifier: String
    public let displayName: String
    public let phoneNumbers: [LabeledPhone]

    public init(contactIdentifier: String, displayName: String, phoneNumbers: [LabeledPhone]) {
        self.contactIdentifier = contactIdentifier
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
    }
}

public struct LabeledPhone: Codable, Sendable, Hashable {
    public let label: String?
    public let number: String

    public init(label: String?, number: String) {
        self.label = label
        self.number = number
    }
}

public struct FileSummary: Codable, Sendable, Hashable {
    public let reference: FileReference
    public let modifiedAt: Date?
    public let byteSize: Int64?

    public init(reference: FileReference, modifiedAt: Date?, byteSize: Int64?) {
        self.reference = reference
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
    }
}

/// What actually happened, as reported by a native executor.
public enum ToolOutcome: Codable, Sendable, Hashable {
    case contactsFound([ContactSummary])
    /// The system call flow was opened. iOS may still ask the user to confirm the call.
    case callStarted(ContactTarget)
    /// MessageUI reported `.sent`.
    case messageSent(ContactTarget)
    case eventsListed([EventReference], DateRange)
    case eventCreated(EventReference)
    case eventUpdated(EventReference)
    case reminderCreated(ReminderDraft)
    case filesFound([FileSummary])
    case fileOpened(FileReference)
    case appOpened(SupportedApp)
}

public enum ToolFailureCode: String, Codable, Sendable, SafeLabelConvertible {
    case permissionDenied
    case notAvailableOnDevice
    case notFound
    case invalidArguments
    case confirmationMismatch
    case expired
    case systemError
    case unsupported
    case timeout
    case noAuthorizedScope
}

public struct ToolFailure: Error, Codable, Sendable, Hashable {
    public let tool: ToolID
    public let code: ToolFailureCode

    public init(tool: ToolID, code: ToolFailureCode) {
        self.tool = tool
        self.code = code
    }
}

public enum ToolResult: Sendable, Hashable {
    case success(ToolOutcome)
    /// The user dismissed Apple's system UI (e.g. cancelled the message composer).
    case cancelledByUser(ToolID)
    case failure(ToolFailure)

    public var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Compact, structured record of the last tool result kept in session state for follow-ups.
public struct ToolResultSummary: Codable, Sendable, Hashable {
    public let tool: ToolID
    public let succeeded: Bool
    public let at: Date

    public init(tool: ToolID, succeeded: Bool, at: Date) {
        self.tool = tool
        self.succeeded = succeeded
        self.at = at
    }
}
