import Core
import Foundation
import Testing
@testable import Tools

@Suite struct DictatedNumberTests {
    private func verify(_ number: String, _ transcript: String) -> DictatedNumberCheck {
        DictatedNumberVerifier.verify(number, transcript: transcript)
    }

    @Test func numeralsInTranscriptVerify() {
        #expect(verify("555-123-4567", "Call 555 123 4567 please") == .verified(DictatedPhoneNumber(digits: "5551234567", hasPlus: false)))
        #expect(verify("5551234567", "text (555) 123-4567 that I'm late") == .verified(DictatedPhoneNumber(digits: "5551234567", hasPlus: false)))
    }

    @Test func spelledDigitsVerify() {
        #expect(verify("555-1212", "call five five five one two one two") == .verified(DictatedPhoneNumber(digits: "5551212", hasPlus: false)))
        #expect(verify("2015550199", "text two oh one five five five oh one nine nine") == .verified(DictatedPhoneNumber(digits: "2015550199", hasPlus: false)))
        #expect(verify("5551212", "call five double five one two one two") == .verified(DictatedPhoneNumber(digits: "5551212", hasPlus: false)))
        #expect(verify("5551212", "call five five five twelve twelve") == .verified(DictatedPhoneNumber(digits: "5551212", hasPlus: false)))
        #expect(verify("18005551212", "call one eight hundred five five five one two one two") == .verified(DictatedPhoneNumber(digits: "18005551212", hasPlus: false)))
        #expect(verify("5552112", "call five five five twenty-one twelve") == .verified(DictatedPhoneNumber(digits: "5552112", hasPlus: false)))
        #expect(verify("5551212", "five five five, um, one two one two") == .verified(DictatedPhoneNumber(digits: "5551212", hasPlus: false)))
    }

    @Test func numberMissingFromTranscriptIsRejected() {
        #expect(verify("5551234567", "call my mom") == .notInTranscript)
        #expect(verify("5551239999", "call 555 123 4567") == .notInTranscript)
        // Digits split by unrelated words are not one spoken number.
        #expect(verify("5551212", "call 555 and then 1212") == .notInTranscript)
    }

    @Test func invalidLengthsAreRejected() {
        #expect(verify("12", "call 12") == .invalid)
        #expect(verify(String(repeating: "1", count: 21), String(repeating: "1", count: 21)) == .invalid)
        #expect(verify("abc", "call abc") == .invalid)
    }

