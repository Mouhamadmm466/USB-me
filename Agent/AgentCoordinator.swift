import Core
import Foundation
import LLM
import Observation
import Permissions
import Telemetry
import Tools

/// Everything the coordinator needs, injected so the full conversation logic runs identically in
/// the app, in tests and in the evaluation harness.
public struct AgentDependencies: Sendable {
    public var languageModel: any LanguageModel
    public var resolver: any ActionResolving
    public var executor: any ToolExecuting
    public var permissions: any PermissionProviding
    public var speech: any SpeechOutput
    public var capabilities: CapabilityRegistry
    public var clock: AgentClock
    public var logger: PrivacySafeLogger
    public var metrics: PerformanceMetrics?

    public init(
        languageModel: any LanguageModel,
        resolver: any ActionResolving,
        executor: any ToolExecuting,
        permissions: any PermissionProviding,
        speech: any SpeechOutput = SilentSpeechOutput(),
        capabilities: CapabilityRegistry = .allAvailable,
        clock: AgentClock = AgentClock(),
        logger: PrivacySafeLogger = .shared,
        metrics: PerformanceMetrics? = nil
    ) {
        self.languageModel = languageModel
        self.resolver = resolver
        self.executor = executor
        self.permissions = permissions
        self.speech = speech
        self.capabilities = capabilities
        self.clock = clock
        self.logger = logger
        self.metrics = metrics
    }
}

/// The deterministic conversation brain (PRD §4–§9).
///
/// Owns the state machine and session state. The model only ever *proposes*; this class validates,
/// resolves natively, asks for confirmation bound to an exact PendingAction version, executes
/// through the tool layer and reports only what actually happened.
@MainActor
@Observable
public final class AgentCoordinator {
    public private(set) var presentation = AssistantPresentation(state: .idle)
    public private(set) var session: SessionState
    public private(set) var stateMachine: AgentStateMachine
    /// Transitions that were refused by the state machine (should always stay 0; asserted in tests).
    public private(set) var illegalTransitionCount = 0

    /// Called after every user or assistant turn (persistence hook; never logged).
    @ObservationIgnored public var onTurnRecorded: (@MainActor (ConversationTurn) -> Void)?

    @ObservationIgnored private let dependencies: AgentDependencies
    @ObservationIgnored private let configuration: AgentConfiguration
    @ObservationIgnored private let confirmation: ConfirmationManager
    @ObservationIgnored private let clarifications = ClarificationManager()
    @ObservationIgnored private let summarizer: ActionSummarizer
    @ObservationIgnored private let promptBuilder: PromptBuilder
    @ObservationIgnored private let validator = OutputValidator()
    @ObservationIgnored private var lastAssistantQuestion: String?
    @ObservationIgnored private var pinnedSelections: [String: ClarificationCandidate] = [:]
    @ObservationIgnored private var isHandlingTurn = false

    public init(
        dependencies: AgentDependencies,
        configuration: AgentConfiguration = .default,
        promptBuilder: PromptBuilder = PromptBuilder(),
        initialState: AgentState = .idle
    ) {
        self.dependencies = dependencies
        self.configuration = configuration
        self.promptBuilder = promptBuilder
        confirmation = ConfirmationManager(config: configuration.confirmation)
        summarizer = ActionSummarizer(clock: dependencies.clock)
        session = SessionState()
        stateMachine = AgentStateMachine(initial: initialState, logger: dependencies.logger)
        presentation.state = initialState
    }

    public var state: AgentState { stateMachine.current }
    public var clock: AgentClock { dependencies.clock }

    // MARK: - Lifecycle / voice-layer events

    /// Moves the machine for events owned by other layers (model manager, voice session).
    @discardableResult
    public func transition(to next: AgentState, reason: TransitionReason) -> Bool {
        guard stateMachine.current != next else { return true }
        do {
            try stateMachine.transition(to: next, reason: reason, now: dependencies.clock.now())
            presentation.state = next
            return true
        } catch {
            illegalTransitionCount += 1
            return false
        }
    }

