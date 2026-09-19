import Core
import Foundation
import Permissions
import Telemetry

/// Everything the resolver and executor touch: native adapters, permissions, time and the date
/// parser. Production uses `.system(presenter:)` (iOS); tests and the evaluation harness use
/// `.fake(...)` / `FakeToolSuite`.
public struct ToolEnvironment: Sendable {
    public var contacts: any ContactsStore
    public var calendar: any CalendarStore
    public var reminders: any ReminderStore
    public var messages: any MessageComposing
    public var calls: any CallLaunching
    public var files: any FileScopeStore
    public var fileOpener: any FileOpening
    public var apps: any AppLaunching
    public var permissions: any PermissionProviding
    public var clock: AgentClock
    public var dateParser: DateParserFactory
    public var logger: PrivacySafeLogger

    public init(
        contacts: any ContactsStore,
        calendar: any CalendarStore,
        reminders: any ReminderStore,
        messages: any MessageComposing,
        calls: any CallLaunching,
        files: any FileScopeStore,
        fileOpener: any FileOpening,
        apps: any AppLaunching,
        permissions: any PermissionProviding,
        clock: AgentClock = AgentClock(),
        dateParser: @escaping DateParserFactory = DateParsers.standard,
        logger: PrivacySafeLogger = .shared
    ) {
        self.contacts = contacts
        self.calendar = calendar
        self.reminders = reminders
        self.messages = messages
        self.calls = calls
        self.files = files
        self.fileOpener = fileOpener
        self.apps = apps
        self.permissions = permissions
        self.clock = clock
        self.dateParser = dateParser
        self.logger = logger
    }
}

// MARK: - Fakes

/// A complete fake tool world with typed handles on every fake, for tests and the evaluation
/// harness (`suite.environment` is what the resolver/executor use; `suite.recorder` shows what
/// happened; the other handles allow failure injection and scripting).
public struct FakeToolSuite: Sendable {
    public let recorder: SideEffectRecorder
    public let contacts: FakeContactsStore
    public let calendar: FakeCalendarStore
    public let reminders: FakeReminderStore
    public let messages: FakeMessageComposer
    public let calls: FakeCallLauncher
    public let files: FakeFileScopeStore
    public let fileOpener: FakeFileOpener
    public let apps: FakeAppLauncher
    public let permissionBackend: FakePermissionBackend
    public let permissions: PermissionManager
    public let environment: ToolEnvironment

    /// - Parameters:
    ///   - permissions: statuses by kind; a missing kind is `.granted`, except `.fileScope`, which
    ///     is `.granted` only when `authorizedScopes` is not empty (like the real backend).
    ///   - permissionResponses: what a request returns (default `.denied`).
    public init(
        contacts: [ContactRecord] = [],
        events: [EventReference] = [],
        files: [FileSummary] = [],
        authorizedScopes: [String] = [],
        permissions: [PermissionKind: PermissionStatus] = [:],
        permissionResponses: [PermissionKind: PermissionStatus] = [:],
        canSendText: Bool = true,
        canPlaceCalls: Bool = true,
        composeOutcomes: [MessageComposeOutcome] = [],
        unavailableApps: Set<SupportedApp> = [],
        clock: AgentClock = AgentClock(),
        dateParser: DateParserFactory? = nil,
        recorder: SideEffectRecorder = SideEffectRecorder(),
        logger: PrivacySafeLogger = .shared
    ) {
        self.recorder = recorder
        self.contacts = FakeContactsStore(contacts: contacts)
        calendar = FakeCalendarStore(events: events, recorder: recorder, calendar: clock.calendar)
        reminders = FakeReminderStore(recorder: recorder)
        messages = FakeMessageComposer(canSendText: canSendText, outcomes: composeOutcomes, recorder: recorder)
        calls = FakeCallLauncher(canPlaceCalls: canPlaceCalls, recorder: recorder)
        self.files = FakeFileScopeStore(scopes: authorizedScopes, files: files)
        fileOpener = FakeFileOpener(store: self.files, recorder: recorder)
        apps = FakeAppLauncher(unavailableApps: unavailableApps, recorder: recorder)

        var statuses: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases {
            let defaultStatus: PermissionStatus = kind == .fileScope && authorizedScopes.isEmpty ? .notDetermined : .granted
            statuses[kind] = permissions[kind] ?? defaultStatus
        }
        permissionBackend = FakePermissionBackend(statuses: statuses, responses: permissionResponses)
        self.permissions = PermissionManager(backend: permissionBackend, logger: logger)

        environment = ToolEnvironment(
            contacts: self.contacts,
            calendar: calendar,
            reminders: reminders,
            messages: messages,
            calls: calls,
            files: self.files,
            fileOpener: fileOpener,
            apps: apps,
            permissions: self.permissions,
            clock: clock,
            dateParser: dateParser ?? DateParsers.standard,
            logger: logger
        )
    }
}

