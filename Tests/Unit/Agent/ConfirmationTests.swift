import Core
import Foundation
import Testing
@testable import Agent

@Suite struct ConfirmationClassifierTests {
    let classifier = ConfirmationClassifier()

    @Test(arguments: [
        "yes", "Yes.", "yeah", "yep", "yup", "sure", "ok", "okay", "OK!", "alright", "all right", "correct",
        "go ahead", "please go ahead", "do it", "yes please", "sure thing", "sounds good", "that's right",
        "go for it", "yes, send it", "send it", "yeah send it now", "Um, yes.", "uh yeah", "confirm",
        "absolutely", "of course", "yes do it", "perfect", "sure why not", "mhm", "yes send the message",
        "thank you yes", "Yes. Thanks.",
    ])
    func affirmativesForMessage(text: String) {
        #expect(classifier.classify(text, pendingTool: .composeMessage) == .affirm, "\(text)")
    }

    @Test(arguments: ["call him", "call", "yes call", "place the call", "dial it"])
    func toolSpecificApproval(text: String) {
        #expect(classifier.classify(text, pendingTool: .initiateCall) == .affirm, "\(text)")
    }

    @Test func approvalVerbsDoNotCrossTools() {
        // "send it" does not approve a call; "call him" does not approve a message.
        #expect(classifier.classify("send it", pendingTool: .initiateCall) != .affirm)
        #expect(classifier.classify("call him", pendingTool: .composeMessage) != .affirm)
        #expect(classifier.classify("add it", pendingTool: .composeMessage) != .affirm)
    }

    @Test(arguments: [
        "no", "No.", "nope", "nah", "cancel", "cancel that", "never mind", "nevermind", "don't",
        "stop", "forget it", "no thanks", "no thank you", "don't send it", "do not send it", "abort",
        "no don't send it", "no, don't do that", "I changed my mind", "scratch that", "not now",
        "absolutely not", "definitely not", "please don't", "don't send the message", "no, cancel",
        "I said no", "don't just send it",
    ])
    func rejections(text: String) {
        #expect(classifier.classify(text, pendingTool: .composeMessage) == .reject, "\(text)")
    }

    @Test(arguments: ["wait", "hold on", "hang on", "one sec", "one second", "not yet", "give me a second", "wait a minute", "no wait", "hold on a second", "let me think"])
    func deferrals(text: String) {
        #expect(classifier.classify(text, pendingTool: .composeMessage) == .defer_, "\(text)")
    }

    @Test(arguments: [
        "yes but make it 30 minutes", "actually say 25 minutes", "change the message to I'm on my way",
        "no, send it to Priya instead", "make it 4pm", "yes but at 5", "send it to his work number",
        "yeah and add that I'm sorry", "no, tomorrow", "can you make it shorter",
    ])
    func modifications(text: String) {
        #expect(classifier.classify(text, pendingTool: .composeMessage) == .modify, "\(text)")
    }

    @Test(arguments: [
        "hmm", "maybe", "I don't know", "what?", "uh", "yes no", "no yes", "yes, cancel it", "no, go ahead",
        "I guess", "I guess so", "I think so", "not sure", "huh", "say that again", "yes wait", "", "   ",
        "...", "please", "thank you", "uh-huh", "probably",
    ])
    func unclear(text: String) {
        #expect(classifier.classify(text, pendingTool: .composeMessage) == .unclear, "\(text)")
    }
}

