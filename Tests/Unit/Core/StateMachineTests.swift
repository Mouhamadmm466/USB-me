import Foundation
import Telemetry
import Testing
@testable import Core

@Suite struct StateMachineTests {
    @Test func everyStateCanReachErrorExceptErrorItself() {
        for state in AgentState.allCases {
            #expect(AgentStateMachine.canTransition(from: state, to: .error) == (state != .error))
        }
    }

    @Test func selfTransitionsAreRejected() {
        for state in AgentState.allCases {
            #expect(!AgentStateMachine.canTransition(from: state, to: state))
        }
    }

    @Test func tableIsTheOnlySourceOfAllowedTransitions() {
        for from in AgentState.allCases {
            for to in AgentState.allCases where to != .error && to != from {
                let expected = AgentStateMachine.allowed[from, default: []].contains(to)
                #expect(AgentStateMachine.canTransition(from: from, to: to) == expected, "\(from) -> \(to)")
            }
        }
    }

    @Test func everyStateHasAnExitAndIsReachable() {
        for state in AgentState.allCases where state != .booting {
            let reachable = AgentState.allCases.contains { AgentStateMachine.canTransition(from: $0, to: state) }
            #expect(reachable, "\(state) unreachable")
        }
        for state in AgentState.allCases {
            #expect(!AgentStateMachine.allowed[state, default: []].isEmpty, "\(state) has no exit")
        }
    }

    @Test func consequentialExecutionIsOnlyReachableFromDecisionStates() {
        // Executing is reachable only after an explicit decision point, never from raw audio states.
        let sources = AgentState.allCases.filter { AgentStateMachine.canTransition(from: $0, to: .executing) }
        #expect(Set(sources) == [.transcribing, .thinking, .speaking, .waitingForConfirmation, .permissionRequired])
        #expect(!AgentStateMachine.canTransition(from: .listening, to: .executing))
        #expect(!AgentStateMachine.canTransition(from: .endpointing, to: .executing))
        #expect(!AgentStateMachine.canTransition(from: .idle, to: .executing))
    }

    @Test func canonicalVoiceTurnIsLegal() throws {
        var machine = AgentStateMachine(initial: .booting, logger: nil)
        let path: [(AgentState, TransitionReason)] = [
            (.warmingModels, .modelsReady), (.idle, .modelsReady), (.listening, .userStartedSession),
            (.endpointing, .silenceDetected), (.transcribing, .transcriptReady), (.thinking, .transcriptReady),
            (.speaking, .confirmationRequested), (.waitingForConfirmation, .speechFinished),
            (.listening, .speechDetected), (.endpointing, .silenceDetected), (.transcribing, .transcriptReady),
            (.executing, .userApproved), (.reportingResult, .toolFinished), (.idle, .speechFinished),
        ]
        for (state, reason) in path {
            try machine.transition(to: state, reason: reason)
        }
        #expect(machine.current == .idle)
        #expect(machine.history.count == path.count)
    }

    @Test func illegalTransitionThrowsAndDoesNotChangeState() {
        var machine = AgentStateMachine(initial: .listening, logger: nil)
        #expect(throws: IllegalTransition.self) { try machine.transition(to: .executing, reason: .userApproved) }
        #expect(machine.current == .listening)
        #expect(machine.history.isEmpty)
    }

    @Test func transitionsAreLoggedWithoutUserContent() throws {
        let logger = PrivacySafeLogger(ringCapacity: 10)
        var machine = AgentStateMachine(initial: .idle, logger: logger)
        try machine.transition(to: .thinking, reason: .typedInput)
        let lines = logger.recentEvents().map(\.event.renderedLine)
        #expect(lines == ["state idle -> thinking [typedInput]"])
    }

    @Test func historyIsBounded() throws {
        var machine = AgentStateMachine(initial: .idle, historyLimit: 4, logger: nil)
        for _ in 0..<5 {
            try machine.transition(to: .thinking, reason: .typedInput)
            try machine.transition(to: .idle, reason: .cancelled)
        }
        #expect(machine.history.count == 4)
    }

    @Test func failIsIdempotent() {
        var machine = AgentStateMachine(initial: .speaking, logger: nil)
        machine.fail()
        machine.fail()
        #expect(machine.current == .error)
        #expect(machine.history.count == 1)
    }
}