    public func setSessionActive(_ active: Bool) {
        presentation.isSessionActive = active
    }

    public func updatePartialTranscript(_ partial: PartialTranscript?) {
        // UI-only (PRD §6.2): partial text never reaches the model, the resolver or the executor.
        presentation.partialTranscript = partial?.text
    }

    public func updateLevels(input: Float? = nil, output: Float? = nil) {
        if let input { presentation.inputLevel = input }
        if let output { presentation.outputLevel = output }
    }

    /// The state the conversation rests in between turns.
    public var restingState: AgentState {
        if let pending = session.pendingAction, pending.confirmationStatus == .pending { return .waitingForConfirmation }
        if session.clarification != nil { return .waitingForClarification }
        return .idle
    }

    public func settle(reason: TransitionReason = .speechFinished) {
        transition(to: restingState, reason: reason)
    }

    /// Clears conversational context (clear-history control).
    public func resetConversation() {
        session.reset()
        lastAssistantQuestion = nil
        pinnedSelections = [:]
        presentation.turns = []
        presentation.actionCard = nil
        presentation.clarificationChoices = []
        presentation.permissionPrompt = nil
        presentation.resultBanner = nil
        presentation.assistantText = nil
        presentation.lastUserUtterance = nil
        presentation.partialTranscript = nil
    }

    // MARK: - Turn handling

    /// Handles one finalized user utterance. Only `UserUtterance` is accepted — partial ASR
    /// hypotheses cannot enter this path.
    @discardableResult
    public func handle(_ utterance: UserUtterance) async -> TurnReport {
        var report = TurnReport()
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        presentation.partialTranscript = nil
        guard !text.isEmpty else {
            settle(reason: .emptyTranscript)
            report.outcome = .noAction
            finish(&report)
            return report
        }
        isHandlingTurn = true
        defer { isHandlingTurn = false }
        presentation.lastUserUtterance = text
        presentation.resultBanner = nil
        record(ConversationTurn(role: .user, text: text, timestamp: dependencies.clock.now()))

        if let pending = session.pendingAction, pending.confirmationStatus == .pending {
            await handleConfirmationReply(text, pending: pending, report: &report)
        } else if let clarification = session.clarification {
            await handleClarificationAnswer(text, clarification: clarification, report: &report)
        } else {
            await runModel(text, modifying: nil, report: &report)
        }
        finish(&report)
        return report
    }

    /// Visual confirmation from the action card. Must match the exact id and version shown.
    @discardableResult
    public func confirmFromCard(id: UUID, version: Int) async -> TurnReport {
        var report = TurnReport()
        guard let token = confirmation.approveFromCard(id: id, version: version, session: &session, now: dependencies.clock.now()),
              let pending = session.pendingAction else {
            dependencies.logger.log(.safety(check: "card_confirmation", outcome: "stale_or_expired"))
            report.outcome = .noAction
            finish(&report)
            return report
        }
        await dependencies.speech.stop()
        await execute(pending, token: token, report: &report)
        finish(&report)
        return report
    }

    @discardableResult
    public func cancelFromCard(id: UUID) async -> TurnReport {
        var report = TurnReport()
        guard var pending = session.pendingAction, pending.id == id else {
            report.outcome = .noAction
            finish(&report)
            return report
        }
        await dependencies.speech.stop()
        pending.reject()
        session.pendingAction = nil
        session.confirmationState = .rejected
        presentation.actionCard = nil
        report.outcome = .cancelled
        await speak(cancellationText(for: pending.tool), report: &report)
        finish(&report)
        return report
    }

    /// Tap on a clarification chip.
    @discardableResult
    public func chooseClarification(candidateID: String) async -> TurnReport {
        var report = TurnReport()
        guard let clarification = session.clarification,
              let candidate = clarification.candidates.first(where: { $0.identifier == candidateID }) else {
            report.outcome = .noAction
            finish(&report)
            return report
        }
        await dependencies.speech.stop()
        transition(to: .thinking, reason: .typedInput)
        await applyChoice(candidate, clarification: clarification, report: &report)
        finish(&report)
        return report
    }

