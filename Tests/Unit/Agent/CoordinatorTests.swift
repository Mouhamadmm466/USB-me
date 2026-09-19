import AgentEval
import Core
import Foundation
import LLM
import Permissions
import Testing
import Tools
@testable import Agent

// MARK: - Test doubles

final class StubResolver: ActionResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ProposedToolCall, ResolutionContext) -> ResolutionOutcome
    private var _calls: [(ProposedToolCall, ResolutionContext)] = []

    init(_ handler: @escaping @Sendable (ProposedToolCall, ResolutionContext) -> ResolutionOutcome) {
        self.handler = handler
    }

    var calls: [(ProposedToolCall, ResolutionContext)] { lock.lock(); defer { lock.unlock() }; return _calls }

    func resolve(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        lock.withLock { _calls.append((call, context)) }
        return handler(call, context)
    }
}

/// Executes nothing real; validates tokens exactly like the production executor must.
final class RecordingExecutor: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sideEffects: [ResolvedAction] = []
    private var _readOnly: [ResolvedAction] = []
    let clock: AgentClock
    var composeResult: ToolResult?

    init(clock: AgentClock) { self.clock = clock }

    var sideEffects: [ResolvedAction] { lock.lock(); defer { lock.unlock() }; return _sideEffects }
    var readOnly: [ResolvedAction] { lock.lock(); defer { lock.unlock() }; return _readOnly }

    func executeReadOnly(_ action: ResolvedAction) async -> ToolResult {
        guard action.riskLevel == .readOnly else { return .failure(ToolFailure(tool: action.tool, code: .confirmationMismatch)) }
        lock.withLock { _readOnly.append(action) }
        switch action {
        case let .getCalendarEvents(range): return .success(.eventsListed([], range))
        case .searchContacts: return .success(.contactsFound([]))
        case let .openSupportedApp(app, _): return .success(.appOpened(app))
        default: return .success(.filesFound([]))
        }
    }

    func execute(_ action: PendingAction, token: ConfirmationToken) async -> ToolResult {
        guard action.accepts(token, at: clock.now()) else {
            return .failure(ToolFailure(tool: action.tool, code: .confirmationMismatch))
        }
        lock.withLock { _sideEffects.append(action.validatedArguments) }
        switch action.validatedArguments {
        case let .composeMessage(target, _): return composeResult ?? .success(.messageSent(target))
        case let .initiateCall(target): return .success(.callStarted(target))
        case let .createReminder(draft): return .success(.reminderCreated(draft))
        case let .createCalendarEvent(draft):
            return .success(.eventCreated(EventReference(eventIdentifier: "new", title: draft.title, startDate: draft.startDate, endDate: draft.endDate)))
        case let .updateCalendarEvent(event, _): return .success(.eventUpdated(event))
        default: return .failure(ToolFailure(tool: action.tool, code: .unsupported))
        }
    }
}

final class RecordingSpeech: SpeechOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    var interruptNext = false

    var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }

    func speak(_ text: String) async -> SpeechOutputResult {
        lock.withLock {
            _spoken.append(text)
            if interruptNext { interruptNext = false; return .interrupted }
            return .finished
        }
    }

    func stop() async {}

    private var _leads: [String] = []
    var leads: [String] { lock.withLock { _leads } }

    func speakLead(_ lead: String) async {
        lock.withLock { _leads.append(lead) }
    }
}

// MARK: - Fixtures

let alexKim = ContactTarget(contactIdentifier: "c-alex-kim", displayName: "Alex Kim", phoneNumber: "+15550101001", phoneLabel: "mobile")

let composeJSON = #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"I'll be 20 minutes late."},"requires_confirmation":true}"#

