import Core
import Foundation
import Telemetry

/// Content-free error thrown by native adapters (Contacts, EventKit, scoped files, …).
///
/// Cases never carry user content (names, titles, paths), so they can be logged and mapped to a
/// `ToolFailureCode` without leaking anything.
public enum ToolAdapterError: String, Error, Sendable, Equatable, CaseIterable, SafeLabelConvertible {
    /// The OS reports that the app is not authorized for this data.
    case permissionDenied
    /// The record (contact, event, file, scope) no longer exists.
    case notFound
    /// The capability is missing on this device (no Messages, no phone, no presenter).
    case unavailable
    /// A relative path was malformed (absolute, `..`, empty, NUL, …).
    case invalidPath
    /// A path resolved (after standardizing and following symlinks) outside its authorized scope.
    case outsideScope
    /// The referenced folder scope is not (or no longer) authorized.
    case scopeNotFound
    /// There is no default calendar / reminders list to write to.
    case noDefaultCalendar
    /// The target lives in a read-only calendar (subscriptions, holidays, birthdays).
    case readOnly
    /// Arguments were rejected by the native API.
    case invalidArgument
    /// Any other native failure.
    case systemFailure

    /// The truthful tool-level failure code for this adapter error.
    public var failureCode: ToolFailureCode {
        switch self {
        case .permissionDenied: .permissionDenied
        case .notFound: .notFound
        case .unavailable, .noDefaultCalendar: .notAvailableOnDevice
        case .invalidPath, .outsideScope, .invalidArgument: .invalidArguments
        case .scopeNotFound: .noAuthorizedScope
        case .readOnly: .unsupported
        case .systemFailure: .systemError
        }
    }

    /// Maps any thrown error to a failure code without inspecting its (possibly content-bearing)
    /// description.
    public static func failureCode(for error: any Error) -> ToolFailureCode {
        if let adapterError = error as? ToolAdapterError { return adapterError.failureCode }
        if error is CancellationError { return .timeout }
        return .systemError
    }
}