    /// Barge-in: the voice layer detected the user talking over the assistant.
    public func userInterrupted() async {
        await dependencies.speech.stop()
    }

    // MARK: - Confirmation replies

    private func handleConfirmationReply(_ text: String, pending: PendingAction, report: inout TurnReport) async {
        let decision = confirmation.decide(reply: text, session: &session, now: dependencies.clock.now())
        dependencies.logger.log(.safety(check: "confirmation_reply", outcome: SafeLabel(ConfirmationDecisionLabel(decision))))
        switch decision {
        case let .approve(token):
            guard let approved = session.pendingAction else { return }
            await execute(approved, token: token, report: &report)
        case .reject:
            presentation.actionCard = nil
            report.outcome = .cancelled
            await speak(cancellationText(for: pending.tool), report: &report)
        case .defer_:
            report.outcome = .deferred
            await speak("Okay, take your time. Say yes when you're ready, or cancel.", report: &report)
        case let .reprompt(attempt):
            report.outcome = .reprompted
            let prompt = attempt == 1 ? repromptText(for: pending) : "Sorry, I need a yes or a no. \(repromptText(for: pending))"
            await speak(prompt, report: &report)
        case .cancelAfterUnclear:
            presentation.actionCard = nil
            report.outcome = .cancelled
            await speak("I'll cancel that for now. Just ask again when you're ready.", report: &report)
        case .expired:
            presentation.actionCard = nil
            report.outcome = .cancelled
            await speak("That request expired, so I didn't do it. Please ask again.", report: &report)
        case .modify:
            await runModel(text, modifying: pending, report: &report)
        }
    }

    private func repromptText(for pending: PendingAction) -> String {
        switch pending.tool {
        case .composeMessage: "Should I send it? Please say yes or no."
        case .initiateCall: "Should I place the call? Please say yes or no."
        case .createCalendarEvent: "Should I add it to your calendar? Please say yes or no."
        case .updateCalendarEvent: "Should I update the event? Please say yes or no."
        case .createReminder: "Should I create the reminder? Please say yes or no."
        default: "Should I go ahead? Please say yes or no."
        }
    }

    private func cancellationText(for tool: ToolID) -> String {
        switch tool {
        case .composeMessage: "Okay, I won't send it."
        case .initiateCall: "Okay, I won't call."
        case .createCalendarEvent: "Okay, I won't add it."
        case .updateCalendarEvent: "Okay, I'll leave the event as it is."
        case .createReminder: "Okay, no reminder."
        default: "Okay, cancelled."
        }
    }

    // MARK: - Clarification answers

    private func handleClarificationAnswer(_ text: String, clarification: PendingClarification, report: inout TurnReport) async {
        switch clarifications.interpret(text, for: clarification) {
        case .cancel:
            session.clarification = nil
            pinnedSelections = [:]
            presentation.clarificationChoices = []
            report.outcome = .cancelled
            await speak("Okay, never mind.", report: &report)
        case let .choose(candidate):
            transition(to: .thinking, reason: .transcriptReady)
            await applyChoice(candidate, clarification: clarification, report: &report)
        case let .fill(argument, value):
            guard let call = clarification.partialCall else {
                session.clarification = nil
                await runModel(text, modifying: nil, report: &report)
                return
            }
            var arguments = call.arguments
            arguments[argument] = .string(value)
            switch validator.validateArguments(arguments.mapValues(Self.strictJSON), for: ToolCatalog.spec(for: call.tool)) {
            case let .success(filled):
                session.clarification = nil
                presentation.clarificationChoices = []
                transition(to: .thinking, reason: .transcriptReady)
                await resolveAndAct(filled, transcript: clarification.originalTranscript + " " + text, modifying: nil, report: &report)
            case .failure:
                report.outcome = .clarificationRequested
                report.clarification = clarification
                await speak(clarification.question, report: &report)
            }
        case let .stillAmbiguous(candidates):
            let narrowed = PendingClarification(
                reason: clarification.reason,
                question: "Which one: " + summarizer.list(candidates.map(\.displayText)) + "?",
                candidates: candidates,
                partialCall: clarification.partialCall,
                missingArgument: clarification.missingArgument,
                originalTranscript: clarification.originalTranscript,
                createdAt: dependencies.clock.now()
            )
            session.clarification = narrowed
            presentation.clarificationChoices = choices(for: narrowed)
            report.outcome = .clarificationRequested
            report.clarification = narrowed
            lastAssistantQuestion = narrowed.question
            await speak(narrowed.question, report: &report)
        case .notAnAnswer:
            if clarification.reason != .modelQuestion {
                // Not an answer to our question: treat it as a fresh request.
                session.clarification = nil
                pinnedSelections = [:]
                presentation.clarificationChoices = []
            } else {
                session.clarification = nil
            }
            await runModel(text, modifying: nil, report: &report)
        }
    }