extension ToolEnvironment {
    /// A fake environment (see `FakeToolSuite` for the parameters and for handles on the fakes).
    public static func fake(
        contacts: [ContactRecord] = [],
        events: [EventReference] = [],
        files: [FileSummary] = [],
        authorizedScopes: [String] = [],
        permissions: [PermissionKind: PermissionStatus] = [:],
        permissionResponses: [PermissionKind: PermissionStatus] = [:],
        canSendText: Bool = true,
        canPlaceCalls: Bool = true,
        composeOutcomes: [MessageComposeOutcome] = [],
        unavailableApps: Set<SupportedApp> = [],
        clock: AgentClock = AgentClock(),
        dateParser: DateParserFactory? = nil,
        recorder: SideEffectRecorder = SideEffectRecorder(),
        logger: PrivacySafeLogger = .shared
    ) -> ToolEnvironment {
        FakeToolSuite(
            contacts: contacts,
            events: events,
            files: files,
            authorizedScopes: authorizedScopes,
            permissions: permissions,
            permissionResponses: permissionResponses,
            canSendText: canSendText,
            canPlaceCalls: canPlaceCalls,
            composeOutcomes: composeOutcomes,
            unavailableApps: unavailableApps,
            clock: clock,
            dateParser: dateParser,
            recorder: recorder,
            logger: logger
        ).environment
    }
}

// MARK: - System (iOS)

#if os(iOS) && canImport(UIKit)
import UIKit

extension ToolEnvironment {
    /// The production environment: Contacts, EventKit, MessageUI, `tel:`, security-scoped folders,
    /// Quick Look and allow-listed app URLs.
    ///
    /// - Parameters:
    ///   - presenter: returns the view controller system UI is presented from.
    ///   - fileScopes: the folder store (share it with `SystemPermissionBackend(fileScopes:)`).
    ///   - permissions: the app's permission manager; by default one backed by the OS and `fileScopes`.
    @MainActor
    public static func system(
        presenter: @escaping ViewControllerPresenter,
        fileScopes: (any FileScopeStore)? = nil,
        permissions: (any PermissionProviding)? = nil,
        clock: AgentClock = AgentClock(),
        logger: PrivacySafeLogger = .shared
    ) -> ToolEnvironment {
        let scopes = fileScopes ?? BookmarkFileScopeStore.standard()
        let eventKit = SystemEventKitStore(calendar: clock.calendar)
        return ToolEnvironment(
            contacts: SystemContactsStore(),
            calendar: eventKit,
            reminders: eventKit,
            messages: SystemMessageComposer(presenter: presenter),
            calls: SystemCallLauncher(),
            files: scopes,
            fileOpener: SystemFileOpener(presenter: presenter),
            apps: SystemAppLauncher(),
            permissions: permissions ?? PermissionManager(backend: SystemPermissionBackend(fileScopes: scopes), logger: logger),
            clock: clock,
            dateParser: DateParsers.standard,
            logger: logger
        )
    }
}
#endif
