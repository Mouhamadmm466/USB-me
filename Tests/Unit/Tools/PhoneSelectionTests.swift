import Core
import Foundation
import Testing
@testable import Tools

@Suite struct PhoneSelectionTests {
    @Test func onlyNumberIsSelected() {
        #expect(PhoneSelector.select(from: World.alexKim, requestedLabel: nil, pinned: nil)
            == .selected(LabeledPhone(label: "mobile", number: "(555) 010-1001")))
    }

    @Test func requestedLabelWins() {
        #expect(PhoneSelector.select(from: World.alexChen, requestedLabel: .work, pinned: nil)
            == .selected(LabeledPhone(label: "work", number: "(555) 010-2002")))
    }

    @Test func uniqueMobileIsPreferredWithoutALabel() {
        #expect(PhoneSelector.select(from: World.alexChen, requestedLabel: nil, pinned: nil)
            == .selected(LabeledPhone(label: "mobile", number: "(555) 010-1002")))
    }

    @Test func iPhoneLabelCountsAsMobile() {
        let contact = ContactRecord(identifier: "c", givenName: "Pat", phones: [
            LabeledPhone(label: "home", number: "555-010-0001"),
            LabeledPhone(label: "iPhone", number: "555-010-0002"),
        ])
        #expect(PhoneSelector.select(from: contact, requestedLabel: nil, pinned: nil)
            == .selected(LabeledPhone(label: "iPhone", number: "555-010-0002")))
        #expect(PhoneSelector.select(from: contact, requestedLabel: .mobile, pinned: nil)
            == .selected(LabeledPhone(label: "iPhone", number: "555-010-0002")))
    }

    @Test func pinnedNumberWinsWhenItBelongsToTheContact() {
        let pin = ClarificationCandidate(kind: .phoneNumber, identifier: "555-010-8002", displayText: "work", matchTerms: [])
        #expect(PhoneSelector.select(from: World.mariaGarcia, requestedLabel: nil, pinned: pin)
            == .selected(LabeledPhone(label: "work", number: "555-010-8002")))
        // A pinned number that is not this contact's is ignored.
        let foreign = ClarificationCandidate(kind: .phoneNumber, identifier: "555-999-0000", displayText: "x", matchTerms: [])
        if case .selected = PhoneSelector.select(from: World.mariaGarcia, requestedLabel: nil, pinned: foreign) {
            Issue.record("A foreign pinned number must not be selected")
        }
    }

    @Test func faxPagerAndAnnotatedNumbersAreNotUsable() {
        let contact = ContactRecord(identifier: "c", givenName: "Fax", phones: [
            LabeledPhone(label: "work fax", number: "555-010-0001"),
            LabeledPhone(label: "pager", number: "555-010-0002"),
            LabeledPhone(label: "mobile", number: "555-010-0003 (old)"),
            LabeledPhone(label: "other", number: "1-800-FLOWERS"),
        ])
        #expect(PhoneSelector.usablePhones(of: contact).isEmpty)
        #expect(PhoneSelector.select(from: contact, requestedLabel: nil, pinned: nil) == .noPhone)
    }

    @Test func duplicateNumbersCollapse() {
        let contact = ContactRecord(identifier: "c", givenName: "Dup", phones: [
            LabeledPhone(label: "mobile", number: "(555) 010-0001"),
            LabeledPhone(label: "iPhone", number: "555.010.0001"),
        ])
        #expect(PhoneSelector.usablePhones(of: contact).count == 1)
    }

    @Test func spokenOptionsUseLabelsOrLastFourDigits() {
        #expect(PhoneSelector.spokenOptions(for: World.mariaGarcia.phones) == ["home", "work", "other"])
        let sameLabels = [LabeledPhone(label: "work", number: "555-010-1234"), LabeledPhone(label: "work", number: "555-010-5678")]
        #expect(PhoneSelector.spokenOptions(for: sameLabels) == ["work ending in 1234", "work ending in 5678"])
        let unlabeled = [LabeledPhone(label: nil, number: "555-010-1234"), LabeledPhone(label: "home", number: "555-010-5678")]
        #expect(PhoneSelector.spokenOptions(for: unlabeled) == ["number ending in 1234", "home ending in 5678"])
    }

    // MARK: Through the resolver

    @Test func ambiguousNumbersAskWhichOne() async throws {
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Maria Garcia")])
        let clarification = try #require(outcome.clarification)
        #expect(clarification.reason == .phoneNumberAmbiguous)
        #expect(clarification.question == "Which number for Maria Garcia: home, work, or other?")
        #expect(clarification.missingArgument == "phone")
        #expect(clarification.candidates.map(\.identifier) == ["555-010-8001", "555-010-8002", "555-010-8003"])
        #expect(clarification.candidates.allSatisfy { $0.kind == .phoneNumber })
        #expect(clarification.candidates[0].displayText == "home: 555-010-8001")
        #expect(clarification.candidates[1].matchTerms.contains("office"))
        #expect(clarification.candidates[1].matchTerms.contains("8002"))
    }

    @Test func answeringThePhoneQuestionResolves() async throws {
        let first = try #require(await World.resolve(.initiateCall, ["contact_query": .string("Maria Garcia")]).clarification)
        let work = first.candidates[1]
        let partial = try #require(first.partialCall)
        let outcome = await ActionResolver(environment: World.suite().environment)
            .resolve(partial, context: World.context().pinning("phone", work))
        #expect(outcome.target?.phoneNumber == "555-010-8002")
        #expect(outcome.target?.phoneLabel == "work")
        #expect(outcome.target?.contactIdentifier == "c-maria-garcia")
    }

    @Test func labelArgumentSelectsThatNumber() async {
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Alex Chen"), "phone_label": .string("work")])
        #expect(outcome.target?.phoneNumber == "(555) 010-2002")
    }

    @Test func missingLabelIsExplained() async throws {
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Maria Garcia"), "phone_label": .string("mobile")])
        let clarification = try #require(outcome.clarification)
        #expect(clarification.reason == .phoneNumberAmbiguous)
        #expect(clarification.question == "I don't see a mobile number for Maria Garcia. Which one: home, work, or other?")

        let single = await World.resolve(.initiateCall, ["contact_query": .string("Alex Kim"), "phone_label": .string("work")])
        #expect(single.clarification?.question == "I don't see a work number for Alex Kim. Should I use mobile?")
        #expect(single.clarification?.candidates.map(\.identifier) == ["(555) 010-1001"])
    }

    @Test func contactWithoutNumbersAsksForOne() async throws {
        let call = try #require(await World.resolve(.initiateCall, ["contact_query": .string("Sam Patel")]).clarification)
        #expect(call.reason == .contactHasNoPhone)
        #expect(call.question == "Sam Patel doesn't have a phone number. What number should I call?")
        #expect(call.missingArgument == "phone_number")

        let message = try #require(await World.resolve(.composeMessage, ["contact_query": .string("Sam Patel"), "message": .string("Hi")]).clarification)
        #expect(message.question == "Sam Patel doesn't have a phone number. What number should I text?")
    }
}