@Suite struct CoreTypeTests {
    @Test func riskPolicy() {
        #expect(!RiskLevel.readOnly.requiresConfirmation)
        #expect(RiskLevel.reversibleLocalWrite.requiresConfirmation)
        #expect(RiskLevel.externalCommunication.requiresConfirmation)
        #expect(!RiskLevel.highRisk.isSupportedInV1)
    }

    @Test func catalogCoversEveryToolWithTheRightRisk() {
        #expect(Set(ToolCatalog.all.map(\.id)) == Set(ToolID.allCases))
        let expected: [ToolID: RiskLevel] = [
            .searchContacts: .readOnly, .getCalendarEvents: .readOnly, .searchFiles: .readOnly, .openFile: .readOnly,
            .openSupportedApp: .readOnly, .createCalendarEvent: .reversibleLocalWrite, .updateCalendarEvent: .reversibleLocalWrite,
            .createReminder: .reversibleLocalWrite, .composeMessage: .externalCommunication, .initiateCall: .externalCommunication,
        ]
        for (tool, risk) in expected {
            #expect(ToolCatalog.spec(for: tool).riskLevel == risk, "\(tool)")
        }
        // No V1 tool is high risk.
        #expect(ToolCatalog.all.allSatisfy { $0.riskLevel.isSupportedInV1 })
    }

    @Test func argumentNamesAreUniquePerTool() {
        for spec in ToolCatalog.all {
            #expect(Set(spec.arguments.map(\.name)).count == spec.arguments.count)
            for group in spec.atLeastOneOf {
                #expect(group.allSatisfy { spec.argument(named: $0) != nil })
            }
        }
    }

    @Test func sessionTurnsAreBounded() {
        var session = SessionState(maxRecentTurns: 3)
        for index in 0..<5 {
            session.append(ConversationTurn(role: .user, text: "\(index)", timestamp: Date()))
        }
        #expect(session.recentTurns.map(\.text) == ["2", "3", "4"])
    }

    @Test func resetKeepsPermissionsButDropsContext() {
        var session = SessionState()
        session.permissionsSnapshot = PermissionsSnapshot(statuses: [.contacts: .granted])
        session.lastContact = ContactReference(contactIdentifier: "c", displayName: "C")
        session.append(ConversationTurn(role: .user, text: "hi", timestamp: Date()))
        session.reset()
        #expect(session.lastContact == nil)
        #expect(session.recentTurns.isEmpty)
        #expect(session.permissionsSnapshot.status(.contacts) == .granted)
    }

    @Test func resolvedEntitiesDeduplicateAndBound() {
        var entities = ResolvedEntities(limit: 2)
        entities.remember(contact: ContactReference(contactIdentifier: "a", displayName: "A"))
        entities.remember(contact: ContactReference(contactIdentifier: "b", displayName: "B"))
        entities.remember(contact: ContactReference(contactIdentifier: "a", displayName: "A"))
        entities.remember(contact: ContactReference(contactIdentifier: "c", displayName: "C"))
        #expect(entities.contacts.map(\.contactIdentifier) == ["c", "a"])
    }
}

@Suite struct PrivacyLoggerTests {
    @Test func renderedEventsContainOnlyLabels() {
        let logger = PrivacySafeLogger(ringCapacity: 5)
        logger.log(.toolExecution(tool: SafeLabel(ToolID.composeMessage), status: "success"))
        logger.log(.stageLatency(stage: .llmTotal, milliseconds: 812))
        logger.log(.error(domain: "asr", code: "whisper_full_failed"))
        let lines = logger.recentEvents().map(\.event.renderedLine)
        #expect(lines == ["tool compose_message success", "latency llmTotal=812ms", "error asr.whisper_full_failed"])
    }

    @Test func ringBufferIsBounded() {
        let logger = PrivacySafeLogger(ringCapacity: 3)
        for index in 0..<10 { logger.log(.counter(name: "n", value: index)) }
        #expect(logger.recentEvents().count == 3)
    }

    @Test func percentiles() {
        let summary = StageSummary(values: [5, 1, 4, 2, 3, 10, 9, 8, 7, 6])
        #expect(summary.p50 == 5)
        #expect(summary.p95 == 10)
        #expect(summary.min == 1)
        #expect(summary.max == 10)
    }
}
