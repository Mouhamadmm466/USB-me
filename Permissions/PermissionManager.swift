import AVFoundation
import Contacts
import Core
import EventKit
import Foundation
import Telemetry

/// Backend that talks to the OS permission APIs. Abstracted so permission-denied behavior is
/// unit-testable without touching real system state.
public protocol PermissionBackend: Sendable {
    func currentStatus(_ kind: PermissionKind) async -> PermissionStatus
    func requestAccess(_ kind: PermissionKind) async -> PermissionStatus
}

/// Just-in-time permission manager (PRD §11).
///
/// - Requests a permission only when its status is `.notDetermined`.
/// - Never re-prompts after a denial in the same process (and iOS would not show the prompt again).
/// - Reports denial so the agent can explain the limitation and offer the Settings path.
public actor PermissionManager: PermissionProviding {
    private let backend: PermissionBackend
    private let logger: PrivacySafeLogger
    private var requestedThisSession: Set<PermissionKind> = []
    private var cache: [PermissionKind: PermissionStatus] = [:]

    public init(backend: PermissionBackend = SystemPermissionBackend(), logger: PrivacySafeLogger = .shared) {
        self.backend = backend
        self.logger = logger
    }

    public func status(for kind: PermissionKind) async -> PermissionStatus {
        let status = await backend.currentStatus(kind)
        cache[kind] = status
        return status
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        let current = await backend.currentStatus(kind)
        guard current == .notDetermined else {
            cache[kind] = current
            return current
        }
        // Guard against prompt loops even if the backend keeps reporting notDetermined.
        guard !requestedThisSession.contains(kind) else {
            cache[kind] = .denied
            return .denied
        }
        requestedThisSession.insert(kind)
        let result = await backend.requestAccess(kind)
        cache[kind] = result
        logger.log(.permission(kind: SafeLabel(kind), status: SafeLabel(result)))
        return result
    }

    public func snapshot() async -> PermissionsSnapshot {
        var statuses: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases {
            statuses[kind] = await backend.currentStatus(kind)
        }
        cache = statuses
        return PermissionsSnapshot(statuses: statuses)
    }

    /// True for statuses that let the tool proceed.
    public static func isUsable(_ status: PermissionStatus, for kind: PermissionKind) -> Bool {
        switch status {
        case .granted: true
        // Limited contacts access still lets us search the contacts the user shared; calendar
        // write-only access still allows creating events (the resolver refuses reads/updates).
        case .limited: kind == .contacts || kind == .calendar
        default: false
        }
    }
}

/// Supplies whether the user has authorized at least one folder via the document picker.
public protocol FileScopeAuthorizationSource: Sendable {
    func hasAuthorizedScope() async -> Bool
}

/// Real OS-backed permission checks.
public struct SystemPermissionBackend: PermissionBackend {
    private let fileScopes: FileScopeAuthorizationSource?

    public init(fileScopes: FileScopeAuthorizationSource? = nil) {
        self.fileScopes = fileScopes
    }

    public func currentStatus(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            return Self.microphoneStatus()
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .limited: return .limited
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        case .calendar:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .fileScope:
            return await (fileScopes?.hasAuthorizedScope() ?? false) ? .granted : .notDetermined
        }
    }

    public func requestAccess(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            #if os(iOS)
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .granted : .denied
            #else
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
            #endif
        case .contacts:
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
            return await currentStatus(.contacts)
        case .calendar:
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
            return await currentStatus(.calendar)
        case .reminders:
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToReminders()
            return await currentStatus(.reminders)
        case .fileScope:
            // Folder access is granted through the document picker UI, not a system prompt.
            return await currentStatus(.fileScope)
        }
    }

    private static func microphoneStatus() -> PermissionStatus {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .denied
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
        #endif
    }

    private static func eventKitStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}

/// Deterministic backend for tests, the evaluation harness and UI-test mode.
public actor FakePermissionBackend: PermissionBackend {
    private var statuses: [PermissionKind: PermissionStatus]
    private var responses: [PermissionKind: PermissionStatus]
    public private(set) var requestCounts: [PermissionKind: Int] = [:]

    public init(
        statuses: [PermissionKind: PermissionStatus] = [:],
        responses: [PermissionKind: PermissionStatus] = [:]
    ) {
        self.statuses = statuses
        self.responses = responses
    }

    public static func allGranted() -> FakePermissionBackend {
        FakePermissionBackend(statuses: Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) }))
    }

    public func currentStatus(_ kind: PermissionKind) async -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }

    public func requestAccess(_ kind: PermissionKind) async -> PermissionStatus {
        requestCounts[kind, default: 0] += 1
        let result = responses[kind] ?? .denied
        statuses[kind] = result
        return result
    }

    public func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        statuses[kind] = status
    }
}
