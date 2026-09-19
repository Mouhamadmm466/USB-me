import Core
import Foundation

/// Decides whether a tool may touch a permission-protected store right now.
public enum PermissionGate {
    public enum Decision: Sendable, Equatable {
        case proceed
        /// Not asked yet: the coordinator requests it (just in time) and retries.
        case needsPermission(PermissionKind)
        /// Denied or restricted (or not usable for this tool).
        case denied
    }

    /// - Contacts `.limited` (iOS 18 limited access) is usable: it covers the contacts the user shared.
    /// - Calendar `.limited` (write-only access) is usable to add events only.
    /// - `.fileScope` is usable when at least one folder is authorized in the file store.
    public static func check(_ kind: PermissionKind, for tool: ToolID, environment: ToolEnvironment) async -> Decision {
        let status = await environment.permissions.status(for: kind)
        if kind == .fileScope {
            if status == .denied || status == .restricted { return .denied }
            return await environment.files.hasAuthorizedScope() ? .proceed : .needsPermission(.fileScope)
        }
        switch status {
        case .granted:
            return .proceed
        case .limited:
            return isLimitedAccessUsable(kind, for: tool) ? .proceed : .denied
        case .notDetermined:
            return .needsPermission(kind)
        case .denied, .restricted:
            return .denied
        }
    }

    static func isLimitedAccessUsable(_ kind: PermissionKind, for tool: ToolID) -> Bool {
        switch kind {
        case .contacts: true
        case .calendar: tool == .createCalendarEvent
        default: false
        }
    }
}