    private func applyChoice(_ candidate: ClarificationCandidate, clarification: PendingClarification, report: inout TurnReport) async {
        guard let call = clarification.partialCall else {
            session.clarification = nil
            report.outcome = .noAction
            settle()
            return
        }
        let argument: String
        switch clarification.reason {
        case .contactAmbiguous: argument = call.tool == .searchContacts ? "name" : "contact_query"
        case .phoneNumberAmbiguous: argument = "phone"
        case .eventAmbiguous: argument = "event_query"
        case .fileAmbiguous: argument = "file_query"
        default: argument = candidate.kind.rawValue
        }
        pinnedSelections[argument] = candidate
        session.clarification = nil
        presentation.clarificationChoices = []
        await resolveAndAct(call, transcript: clarification.originalTranscript, modifying: nil, report: &report)
    }

    // MARK: - Model

    private func runModel(_ text: String, modifying pending: PendingAction?, report: inout TurnReport) async {
        transition(to: .thinking, reason: pending == nil ? .transcriptReady : .userModified)
        let request = promptBuilder.request(
            session: session,
            utterance: text,
            clock: dependencies.clock,
            lastAssistantQuestion: lastAssistantQuestion,
            maxOutputTokens: configuration.llm.maxOutputTokens
        )
        var output = ""
        let watch = Stopwatch()
        do {
            for try await event in dependencies.languageModel.generate(request) {
                if case let .text(delta) = event { output += delta }
            }
        } catch {
            dependencies.logger.log(.error(domain: "llm", code: "generation_failed"))
            report.modelOutputs.append(output)
            report.outcome = pending == nil ? .noAction : .reprompted
            await speak("Sorry, something went wrong on my side. Could you say that again?", report: &report)
            return
        }
        report.modelMilliseconds += watch.elapsedMilliseconds
        report.modelOutputs.append(output)
        await dependencies.metrics?.record(.llmTotal, milliseconds: watch.elapsedMilliseconds)
        lastAssistantQuestion = nil

        switch validator.validate(output) {
        case let .failure(error):
            report.validationErrors.append(error)
            dependencies.logger.log(.safety(check: "model_output_rejected", outcome: error.code))
            if let pending {
                report.outcome = .reprompted
                await speak("Sorry, I didn't get the change. \(repromptText(for: pending))", report: &report)
                return
            }
            if case .emptyValue("message") = error {
                await askModelQuestion("What should the message say?", report: &report)
                return
            }
            report.outcome = .noAction
            await speak("Sorry, I didn't catch that. Could you say it again?", report: &report)

        case let .success(.answer(speech)):
            if let pending {
                report.outcome = .reprompted
                await speak(speech + " " + repromptText(for: pending), report: &report)
            } else {
                report.outcome = .answered
                await speak(speech, report: &report)
            }

        case let .success(.clarification(speech)):
            if pending != nil {
                report.outcome = .clarificationRequested
                lastAssistantQuestion = speech
                await speak(speech, report: &report)
            } else {
                await askModelQuestion(speech, report: &report)
            }

        case let .success(.unsupported(speech)):
            if let pending {
                report.outcome = .reprompted
                await speak(speech + " " + repromptText(for: pending), report: &report)
            } else {
                report.outcome = .unsupported
                await speak(speech, report: &report)
            }

        case let .success(.proposedAction(call, _)):
            pinnedSelections = [:]
            await resolveAndAct(call, transcript: text, modifying: pending, report: &report)
        }
    }

