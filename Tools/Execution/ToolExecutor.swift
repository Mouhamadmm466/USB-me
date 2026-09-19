import Core
import Foundation
import Telemetry

/// Executes resolved actions through the environment's adapters and reports only what the native
/// API actually returned.
///
/// - `executeReadOnly` runs risk-0 actions only; anything else is refused with
///   `.confirmationMismatch` and has no side effect.
/// - `execute(_:token:)` first binds the token to the exact PendingAction id, version and argument
///   digest (mismatch ⇒ `.confirmationMismatch`, expired ⇒ `.expired`, both without side
///   effects), refuses a second execution of the same version, re-checks the permission, then
///   performs the action once.
public actor ToolExecutor: ToolExecuting {
    private struct ExecutionKey: Hashable {
        let id: UUID
        let version: Int
    }

    static let maxContactResults = 5
    static let maxFileResults = 10

    private let environment: ToolEnvironment
    private var executed: Set<ExecutionKey> = []

    public init(environment: ToolEnvironment) {
        self.environment = environment
    }

    // MARK: ToolExecuting

    public func executeReadOnly(_ action: ResolvedAction) async -> ToolResult {
        guard action.riskLevel == .readOnly else {
            environment.logger.log(.safety(check: "read_only_guard", outcome: "refused"))
            return finish(action.tool, .failure(ToolFailure(tool: action.tool, code: .confirmationMismatch)))
        }
        let started = ContinuousClock.now
        let result = await performChecked(action)
        return finish(action.tool, result, since: started)
    }

    public func execute(_ pending: PendingAction, token: ConfirmationToken) async -> ToolResult {
        let tool = pending.tool
        let now = environment.clock.now()

        let bound = pending.confirmationStatus == .approved
            && token.actionID == pending.id
            && token.version == pending.version
            && token.argumentsDigest == pending.argumentsDigest
            && ActionDigest.digest(of: pending.validatedArguments) == pending.argumentsDigest
            && pending.validatedArguments.tool == tool
        guard bound else {
            environment.logger.log(.safety(check: "confirmation_token", outcome: "mismatch"))
            return finish(tool, .failure(ToolFailure(tool: tool, code: .confirmationMismatch)))
        }
        guard !pending.isExpired(at: now) else {
            environment.logger.log(.safety(check: "confirmation_token", outcome: "expired"))
            return finish(tool, .failure(ToolFailure(tool: tool, code: .expired)))
        }
        // Authoritative check (same rules, evaluated by Core).
        guard pending.accepts(token, at: now) else {
            return finish(tool, .failure(ToolFailure(tool: tool, code: .confirmationMismatch)))
        }
        guard pending.riskLevel.isSupportedInV1 else {
            return finish(tool, .failure(ToolFailure(tool: tool, code: .unsupported)))
        }
        // One execution per approved version, even if the same token is presented twice.
        let key = ExecutionKey(id: pending.id, version: pending.version)
        guard executed.insert(key).inserted else {
            environment.logger.log(.safety(check: "confirmation_token", outcome: "replayed"))
            return finish(tool, .failure(ToolFailure(tool: tool, code: .confirmationMismatch)))
        }

        let started = ContinuousClock.now
        let result = await performChecked(pending.validatedArguments)
        return finish(tool, result, since: started)
    }

    // MARK: Permission re-check

    /// The permission an action needs at execution time. Calls and messages to a dictated number
    /// (no contact identifier) need none.
    static func requiredPermission(for action: ResolvedAction) -> PermissionKind? {
        switch action {
        case .searchContacts:
            return .contacts
        case let .initiateCall(target), let .composeMessage(target, _):
            return target.contactIdentifier == nil ? nil : .contacts
        case .getCalendarEvents, .createCalendarEvent, .updateCalendarEvent:
            return .calendar
        case .createReminder:
            return .reminders
        case .searchFiles, .openFile:
            return .fileScope
        case .openSupportedApp:
            return nil
        }
    }

    private func performChecked(_ action: ResolvedAction) async -> ToolResult {
        if let kind = Self.requiredPermission(for: action) {
            switch await PermissionGate.check(kind, for: action.tool, environment: environment) {
            case .proceed:
                break
            case .needsPermission(.fileScope):
                return .failure(ToolFailure(tool: action.tool, code: .noAuthorizedScope))
            case .needsPermission, .denied:
                return .failure(ToolFailure(tool: action.tool, code: .permissionDenied))
            }
        }
        return await perform(action)
    }

    // MARK: Actions

    private func perform(_ action: ResolvedAction) async -> ToolResult {
        let tool = action.tool
        func failure(_ code: ToolFailureCode) -> ToolResult { .failure(ToolFailure(tool: tool, code: code)) }

        switch action {
        case let .initiateCall(target):
            guard await environment.calls.canPlaceCalls() else { return failure(.notAvailableOnDevice) }
            // Only numbers whose dialed digits are exactly what the user saw.
            guard PhoneNumbers.isClean(target.phoneNumber), let digits = PhoneNumbers.dialable(target.phoneNumber) else {
                return failure(.invalidArguments)
            }
            return await environment.calls.startCall(toDigits: digits) ? .success(.callStarted(target)) : failure(.systemError)

        case let .composeMessage(target, body):
            guard await environment.messages.canSendText() else { return failure(.notAvailableOnDevice) }
            guard PhoneNumbers.isClean(target.phoneNumber),
                  let recipient = PhoneNumbers.dialable(target.phoneNumber),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure(.invalidArguments)
            }
            switch await environment.messages.compose(recipients: [recipient], body: body) {
            case .sent: return .success(.messageSent(target))
            case .cancelled: return .cancelledByUser(.composeMessage)
            case .unavailable: return failure(.notAvailableOnDevice)
            case .failed: return failure(.systemError)
            }

        case let .createCalendarEvent(draft):
            guard draft.endDate >= draft.startDate else { return failure(.invalidArguments) }
            do {
                return .success(.eventCreated(try await environment.calendar.createEvent(draft)))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .updateCalendarEvent(event, changes):
            guard !changes.isEmpty else { return failure(.invalidArguments) }
            do {
                return .success(.eventUpdated(try await environment.calendar.updateEvent(identifier: event.eventIdentifier, changes: changes)))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .createReminder(draft):
            do {
                _ = try await environment.reminders.createReminder(draft)
                return .success(.reminderCreated(draft))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .searchContacts(query):
            do {
                let ranked = ContactMatcher.rank(query: query, contacts: try await environment.contacts.allContacts())
                return .success(.contactsFound(ranked.prefix(Self.maxContactResults).map(\.contact.summary)))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .getCalendarEvents(range):
            guard range.end > range.start else { return failure(.invalidArguments) }
            do {
                let events = try await environment.calendar.events(in: DateInterval(start: range.start, end: range.end))
                let sorted = events.sorted { lhs, rhs in
                    if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                    if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                    return lhs.eventIdentifier < rhs.eventIdentifier
                }
                return .success(.eventsListed(sorted, range))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .searchFiles(query):
            do {
                return .success(.filesFound(try await environment.files.search(query: query, limit: Self.maxFileResults)))
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .openFile(reference):
            do {
                let url = try await environment.files.url(for: reference)
                return await environment.fileOpener.open(url) ? .success(.fileOpened(reference)) : failure(.notAvailableOnDevice)
            } catch {
                return failure(ToolAdapterError.failureCode(for: error))
            }

        case let .openSupportedApp(app, query):
            let allowedQuery = app == .maps ? AppURLBuilder.sanitizedQuery(query) : nil
            return await environment.apps.open(app, query: allowedQuery) ? .success(.appOpened(app)) : failure(.notAvailableOnDevice)
        }
    }

    // MARK: Logging

    private func finish(_ tool: ToolID, _ result: ToolResult, since start: ContinuousClock.Instant? = nil) -> ToolResult {
        let status: SafeLabel
        switch result {
        case .success: status = "succeeded"
        case .cancelledByUser: status = "cancelled"
        case let .failure(failure): status = SafeLabel(failure.code)
        }
        environment.logger.log(.toolExecution(tool: SafeLabel(tool), status: status))
        if let start {
            environment.logger.log(.stageLatency(stage: .toolExecution, milliseconds: (ContinuousClock.now - start).wholeMilliseconds))
        }
        return result
    }
}