@MainActor
func makeCoordinator(
    model: ScriptedLanguageModel,
    resolver: StubResolver? = nil,
    permissions: FakePermissionBackend = .allGranted(),
    capabilities: DeviceCapabilities = .allAvailable,
    now: Date = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!,
    speech: RecordingSpeech = RecordingSpeech()
) -> (AgentCoordinator, RecordingExecutor, StubResolver, RecordingSpeech) {
    let clock = AgentClock.fixed(now, timeZone: TimeZone(identifier: "America/New_York")!)
    let executor = RecordingExecutor(clock: clock)
    let stub = resolver ?? StubResolver { call, _ in
        switch call.tool {
        case .composeMessage:
            return .resolved(.composeMessage(alexKim, body: call.string("message") ?? ""))
        case .initiateCall:
            return .resolved(.initiateCall(alexKim))
        case .getCalendarEvents:
            return .resolved(.getCalendarEvents(DateRange(start: clock.now(), end: clock.now().addingTimeInterval(86_400), spokenDescription: "tomorrow")))
        case .createReminder:
            return .resolved(.createReminder(ReminderDraft(title: call.string("title") ?? "", dueDate: nil, dueHasTime: false)))
        default:
            return .failed(ToolFailure(tool: call.tool, code: .unsupported))
        }
    }
    let dependencies = AgentDependencies(
        languageModel: model,
        resolver: stub,
        executor: executor,
        permissions: PermissionManager(backend: permissions),
        speech: speech,
        capabilities: capabilities,
        clock: clock
    )
    return (AgentCoordinator(dependencies: dependencies), executor, stub, speech)
}

// MARK: - Tests

@MainActor
@Suite struct ConfirmationLeadCoordinatorTests {
    @Test func messageLeadIsSpokenBeforeTheConfirmationAndMatchesItsStart() async {
        let model = ScriptedLanguageModel(["Text Alex that I will be 20 minutes late": composeJSON])
        let (coordinator, executor, _, speech) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("Text Alex that I will be 20 minutes late"))
        #expect(report.outcome == .confirmationRequested)
        #expect(speech.leads == ["Text Alex Kim:"])
        #expect(speech.spoken.last?.hasPrefix("Text Alex Kim:") == true)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func noLeadWhenContactsAreNotAllowedYet() async {
        let model = ScriptedLanguageModel(["Text Alex that I will be 20 minutes late": composeJSON])
        let (coordinator, _, _, speech) = makeCoordinator(model: model, permissions: FakePermissionBackend(statuses: [:], responses: [.contacts: .granted]))
        _ = await coordinator.handle(.typed("Text Alex that I will be 20 minutes late"))
        #expect(speech.leads.isEmpty, "the lead-in never triggers a permission prompt")
    }

    @Test func noLeadForAmbiguousRecipients() async {
        let candidates = [
            ClarificationCandidate(kind: .contact, identifier: "c-alex-kim", displayText: "Alex Kim", matchTerms: ["Kim"]),
            ClarificationCandidate(kind: .contact, identifier: "c-alex-chen", displayText: "Alex Chen", matchTerms: ["Chen"]),
        ]
        let resolver = StubResolver { call, context in
            .needsClarification(PendingClarification(
                reason: .contactAmbiguous, question: "I found Alex Kim and Alex Chen. Which one?", candidates: candidates,
                partialCall: call, originalTranscript: context.transcript, createdAt: context.clock.now()))
        }
        let model = ScriptedLanguageModel(["Text Alex that I will be 20 minutes late": composeJSON])
        let (coordinator, _, _, speech) = makeCoordinator(model: model, resolver: resolver)
        _ = await coordinator.handle(.typed("Text Alex that I will be 20 minutes late"))
        #expect(speech.leads.isEmpty)
    }
}