    private func askModelQuestion(_ question: String, report: inout TurnReport) async {
        let clarification = PendingClarification(
            reason: .modelQuestion,
            question: question,
            originalTranscript: session.recentTurns.last(where: { $0.role == .user })?.text ?? "",
            createdAt: dependencies.clock.now()
        )
        session.clarification = clarification
        lastAssistantQuestion = question
        report.outcome = .clarificationRequested
        report.clarification = clarification
        await speak(question, report: &report)
    }

    // MARK: - Resolution and action

    private func resolveAndAct(_ call: ProposedToolCall, transcript: String, modifying pending: PendingAction?, report: inout TurnReport) async {
        if let unavailable = await dependencies.capabilities.unavailability(for: call.tool) {
            report.outcome = pending == nil ? .unsupported : .reprompted
            var text = summarizer.failureSpeech(unavailable)
            if let pending { text += " " + repromptText(for: pending) }
            await speak(text, report: &report)
            return
        }

        let watch = Stopwatch()
        var outcome = await dependencies.resolver.resolve(call, context: resolutionContext(transcript))
        if case let .needsPermission(kind) = outcome {
            transition(to: .permissionRequired, reason: .permissionNeeded)
            presentation.permissionPrompt = permissionPrompt(kind, requiresSettings: false)
            let status = await dependencies.permissions.request(kind)
            if PermissionManager.isUsable(status, for: kind) {
                presentation.permissionPrompt = nil
                transition(to: .thinking, reason: .permissionResolved)
                outcome = await dependencies.resolver.resolve(call, context: resolutionContext(transcript))
            } else {
                outcome = kind == .fileScope ? .needsPermission(kind) : .failed(ToolFailure(tool: call.tool, code: .permissionDenied))
            }
        }
        await dependencies.metrics?.record(.contactResolution, milliseconds: watch.elapsedMilliseconds)

        switch outcome {
        case let .needsPermission(kind):
            presentation.permissionPrompt = permissionPrompt(kind, requiresSettings: kind != .fileScope)
            report.outcome = .permissionRequired
            let text = kind == .fileScope
                ? "Choose a folder to share with me first. You can do that in Settings, under Files."
                : summarizer.failureSpeech(ToolFailure(tool: call.tool, code: .permissionDenied))
            await speak(text, report: &report)

        case let .failed(failure):
            if failure.code == .permissionDenied {
                presentation.permissionPrompt = permissionPrompt(ToolCatalog.spec(for: call.tool).requiredPermissions.first ?? .contacts, requiresSettings: true)
                report.outcome = .permissionRequired
            } else {
                report.outcome = pending == nil ? .unsupported : .reprompted
            }
            var text = summarizer.failureSpeech(failure)
            if let pending, failure.code != .permissionDenied { text += " " + repromptText(for: pending) }
            await speak(text, report: &report)

        case let .needsClarification(clarification):
            if pending != nil {
                // The requested change needs more detail; the old version is superseded.
                session.pendingAction = nil
                session.confirmationState = .none
                presentation.actionCard = nil
            }
            session.clarification = clarification
            presentation.clarificationChoices = choices(for: clarification)
            lastAssistantQuestion = clarification.question
            report.outcome = .clarificationRequested
            report.clarification = clarification
            await speak(clarification.question, report: &report)

        case let .resolved(action):
            rememberEntities(from: action)
            if action.riskLevel == .readOnly {
                await executeReadOnly(action, report: &report)
                if let pending, session.pendingAction?.id == pending.id {
                    // Still waiting on the earlier action.
                    report.pendingAction = session.pendingAction
                }
            } else {
                propose(action, transcript: transcript, replacing: pending, report: &report)
                await speak(summarizer.confirmationPrompt(for: action), report: &report)
            }
        }
    }