@Suite struct ConfirmationManagerTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let target = ContactTarget(contactIdentifier: "c1", displayName: "Alex Kim", phoneNumber: "+15550101001", phoneLabel: "mobile")

    func session(with action: ResolvedAction, lifetime: TimeInterval = 120) -> SessionState {
        var session = SessionState()
        session.pendingAction = PendingAction(action: action, humanReadableSummary: "s", originalTranscript: "t", createdAt: now, lifetime: lifetime)
        session.confirmationState = .awaitingResponse(reprompts: 0)
        return session
    }

    @Test func approvalBindsToExactVersionAndDigest() throws {
        var state = session(with: .composeMessage(target, body: "I'll be 20 minutes late."))
        let manager = ConfirmationManager()
        guard case let .approve(token) = manager.decide(reply: "yes", session: &state, now: now) else {
            Issue.record("expected approval"); return
        }
        let pending = try #require(state.pendingAction)
        #expect(pending.accepts(token, at: now))
        #expect(token.version == 1)
        // A revised version never accepts the old token, even with identical text changes reverted.
        let revised = pending.revised(action: .composeMessage(target, body: "I'll be 30 minutes late."), humanReadableSummary: "s", originalTranscript: "t", now: now, lifetime: 120)
        #expect(revised.version == 2)
        #expect(revised.confirmationStatus == .pending)
        #expect(!revised.accepts(token, at: now))
    }

    @Test func tokenFromDifferentActionIsRejected() {
        var first = PendingAction(action: .composeMessage(target, body: "a"), humanReadableSummary: "", originalTranscript: "", createdAt: now, lifetime: 120)
        let second = PendingAction(action: .composeMessage(target, body: "b"), humanReadableSummary: "", originalTranscript: "", createdAt: now, lifetime: 120)
        let token = first.approve(at: now)!
        #expect(!second.accepts(token, at: now))
    }

    @Test func expiredActionCannotBeApproved() {
        var state = session(with: .composeMessage(target, body: "hi"), lifetime: 60)
        let decision = ConfirmationManager().decide(reply: "yes", session: &state, now: now.addingTimeInterval(61))
        #expect(decision == .expired)
        #expect(state.pendingAction == nil)
    }

    @Test func tokenExpiresEvenAfterApproval() {
        var pending = PendingAction(action: .composeMessage(target, body: "hi"), humanReadableSummary: "", originalTranscript: "", createdAt: now, lifetime: 60)
        let token = pending.approve(at: now.addingTimeInterval(59))!
        #expect(pending.accepts(token, at: now.addingTimeInterval(59)))
        #expect(!pending.accepts(token, at: now.addingTimeInterval(61)))
    }

    @Test func approvedActionCannotBeApprovedTwice() {
        var pending = PendingAction(action: .composeMessage(target, body: "hi"), humanReadableSummary: "", originalTranscript: "", createdAt: now, lifetime: 60)
        #expect(pending.approve(at: now) != nil)
        #expect(pending.approve(at: now) == nil)
    }

    @Test func unclearRepliesEscalateThenCancel() {
        var state = session(with: .composeMessage(target, body: "hi"))
        let manager = ConfirmationManager()
        #expect(manager.decide(reply: "hmm", session: &state, now: now) == .reprompt(attempt: 1))
        #expect(manager.decide(reply: "maybe", session: &state, now: now) == .reprompt(attempt: 2))
        #expect(manager.decide(reply: "I don't know", session: &state, now: now) == .cancelAfterUnclear)
        #expect(state.pendingAction == nil)
    }

    @Test func modificationNeverApproves() {
        var state = session(with: .composeMessage(target, body: "hi"))
        #expect(ConfirmationManager().decide(reply: "yes but make it 30 minutes", session: &state, now: now) == .modify)
        #expect(state.pendingAction?.confirmationStatus == .pending)
    }

    @Test func cardApprovalRequiresMatchingIDAndVersion() {
        var state = session(with: .composeMessage(target, body: "hi"))
        let pending = state.pendingAction!
        let manager = ConfirmationManager()
        #expect(manager.approveFromCard(id: UUID(), version: 1, session: &state, now: now) == nil)
        #expect(manager.approveFromCard(id: pending.id, version: 2, session: &state, now: now) == nil)
        #expect(manager.approveFromCard(id: pending.id, version: 1, session: &state, now: now) != nil)
    }

    @Test func digestChangesWithEveryArgument() {
        let base = ActionDigest.digest(of: .composeMessage(target, body: "hi"))
        #expect(base != ActionDigest.digest(of: .composeMessage(target, body: "hi!")))
        let other = ContactTarget(contactIdentifier: "c2", displayName: "Alex Kim", phoneNumber: "+15550101001", phoneLabel: "mobile")
        #expect(base != ActionDigest.digest(of: .composeMessage(other, body: "hi")))
        #expect(base == ActionDigest.digest(of: .composeMessage(target, body: "hi")))
    }
}