    @Test func plusIsKeptOnlyWhenSpoken() {
        #expect(verify("+44 20 7946 0958", "call plus four four two zero seven nine four six zero nine five eight")
            == .verified(DictatedPhoneNumber(digits: "442079460958", hasPlus: true)))
        #expect(verify("+442079460958", "call +44 20 7946 0958") == .verified(DictatedPhoneNumber(digits: "442079460958", hasPlus: true)))
        #expect(verify("+442079460958", "call 44 20 7946 0958") == .verified(DictatedPhoneNumber(digits: "442079460958", hasPlus: false)))
    }

    @Test func spokenRunsAreSeparatedByOrdinaryWords() {
        let runs = SpokenNumberScanner.runs(in: "at 5 call 555-1212 or plus one two")
        #expect(runs.map(\.digits) == ["5", "5551212", "12"])
        #expect(runs.map(\.hasLeadingPlus) == [false, false, true])
    }

    @Test func formatting() {
        #expect(PhoneNumbers.formatted(digits: "5551212", hasPlus: false) == "555-1212")
        #expect(PhoneNumbers.formatted(digits: "5551234567", hasPlus: false) == "(555) 123-4567")
        #expect(PhoneNumbers.formatted(digits: "15551234567", hasPlus: true) == "+1 (555) 123-4567")
        #expect(PhoneNumbers.formatted(digits: "442079460958", hasPlus: true) == "+442079460958")
        #expect(PhoneNumbers.digits(in: "+1 (555) 010-2233 ext. 12") == "15550102233")
        #expect(PhoneNumbers.dialable("+1 (555) 010-2233") == "+15550102233")
        #expect(PhoneNumbers.dialable("12") == nil)
        #expect(PhoneNumbers.isClean("+1 (555) 010-2233"))
        #expect(!PhoneNumbers.isClean("555-0100 (cell)"))
    }

    // MARK: Through the resolver

    @Test func dictatedNumberResolvesWithoutAContact() async throws {
        let outcome = await World.resolve(.initiateCall, ["phone_number": .string("555-123-4567")], transcript: "call 555 123 4567")
        let target = try #require(outcome.target)
        #expect(target.contactIdentifier == nil)
        #expect(target.displayName == "(555) 123-4567")
        #expect(target.phoneNumber == "5551234567")
        #expect(target.phoneLabel == nil)
    }

    @Test func inventedNumberAsksAgain() async throws {
        let outcome = await World.resolve(.composeMessage, ["phone_number": .string("5551234567"), "message": .string("Hi")], transcript: "text my landlord that I'm late")
        let clarification = try #require(outcome.clarification)
        #expect(clarification.reason == .phoneNumberNotInTranscript)
        #expect(clarification.question == "I didn't catch the number. What number should I text?")
        #expect(clarification.missingArgument == "phone_number")
    }

    @Test func invalidDictatedNumberAsksAgain() async throws {
        let outcome = await World.resolve(.initiateCall, ["phone_number": .string("12")], transcript: "call 12")
        #expect(outcome.clarification?.reason == .missingField)
        #expect(outcome.clarification?.question == "I didn't catch the number. What number should I call?")
    }

    @Test func unverifiedNumberIsIgnoredWhenSomeoneIsNamed() async {
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Alex Kim"), "phone_number": .string("5559999999")], transcript: "call Alex Kim")
        #expect(outcome.target?.contactIdentifier == "c-alex-kim")
        #expect(outcome.target?.phoneNumber == "(555) 010-1001")
    }

    @Test func dictatedNumberOwnedByTheNamedContactKeepsTheirIdentity() async {
        let outcome = await World.resolve(
            .initiateCall,
            ["contact_query": .string("Alex Chen"), "phone_number": .string("5550102002")],
            transcript: "call Alex Chen at 555 010 2002"
        )
        #expect(outcome.target?.contactIdentifier == "c-alex-chen")
        #expect(outcome.target?.phoneNumber == "(555) 010-2002")
        #expect(outcome.target?.phoneLabel == "work")
    }

    @Test func dictatedNumberNotOwnedByTheNamedContactStaysAnonymous() async {
        let outcome = await World.resolve(
            .initiateCall,
            ["contact_query": .string("Alex Kim"), "phone_number": .string("5550009999")],
            transcript: "call Alex Kim at 555 000 9999"
        )
        #expect(outcome.target?.contactIdentifier == nil)
        #expect(outcome.target?.phoneNumber == "5550009999")
    }

    @Test func dictatedNumbersNeedNoContactsPermission() async {
        let suite = World.suite(permissions: [.contacts: .denied])
        let outcome = await World.resolve(.initiateCall, ["phone_number": .string("5551212")], transcript: "call 555 1212", suite: suite)
        #expect(outcome.target?.phoneNumber == "5551212")
    }

    @Test func noRecipientAtAllAsksWho() async {
        let outcome = await World.resolve(.initiateCall, [:], transcript: "call")
        #expect(outcome.clarification?.reason == .missingField)
        #expect(outcome.clarification?.question == "Who should I call?")
    }
}

@Suite struct MessageValidationTests {
    private func compose(_ message: String?) async -> ResolutionOutcome {
        var arguments: [String: ToolArgumentValue] = ["contact_query": .string("Alex Kim")]
        if let message { arguments["message"] = .string(message) }
        return await World.resolve(.composeMessage, arguments, transcript: "text Alex Kim")
    }

    @Test func validMessageIsTrimmed() async {
        let outcome = await compose("  Running 10 minutes late  ")
        guard case let .composeMessage(target, body)? = outcome.action else {
            Issue.record("expected a resolved message")
            return
        }
        #expect(target.contactIdentifier == "c-alex-kim")
        #expect(body == "Running 10 minutes late")
    }

    @Test(arguments: [nil, "", "   ", "\u{200B}\n"])
    func emptyMessageAsksWhatToSay(message: String?) async throws {
        let clarification = try #require(await compose(message).clarification)
        #expect(clarification.reason == .missingField)
        #expect(clarification.missingArgument == "message")
        #expect(clarification.question == "What should the message say?")
    }

    @Test func messageLengthLimit() async throws {
        let exactly500 = String(repeating: "a", count: 500)
        #expect(await compose(exactly500).action != nil)
        let clarification = try #require(await compose(exactly500 + "b").clarification)
        #expect(clarification.reason == .missingField)
        #expect(clarification.missingArgument == "message")
        #expect(clarification.question == "That message is too long. What should it say?")
    }

    @Test func hiddenCharactersAreRemoved() async {
        let outcome = await compose("Pay\u{202E}me\u{0007} back")
        guard case let .composeMessage(_, body)? = outcome.action else {
            Issue.record("expected a resolved message")
            return
        }
        #expect(body == "Payme back")
    }

    @Test func multilineMessagesKeepLineBreaks() async {
        guard case let .composeMessage(_, body)? = await compose("Line one\r\nLine two").action else {
            Issue.record("expected a resolved message")
            return
        }
        #expect(body == "Line one\nLine two")
    }

    @Test func recipientProblemsAreAskedBeforeTheMessage() async throws {
        let outcome = await World.resolve(.composeMessage, ["contact_query": .string("Taylor"), "message": .string("")])
        #expect(outcome.clarification?.reason == .contactNotFound)
    }
}