    private func propose(_ action: ResolvedAction, transcript: String, replacing previous: PendingAction?, report: inout TurnReport) {
        let now = dependencies.clock.now()
        let lifetime = configuration.confirmation.pendingActionLifetimeSeconds
        let summary = summarizer.confirmationPrompt(for: action)
        let pending: PendingAction
        if let previous, previous.tool == action.tool {
            pending = previous.revised(action: action, humanReadableSummary: summary, originalTranscript: transcript, now: now, lifetime: lifetime)
        } else {
            pending = PendingAction(action: action, humanReadableSummary: summary, originalTranscript: transcript, createdAt: now, lifetime: lifetime)
        }
        session.pendingAction = pending
        session.confirmationState = .awaitingResponse(reprompts: 0)
        session.clarification = nil
        session.currentGoal = summary
        pinnedSelections = [:]
        presentation.actionCard = summarizer.actionCard(for: pending)
        presentation.clarificationChoices = []
        report.outcome = .confirmationRequested
        report.pendingAction = pending
        dependencies.logger.log(.safety(check: "pending_action_created", outcome: SafeLabel(action.riskLevel)))
    }

    private func executeReadOnly(_ action: ResolvedAction, report: inout TurnReport) async {
        transition(to: .executing, reason: .autoExecuteReadOnly)
        let watch = Stopwatch()
        let result = await dependencies.executor.executeReadOnly(action)
        await dependencies.metrics?.record(.toolExecution, milliseconds: watch.elapsedMilliseconds)
        report.executions.append(.init(action: action, result: result, consequential: false))
        recordResult(result, for: action)
        report.outcome = .executed
        await speak(summarizer.resultSpeech(result, for: action), report: &report, reporting: true)
    }

    private func execute(_ pending: PendingAction, token: ConfirmationToken, report: inout TurnReport) async {
        transition(to: .executing, reason: .userApproved)
        let watch = Stopwatch()
        let result = await dependencies.executor.execute(pending, token: token)
        await dependencies.metrics?.record(.toolExecution, milliseconds: watch.elapsedMilliseconds)
        report.executions.append(.init(action: pending.validatedArguments, result: result, consequential: true))
        session.pendingAction = nil
        session.confirmationState = .none
        session.currentGoal = nil
        presentation.actionCard = nil
        recordResult(result, for: pending.validatedArguments)
        switch result {
        case .success, .cancelledByUser:
            report.outcome = .executed
        case let .failure(failure):
            report.outcome = failure.code == .permissionDenied ? .permissionRequired : .executed
            if failure.code == .permissionDenied {
                presentation.permissionPrompt = permissionPrompt(ToolCatalog.spec(for: pending.tool).requiredPermissions.first ?? .contacts, requiresSettings: true)
            }
        }
        dependencies.logger.log(.toolExecution(tool: SafeLabel(pending.tool), status: result.succeeded ? "success" : "not_completed"))
        await speak(summarizer.resultSpeech(result, for: pending.validatedArguments), report: &report, reporting: true)
    }

    private func recordResult(_ result: ToolResult, for action: ResolvedAction) {
        session.lastToolResult = ToolResultSummary(tool: action.tool, succeeded: result.succeeded, at: dependencies.clock.now())
        presentation.resultBanner = summarizer.resultBanner(result, for: action)
        guard case let .success(outcome) = result else { return }
        switch outcome {
        case let .contactsFound(contacts) where contacts.count == 1:
            let reference = ContactReference(contactIdentifier: contacts[0].contactIdentifier, displayName: contacts[0].displayName)
            session.lastContact = reference
            session.resolvedEntities.remember(contact: reference)
        case let .eventsListed(events, _) where events.count == 1:
            session.lastCalendarEvent = events[0]
            session.resolvedEntities.remember(event: events[0])
        case let .eventCreated(event), let .eventUpdated(event):
            session.lastCalendarEvent = event
            session.resolvedEntities.remember(event: event)
        case let .fileOpened(reference):
            session.resolvedEntities.remember(file: reference)
        default:
            break
        }
    }