@Suite struct ClarificationManagerTests {
    let manager = ClarificationManager()
    let candidates = [
        ClarificationCandidate(kind: .contact, identifier: "c-alex-kim", displayText: "Alex Kim", matchTerms: ["Kim", "Acme"]),
        ClarificationCandidate(kind: .contact, identifier: "c-alex-chen", displayText: "Alex Chen", matchTerms: ["Chen", "Globex"]),
    ]

    func clarification(_ reason: ClarificationReason = .contactAmbiguous, candidates: [ClarificationCandidate]? = nil, missing: String? = nil) -> PendingClarification {
        PendingClarification(
            reason: reason, question: "Which one?", candidates: candidates ?? self.candidates,
            partialCall: ProposedToolCall(tool: .composeMessage, arguments: ["contact_query": .string("Alex"), "message": .string("hi")]),
            missingArgument: missing, originalTranscript: "text alex hi", createdAt: Date()
        )
    }

    @Test(arguments: [
        ("Kim", "c-alex-kim"), ("Alex Kim", "c-alex-kim"), ("the first one", "c-alex-kim"), ("first", "c-alex-kim"),
        ("the second one", "c-alex-chen"), ("Chen", "c-alex-chen"), ("the one at Globex", "c-alex-chen"),
        ("the last one", "c-alex-chen"), ("number two", "c-alex-chen"), ("Alex Chenn", "c-alex-chen"),
    ])
    func picksCandidates(answer: String, expected: String) {
        guard case let .choose(candidate) = manager.interpret(answer, for: clarification()) else {
            Issue.record("no choice for \(answer)"); return
        }
        #expect(candidate.identifier == expected)
    }

    @Test(arguments: ["cancel", "never mind", "neither", "none of them", "no"])
    func cancels(answer: String) {
        #expect(manager.interpret(answer, for: clarification()) == .cancel)
    }

    @Test func ambiguousAnswerStaysAmbiguous() {
        guard case let .stillAmbiguous(remaining) = manager.interpret("Alex", for: clarification()) else {
            Issue.record("expected still ambiguous"); return
        }
        #expect(remaining.count == 2)
    }

    @Test func unrelatedAnswerIsNotAnAnswer() {
        #expect(manager.interpret("what's the weather tomorrow", for: clarification()) == .notAnAnswer)
    }

    @Test func phoneCandidatesByLabelOrDigits() {
        let phones = [
            ClarificationCandidate(kind: .phoneNumber, identifier: "+15550101001", displayText: "mobile", matchTerms: ["mobile"]),
            ClarificationCandidate(kind: .phoneNumber, identifier: "+15550102002", displayText: "work", matchTerms: ["work"]),
        ]
        let question = clarification(.phoneNumberAmbiguous, candidates: phones)
        #expect(manager.interpret("his cell", for: question) == .choose(phones[0]))
        #expect(manager.interpret("the office one", for: question) == .choose(phones[1]))
        #expect(manager.interpret("the one ending in two zero zero two", for: question) == .choose(phones[1]))
    }

    @Test func missingMessageIsFilledVerbatim() {
        let question = clarification(.missingField, candidates: [], missing: "message")
        #expect(manager.interpret("say that I'm on my way", for: question) == .fill(argument: "message", value: "I'm on my way"))
        #expect(manager.interpret("running late, sorry", for: question) == .fill(argument: "message", value: "Running late, sorry"))
    }

    @Test func notFoundTakesANewName() {
        let question = clarification(.contactNotFound, candidates: [])
        #expect(manager.interpret("try Taylor Swift", for: question) == .fill(argument: "contact_query", value: "taylor swift"))
    }

    @Test func spokenDigits() {
        #expect(SpokenDigits.digits(in: "five five five oh one two three") == "5550123")
        #expect(SpokenDigits.digits(in: "call 555 010 4477") == "5550104477")
        #expect(SpokenDigits.digits(in: "double two nine") == "229")
        #expect(SpokenDigits.digits(in: "oh hello") == "")
    }
}