@MainActor
@Suite struct PrimingTests {
    private func primeAndWait(_ coordinator: AgentCoordinator, _ model: ScriptedLanguageModel) async {
        let before = model.primedHeads.count
        coordinator.primeLanguageModel()
        for _ in 0..<200 where model.primedHeads.count == before { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func primedContextIsExactlyTheStartOfTheNextRequest() async throws {
        let correction = #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"I'll be 30 minutes late."},"requires_confirmation":true}"#
        let model = ScriptedLanguageModel([
            "Text Alex that I will be 20 minutes late": composeJSON,
            "actually make it 30 minutes": correction,
        ])
        let (coordinator, _, _, _) = makeCoordinator(model: model)

        await primeAndWait(coordinator, model)
        _ = await coordinator.handle(.speech(FinalTranscript(text: "Text Alex that I will be 20 minutes late", audioDurationSeconds: 2)))
        let firstHead = try #require(model.primedHeads.last)
        #expect(model.requests.last?.suffix.hasPrefix(firstHead) == true, "head: \(firstHead)\nsuffix: \(model.requests.last?.suffix ?? "")")

        // Second turn: a pending action, the confirmation question and the last contact are in context.
        await primeAndWait(coordinator, model)
        _ = await coordinator.handle(.speech(FinalTranscript(text: "actually make it 30 minutes", audioDurationSeconds: 2)))
        let secondHead = try #require(model.primedHeads.last)
        #expect(secondHead.contains("Pending action"))
        #expect(model.requests.last?.suffix.hasPrefix(secondHead) == true)
        #expect(model.requests.count == 2)
    }
}

@MainActor
@Suite struct CoordinatorTests {
    @Test func canonicalMessageFlowConfirmsThenExecutesExactlyOnce() async throws {
        let model = ScriptedLanguageModel(["Text Alex that I will be 20 minutes late": composeJSON])
        let (coordinator, executor, _, speech) = makeCoordinator(model: model)

        let first = await coordinator.handle(.typed("Text Alex that I will be 20 minutes late"))
        #expect(first.outcome == .confirmationRequested)
        #expect(executor.sideEffects.isEmpty)
        #expect(coordinator.state == .waitingForConfirmation)
        let card = try #require(coordinator.presentation.actionCard)
        #expect(card.fields.contains(.init(label: "To", value: "Alex Kim")))
        #expect(card.fields.contains(.init(label: "Message", value: "I'll be 20 minutes late.")))
        #expect(speech.spoken.last?.contains("Alex Kim") == true)
        #expect(speech.spoken.last?.contains("I'll be 20 minutes late.") == true)

        let second = await coordinator.handle(.typed("yes"))
        #expect(second.outcome == .executed)
        #expect(executor.sideEffects.count == 1)
        #expect(coordinator.presentation.actionCard == nil)
        #expect(coordinator.state == .idle)
        #expect(coordinator.illegalTransitionCount == 0)
        // The confirmation reply never reached the model.
        #expect(model.requests.count == 1)
    }

    @Test func rejectionExecutesNothing() async {
        let model = ScriptedLanguageModel(["text alex i'm late": composeJSON])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("text alex i'm late"))
        let report = await coordinator.handle(.typed("no, don't send it"))
        #expect(report.outcome == .cancelled)
        #expect(executor.sideEffects.isEmpty)
        #expect(coordinator.session.pendingAction == nil)
        #expect(coordinator.state == .idle)
    }

    @Test func modificationCreatesNewVersionAndRequiresReconfirmation() async throws {
        let revised = #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex Kim","message":"I'll be 30 minutes late."},"requires_confirmation":true}"#
        let model = ScriptedLanguageModel([
            "text alex i'm 20 minutes late": composeJSON,
            "yes but make it 30 minutes": revised,
        ])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        let first = await coordinator.handle(.typed("text alex i'm 20 minutes late"))
        let v1 = try #require(first.pendingAction)
        let second = await coordinator.handle(.typed("yes but make it 30 minutes"))
        #expect(second.outcome == .confirmationRequested)
        let v2 = try #require(second.pendingAction)
        #expect(v2.id == v1.id)
        #expect(v2.version == 2)
        #expect(v2.confirmationStatus == .pending)
        #expect(executor.sideEffects.isEmpty)
        // The model saw the pending action in its context.
        #expect(model.requests.last?.suffix.contains("Pending action") == true)
        // A stale card tap for version 1 does nothing.
        let stale = await coordinator.confirmFromCard(id: v1.id, version: 1)
        #expect(stale.outcome == .noAction)
        #expect(executor.sideEffects.isEmpty)
        let third = await coordinator.handle(.typed("yes"))
        #expect(third.outcome == .executed)
        #expect(executor.sideEffects == [.composeMessage(alexKim, body: "I'll be 30 minutes late.")])
    }

    @Test func unclearRepliesRepromptThenCancel() async {
        let model = ScriptedLanguageModel(["text alex hi": composeJSON])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("text alex hi"))
        #expect(await coordinator.handle(.typed("hmm")).outcome == .reprompted)
        #expect(await coordinator.handle(.typed("yes no")).outcome == .reprompted)
        #expect(await coordinator.handle(.typed("I don't know")).outcome == .cancelled)
        #expect(executor.sideEffects.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test func deferKeepsActionPending() async {
        let model = ScriptedLanguageModel(["text alex hi": composeJSON])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("text alex hi"))
        #expect(await coordinator.handle(.typed("wait")).outcome == .deferred)
        #expect(coordinator.session.pendingAction != nil)
        #expect(coordinator.state == .waitingForConfirmation)
        #expect(await coordinator.handle(.typed("okay go ahead")).outcome == .executed)
        #expect(executor.sideEffects.count == 1)
    }

    @Test func cardConfirmationExecutesCurrentVersion() async throws {
        let model = ScriptedLanguageModel(["text alex hi": composeJSON])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("text alex hi"))
        let pending = try #require(report.pendingAction)
        #expect(await coordinator.confirmFromCard(id: UUID(), version: 1).outcome == .noAction)
        #expect(executor.sideEffects.isEmpty)
        #expect(await coordinator.confirmFromCard(id: pending.id, version: pending.version).outcome == .executed)
        #expect(executor.sideEffects.count == 1)
        // A second tap cannot execute again.
        #expect(await coordinator.confirmFromCard(id: pending.id, version: pending.version).outcome == .noAction)
        #expect(executor.sideEffects.count == 1)
    }

    @Test func expiredActionIsNotExecuted() async {
        let model = ScriptedLanguageModel(["text alex hi": composeJSON])
        var current = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!
        let box = DateBox(current)
        let clock = AgentClock(now: { box.value }, calendar: Calendar(identifier: .gregorian))
        let executor = RecordingExecutor(clock: clock)
        let coordinator = AgentCoordinator(dependencies: AgentDependencies(
            languageModel: model,
            resolver: StubResolver { call, _ in .resolved(.composeMessage(alexKim, body: call.string("message") ?? "")) },
            executor: executor,
            permissions: PermissionManager(backend: FakePermissionBackend.allGranted()),
            clock: clock
        ))
        _ = await coordinator.handle(.typed("text alex hi"))
        current = current.addingTimeInterval(121)
        box.value = current
        let report = await coordinator.handle(.typed("yes"))
        #expect(report.outcome == .cancelled)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func modelCannotSkipConfirmationByClaimingItIsNotNeeded() async {
        let sneaky = #"{"type":"proposed_action","tool":"initiate_call","arguments":{"contact_query":"Alex"},"requires_confirmation":false}"#
        let model = ScriptedLanguageModel(["call alex": sneaky])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("call alex"))
        #expect(report.outcome == .confirmationRequested)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func readOnlyToolRunsWithoutConfirmation() async {
        let model = ScriptedLanguageModel(["what's on my calendar tomorrow": #"{"type":"proposed_action","tool":"get_calendar_events","arguments":{"when":"tomorrow"},"requires_confirmation":false}"#])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("what's on my calendar tomorrow"))
        #expect(report.outcome == .executed)
        #expect(executor.readOnly.count == 1)
        #expect(executor.sideEffects.isEmpty)
        #expect(report.spokenText.contains("nothing on your calendar"))
    }

    @Test(arguments: [
        "not json at all",
        #"{"type":"proposed_action","tool":"send_email","arguments":{"to":"boss"},"requires_confirmation":true}"#,
        #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"hi","contact_id":"123"},"requires_confirmation":true}"#,
        #"{"type":"execute","speech":"done"}"#,
    ])
    func invalidModelOutputNeverExecutes(output: String) async {
        let model = ScriptedLanguageModel { _ in output }
        let (coordinator, executor, resolver, _) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("do something"))
        #expect(report.outcome == .noAction)
        #expect(!report.validationErrors.isEmpty)
        #expect(executor.sideEffects.isEmpty)
        // Only the read-only lead-in probe (recipient lookup while the body is generated) may run.
        #expect(resolver.calls.allSatisfy { $0.0.string("message") == ConfirmationLead.placeholderMessage })
        #expect(report.pendingAction == nil)
        #expect(coordinator.state == .idle)
    }

    @Test func ambiguousContactClarificationThenChoice() async {
        let candidates = [
            ClarificationCandidate(kind: .contact, identifier: "c-alex-kim", displayText: "Alex Kim", matchTerms: ["Kim"]),
            ClarificationCandidate(kind: .contact, identifier: "c-alex-chen", displayText: "Alex Chen", matchTerms: ["Chen"]),
        ]
        let resolver = StubResolver { call, context in
            if let pinned = context.pinnedSelections["contact_query"] {
                let target = ContactTarget(contactIdentifier: pinned.identifier, displayName: pinned.displayText, phoneNumber: "+15550000000", phoneLabel: "mobile")
                return .resolved(.composeMessage(target, body: call.string("message") ?? ""))
            }
            return .needsClarification(PendingClarification(
                reason: .contactAmbiguous, question: "I found Alex Kim and Alex Chen. Which one?", candidates: candidates,
                partialCall: call, originalTranscript: context.transcript, createdAt: context.clock.now()))
        }
        let model = ScriptedLanguageModel(["text alex hi": composeJSON])
        let (coordinator, executor, _, _) = makeCoordinator(model: model, resolver: resolver)
        let first = await coordinator.handle(.typed("text alex hi"))
        #expect(first.outcome == .clarificationRequested)
        #expect(coordinator.presentation.clarificationChoices.map(\.id) == ["c-alex-kim", "c-alex-chen"])
        #expect(coordinator.state == .waitingForClarification)
        let second = await coordinator.handle(.typed("the second one"))
        #expect(second.outcome == .confirmationRequested)
        if case let .composeMessage(target, _)? = second.pendingAction?.validatedArguments {
            #expect(target.contactIdentifier == "c-alex-chen")
        } else {
            Issue.record("expected compose message")
        }
        #expect(model.requests.count == 1) // the answer was resolved deterministically
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func clarificationCanBeCancelled() async {
        let resolver = StubResolver { call, context in
            .needsClarification(PendingClarification(reason: .contactNotFound, question: "Who?", partialCall: call, originalTranscript: context.transcript, createdAt: context.clock.now()))
        }
        let (coordinator, executor, _, _) = makeCoordinator(model: ScriptedLanguageModel(["text zed hi": composeJSON]), resolver: resolver)
        _ = await coordinator.handle(.typed("text zed hi"))
        #expect(await coordinator.handle(.typed("never mind")).outcome == .cancelled)
        #expect(coordinator.session.clarification == nil)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func permissionRequestedJustInTimeAndDenialIsReported() async {
        let backend = FakePermissionBackend(statuses: [:], responses: [.contacts: .denied])
        let resolver = StubResolver { _, _ in .needsPermission(.contacts) }
        let (coordinator, executor, _, _) = makeCoordinator(model: ScriptedLanguageModel(["text alex hi": composeJSON]), resolver: resolver, permissions: backend)
        let report = await coordinator.handle(.typed("text alex hi"))
        #expect(report.outcome == .permissionRequired)
        #expect(coordinator.presentation.permissionPrompt?.requiresSettings == true)
        #expect(await backend.requestCounts[.contacts] == 1)
        #expect(executor.sideEffects.isEmpty)
        // Asking again does not loop the system prompt.
        _ = await coordinator.handle(.typed("text alex hi"))
        #expect(await backend.requestCounts[.contacts] == 1)
    }

    @Test func permissionGrantedContinuesTheRequest() async {
        let backend = FakePermissionBackend(statuses: [:], responses: [.contacts: .granted])
        let (coordinator, _, _, _) = makeCoordinator(model: ScriptedLanguageModel(["text alex hi": composeJSON]), resolver: permissionGatedResolver(), permissions: backend)
        let report = await coordinator.handle(.typed("text alex hi"))
        #expect(report.outcome == .confirmationRequested)
        #expect(await backend.requestCounts[.contacts] == 1)
    }

    @Test func unavailableCapabilityNeverCreatesPendingAction() async {
        let capabilities = DeviceCapabilities(canSendText: { false }, canPlaceCalls: { true })
        let (coordinator, executor, resolver, _) = makeCoordinator(model: ScriptedLanguageModel(["text alex hi": composeJSON]), capabilities: capabilities)
        let report = await coordinator.handle(.typed("text alex hi"))
        #expect(report.outcome == .unsupported)
        #expect(report.pendingAction == nil)
        #expect(resolver.calls.isEmpty)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func strayYesWithNothingPendingGoesToTheModelNotTheExecutor() async {
        let model = ScriptedLanguageModel(["yes": #"{"type":"answer","speech":"What would you like me to do?"}"#])
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        let report = await coordinator.handle(.typed("yes"))
        #expect(report.outcome == .answered)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func bargeInDuringPromptLeavesActionPendingAndUnexecuted() async {
        let speech = RecordingSpeech()
        speech.interruptNext = true
        let (coordinator, executor, _, _) = makeCoordinator(model: ScriptedLanguageModel(["text alex hi": composeJSON]), speech: speech)
        let report = await coordinator.handle(.typed("text alex hi"))
        #expect(report.interrupted)
        #expect(coordinator.state == .interrupted)
        #expect(coordinator.session.pendingAction != nil)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func partialTranscriptsAreUIOnly() {
        let model = ScriptedLanguageModel { _ in composeJSON }
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        coordinator.updatePartialTranscript(PartialTranscript(text: "text alex yes send it", revision: 3, audioDurationSeconds: 1.2))
        #expect(coordinator.presentation.partialTranscript == "text alex yes send it")
        #expect(model.requests.isEmpty)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func emptyUtteranceDoesNothing() async {
        let model = ScriptedLanguageModel { _ in composeJSON }
        let (coordinator, executor, _, _) = makeCoordinator(model: model)
        #expect(await coordinator.handle(.typed("   ")).outcome == .noAction)
        #expect(model.requests.isEmpty)
        #expect(executor.sideEffects.isEmpty)
    }

    @Test func modelQuestionThenAnswerGoesBackToModelWithContext() async {
        let model = ScriptedLanguageModel { request in
            let utterance = ScriptedLanguageModel.utterance(in: request)
            if utterance == "send a text to Jordan" { return #"{"type":"clarification","speech":"What should the message say?"}"# }
            return #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Jordan","message":"I'm outside."},"requires_confirmation":true}"#
        }
        let (coordinator, _, _, _) = makeCoordinator(model: model)
        #expect(await coordinator.handle(.typed("send a text to Jordan")).outcome == .clarificationRequested)
        let report = await coordinator.handle(.typed("I'm outside"))
        #expect(report.outcome == .confirmationRequested)
        #expect(model.requests.last?.suffix.contains("What should the message say?") == true)
    }

    @Test func messageComposerCancellationIsReportedTruthfully() async {
        let (coordinator, executor, _, _) = makeCoordinator(model: ScriptedLanguageModel(["text alex hi": composeJSON]))
        executor.composeResult = .cancelledByUser(.composeMessage)
        _ = await coordinator.handle(.typed("text alex hi"))
        let report = await coordinator.handle(.typed("yes"))
        #expect(report.spokenText.contains("wasn't sent"))
        #expect(!report.spokenText.contains("Sent to"))
    }
}

final class DateBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

/// Needs contacts permission on the first call only.
func permissionGatedResolver() -> StubResolver {
    let counter = Counter()
    return StubResolver { call, _ in
        counter.increment() == 1 ? .needsPermission(.contacts) : .resolved(.composeMessage(alexKim, body: call.string("message") ?? ""))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