    private func rememberEntities(from action: ResolvedAction) {
        switch action {
        case let .initiateCall(target), let .composeMessage(target, _):
            if let identifier = target.contactIdentifier {
                let reference = ContactReference(contactIdentifier: identifier, displayName: target.displayName)
                session.lastContact = reference
                session.resolvedEntities.remember(contact: reference)
            }
        case let .updateCalendarEvent(event, _):
            session.lastCalendarEvent = event
            session.resolvedEntities.remember(event: event)
        default:
            break
        }
    }

    private func resolutionContext(_ transcript: String) -> ResolutionContext {
        ResolutionContext(transcript: transcript, session: session, clock: dependencies.clock, pinnedSelections: pinnedSelections)
    }

    // MARK: - Speaking

    /// Speaks and moves to the resting state. Returns false if the user barged in.
    @discardableResult
    private func speak(_ text: String, report: inout TurnReport, reporting: Bool = false) async -> Bool {
        report.spokenText = report.spokenText.isEmpty ? text : report.spokenText + " " + text
        presentation.assistantText = text
        record(ConversationTurn(role: .assistant, text: text, timestamp: dependencies.clock.now()))
        transition(to: reporting ? .reportingResult : .speaking, reason: reporting ? .toolFinished : .agentAnswered)
        let result = await dependencies.speech.speak(text)
        if result == .interrupted {
            report.interrupted = true
            transition(to: .interrupted, reason: .bargeIn)
            return false
        }
        settle()
        return true
    }

    private func record(_ turn: ConversationTurn) {
        session.append(turn)
        presentation.turns.append(turn)
        if presentation.turns.count > 40 { presentation.turns.removeFirst(presentation.turns.count - 40) }
        onTurnRecorded?(turn)
    }

    private func finish(_ report: inout TurnReport) {
        report.pendingAction = session.pendingAction.flatMap { $0.confirmationStatus == .pending ? $0 : nil }
        if report.clarification == nil { report.clarification = session.clarification }
    }

    private func choices(for clarification: PendingClarification) -> [ClarificationChoice] {
        clarification.candidates.map { candidate in
            let subtitle = candidate.matchTerms.first { !candidate.displayText.localizedCaseInsensitiveContains($0) }
            return ClarificationChoice(id: candidate.identifier, title: candidate.displayText, subtitle: subtitle)
        }
    }

    private func permissionPrompt(_ kind: PermissionKind, requiresSettings: Bool) -> PermissionPrompt {
        let (title, message): (String, String) = switch kind {
        case .microphone: ("Microphone access", "Voice Agent needs the microphone to hear you. Audio stays on this iPhone.")
        case .contacts: ("Contacts access", "To call or message people, Voice Agent needs to look them up in your contacts.")
        case .calendar: ("Calendar access", "To read and change events, Voice Agent needs access to your calendar.")
        case .reminders: ("Reminders access", "To create reminders, Voice Agent needs access to Reminders.")
        case .fileScope: ("Share a folder", "Choose a folder in Settings so Voice Agent can search and open files in it.")
        }
        return PermissionPrompt(kind: kind, title: title, message: message, requiresSettings: requiresSettings)
    }

    static func strictJSON(_ value: ToolArgumentValue) -> StrictJSON {
        switch value {
        case let .string(string): .string(string)
        case let .integer(integer): .integer(integer)
        }
    }
}

/// Privacy-safe label for confirmation decisions.
struct ConfirmationDecisionLabel: SafeLabelConvertible {
    let decision: ConfirmationManager.Decision

    init(_ decision: ConfirmationManager.Decision) { self.decision = decision }

    var safeLabelText: String {
        switch decision {
        case .approve: "approve"
        case .reject: "reject"
        case .defer_: "defer"
        case .modify: "modify"
        case .reprompt: "reprompt"
        case .cancelAfterUnclear: "cancel_after_unclear"
        case .expired: "expired"
        }
    }
}
