import Core
import Foundation
import Telemetry

/// Turns validated-for-shape but untrusted model proposals into natively resolved actions.
///
/// - Identifiers (contacts, phone numbers, events, files) come only from native stores or, for
///   dictated phone numbers, from digits verified to appear in the user's transcript.
/// - Dates are computed by Swift from the user's phrases (`DateParsing`), never by the model.
/// - Anything ambiguous, missing or not found becomes a deterministic clarification.
/// - Permissions: `.notDetermined` ⇒ `.needsPermission`; denied/restricted ⇒ `.failed(.permissionDenied)`.
///
/// Never performs side effects.
public struct ActionResolver: ActionResolving {
    let environment: ToolEnvironment

    public init(environment: ToolEnvironment) {
        self.environment = environment
    }

    public func resolve(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let outcome: ResolutionOutcome
        switch call.tool {
        case .searchContacts:
            outcome = await resolveSearchContacts(call, context: context)
        case .initiateCall:
            outcome = await resolveCommunication(call, context: context, purpose: .call)
        case .composeMessage:
            outcome = await resolveCommunication(call, context: context, purpose: .message)
        case .getCalendarEvents:
            outcome = await resolveGetCalendarEvents(call, context: context)
        case .createCalendarEvent:
            outcome = await resolveCreateCalendarEvent(call, context: context)
        case .updateCalendarEvent:
            outcome = await resolveUpdateCalendarEvent(call, context: context)
        case .createReminder:
            outcome = await resolveCreateReminder(call, context: context)
        case .searchFiles:
            outcome = await resolveSearchFiles(call, context: context)
        case .openFile:
            outcome = await resolveOpenFile(call, context: context)
        case .openSupportedApp:
            outcome = resolveOpenSupportedApp(call)
        }
        log(outcome, tool: call.tool)
        return outcome
    }

    // MARK: Shared helpers

    func clarify(
        _ reason: ClarificationReason,
        _ question: String,
        candidates: [ClarificationCandidate] = [],
        missingArgument: String?,
        call: ProposedToolCall,
        context: ResolutionContext
    ) -> ResolutionOutcome {
        .needsClarification(PendingClarification(
            reason: reason,
            question: question,
            candidates: candidates,
            partialCall: call,
            missingArgument: missingArgument,
            originalTranscript: context.transcript,
            createdAt: context.clock.now()
        ))
    }

    func clarify(_ plan: PlanClarification, call: ProposedToolCall, context: ResolutionContext) -> ResolutionOutcome {
        clarify(plan.reason, plan.question, missingArgument: plan.missingArgument, call: call, context: context)
    }

    func failed(_ tool: ToolID, _ code: ToolFailureCode) -> ResolutionOutcome {
        .failed(ToolFailure(tool: tool, code: code))
    }

    /// Checks `kind` for `tool`; nil means go ahead, otherwise the outcome to return.
    func permissionBlock(_ kind: PermissionKind, for tool: ToolID) async -> ResolutionOutcome? {
        switch await PermissionGate.check(kind, for: tool, environment: environment) {
        case .proceed: return nil
        case let .needsPermission(kind): return .needsPermission(kind)
        case .denied: return failed(tool, .permissionDenied)
        }
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// An integer argument, tolerating a numeric string or a duration phrase ("90", "an hour").
    static func integerArgument(_ call: ProposedToolCall, _ name: String, parser: any DateParsing) -> Int? {
        if let value = call.integer(name) { return value }
        guard let text = nonEmpty(call.string(name)) else { return nil }
        return Int(text) ?? parser.parseDurationMinutes(text)
    }

    func parser(for context: ResolutionContext) -> any DateParsing {
        environment.dateParser(context.clock)
    }

    private func log(_ outcome: ResolutionOutcome, tool: ToolID) {
        let status: SafeLabel
        switch outcome {
        case .resolved: status = "resolved"
        case let .needsClarification(clarification): status = SafeLabel(clarification.reason)
        case .needsPermission: status = "needs_permission"
        case let .failed(failure): status = SafeLabel(failure.code)
        }
        environment.logger.log(.toolExecution(tool: SafeLabel(tool), status: status))
    }
}
