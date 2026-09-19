import Core
import Foundation
import Permissions
import Testing
@testable import Tools

@Suite struct ContactResolutionTests {
    private func callTarget(_ query: String, session: SessionState = SessionState(), pins: [String: ClarificationCandidate] = [:]) async -> ResolutionOutcome {
        await World.resolve(.initiateCall, ["contact_query": .string(query)], session: session, pins: pins)
    }

    @Test func exactFullNameResolvesUniquely() async throws {
        let target = try #require(await callTarget("Alex Kim").target)
        #expect(target.contactIdentifier == "c-alex-kim")
        #expect(target.displayName == "Alex Kim")
        #expect(target.phoneNumber == "(555) 010-1001")
        #expect(target.phoneLabel == "mobile")
    }

    @Test func givenNameSharedByTwoContactsIsAmbiguous() async throws {
        let clarification = try #require(await callTarget("Alex").clarification)
        #expect(clarification.reason == .contactAmbiguous)
        #expect(clarification.question == "I found Alex Chen and Alex Kim. Which one?")
        #expect(clarification.candidates.map(\.identifier) == ["c-alex-chen", "c-alex-kim"])
        #expect(clarification.candidates.allSatisfy { $0.kind == .contact })
        #expect(clarification.missingArgument == "contact_query")
        let chen = try #require(clarification.candidates.first)
        #expect(chen.matchTerms.contains("Chen"))
        #expect(chen.matchTerms.contains("Acme"))
        #expect(clarification.partialCall?.tool == .initiateCall)
        #expect(clarification.createdAt == World.now)
    }

    @Test func nicknameResolves() async throws {
        #expect(await callTarget("Johnny").target?.contactIdentifier == "c-john-smith")
        #expect(await callTarget("Bobby").target?.contactIdentifier == "c-robert-diaz")
        #expect(await callTarget("Bobby Diaz").target?.contactIdentifier == "c-robert-diaz")
    }

    @Test func duplicateContactsAreAmbiguousAndDistinguishable() async throws {
        let clarification = try #require(await callTarget("Jordan Park").clarification)
        #expect(clarification.reason == .contactAmbiguous)
        #expect(clarification.question == "I found 2 contacts named Jordan Park. Which one?")
        #expect(clarification.candidates.map(\.displayText) == ["Jordan Park, Initech", "Jordan Park, Umbrella"])
        #expect(clarification.candidates.map(\.identifier) == ["c-jordan-park-1", "c-jordan-park-2"])
        #expect(clarification.candidates[1].matchTerms.contains("Umbrella"))
    }

    @Test(arguments: [
        ("Alex Kym", "c-alex-kim"),
        ("alex kim", "c-alex-kim"),
        ("Jon Smith", "c-john-smith"),
        ("Catherine Lee", "c-kathryn-lee"),
        ("Katherine", "c-kathryn-lee"),
        ("Kathryn", "c-kathryn-lee"),
        ("Roberto Diaz", "c-robert-diaz"),
        ("Rob Diaz", "c-robert-diaz"),
        ("Dr. Kim", "c-alex-kim"),
        ("my Alex Kim", "c-alex-kim"),
    ])
    func recognitionErrorsStillResolve(query: String, expected: String) async {
        let outcome = await World.resolve(.composeMessage, ["contact_query": .string(query), "message": .string("On my way")])
        #expect(outcome.target?.contactIdentifier == expected, "query \(query)")
    }

    @Test func pronounUsesLastContact() async throws {
        var session = SessionState()
        session.lastContact = ContactReference(contactIdentifier: "c-alex-chen", displayName: "Alex Chen")
        for pronoun in ["him", "her", "them", "that person", "Him"] {
            let target = try #require(await callTarget(pronoun, session: session).target, "pronoun \(pronoun)")
            #expect(target.contactIdentifier == "c-alex-chen")
            // Alex Chen has mobile and work numbers: the unique mobile number is used.
            #expect(target.phoneNumber == "(555) 010-1002")
        }
    }

    @Test func pronounWithoutLastContactAsksWho() async throws {
        let clarification = try #require(await callTarget("him").clarification)
        #expect(clarification.reason == .contactNotFound)
        #expect(clarification.question == "Who do you mean?")
        #expect(clarification.candidates.isEmpty)
    }

    @Test func pronounWhoseContactWasDeletedIsNotFound() async throws {
        var session = SessionState()
        session.lastContact = ContactReference(contactIdentifier: "c-deleted", displayName: "Old Friend")
        let clarification = try #require(await callTarget("her", session: session).clarification)
        #expect(clarification.reason == .contactNotFound)
        #expect(clarification.question == "I couldn't find Old Friend in your contacts. Who should I call?")
    }

    @Test func unknownNameIsNotFound() async throws {
        let outcome = await World.resolve(.composeMessage, ["contact_query": .string("Taylor"), "message": .string("Hi")])
        let clarification = try #require(outcome.clarification)
        #expect(clarification.reason == .contactNotFound)
        #expect(clarification.question == "I couldn't find Taylor in your contacts. Who should I message?")

        let call = try #require(await callTarget("Taylor").clarification)
        #expect(call.question == "I couldn't find Taylor in your contacts. Who should I call?")
    }

    @Test func unexplainedSurnameIsNotFoundRatherThanAPartialMatch() async throws {
        // "Alex" matches two contacts but "Johnson" matches neither.
        let clarification = try #require(await callTarget("Alex Johnson").clarification)
        #expect(clarification.reason == .contactNotFound)
    }

    @Test func pinnedSelectionFetchesThatContact() async throws {
        let pin = ClarificationCandidate(kind: .contact, identifier: "c-alex-kim", displayText: "Alex Kim", matchTerms: [])
        let target = try #require(await callTarget("Alex", pins: ["contact_query": pin]).target)
        #expect(target.contactIdentifier == "c-alex-kim")
    }

    @Test func pinnedSelectionThatVanishedIsNotFound() async throws {
        let pin = ClarificationCandidate(kind: .contact, identifier: "c-gone", displayText: "Alex Gone", matchTerms: [])
        let clarification = try #require(await callTarget("Alex", pins: ["contact_query": pin]).clarification)
        #expect(clarification.reason == .contactNotFound)
    }

    @Test func givenNameOutranksFamilyName() async throws {
        // "Lee" is Lee Wong's given name and Kathryn Lee's family name.
        #expect(await callTarget("Lee").target?.contactIdentifier == "c-lee-wong")
    }

    @Test func organizationOnlyContactResolvesByFullName() async throws {
        #expect(await callTarget("Acme Dental").target?.contactIdentifier == "c-acme-dental")
    }

    @Test func exactMatchBeatsDiminutive() async throws {
        let mike = ContactRecord(identifier: "c-mike", givenName: "Mike", familyName: "Ross", phones: [LabeledPhone(label: "mobile", number: "555-010-1111")])
        let michael = ContactRecord(identifier: "c-michael", givenName: "Michael", familyName: "Chen", phones: [LabeledPhone(label: "mobile", number: "555-010-2222")])
        let suite = World.suite(contacts: [michael, mike])
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Mike")], suite: suite)
        #expect(outcome.target?.contactIdentifier == "c-mike")

        let onlyMichael = World.suite(contacts: [michael])
        let fuzzy = await World.resolve(.initiateCall, ["contact_query": .string("Mike")], suite: onlyMichael)
        #expect(fuzzy.target?.contactIdentifier == "c-michael")
    }

    @Test func homophonesAreEquallyGood() async throws {
        // Speech recognition cannot tell "Jon" from "John", so both are offered.
        let jon = ContactRecord(identifier: "c-jon-snow", givenName: "Jon", familyName: "Snow", phones: [LabeledPhone(label: "mobile", number: "555-010-3333")])
        let suite = World.suite(contacts: [World.johnSmith, jon])
        let clarification = try #require(await World.resolve(.initiateCall, ["contact_query": .string("Jon")], suite: suite).clarification)
        #expect(clarification.reason == .contactAmbiguous)
        #expect(clarification.question == "I found John Smith and Jon Snow. Which one?")
    }

    @Test func rankingIsDeterministicRegardlessOfStoreOrder() async throws {
        let forward = World.suite(contacts: World.contacts)
        let reversed = World.suite(contacts: World.contacts.reversed())
        for query in ["Alex", "Jordan Park", "Jordan"] {
            let first = await World.resolve(.initiateCall, ["contact_query": .string(query)], suite: forward).clarification
            let second = await World.resolve(.initiateCall, ["contact_query": .string(query)], suite: reversed).clarification
            #expect(first?.candidates == second?.candidates, "query \(query)")
            #expect(first?.question == second?.question, "query \(query)")
        }
    }

    @Test func manyEquallyGoodMatchesAreCountedNotListed() async throws {
        let alexes = (1...5).map { index in
            ContactRecord(identifier: "c-alex-\(index)", givenName: "Alex", familyName: "Name\(index)", phones: [LabeledPhone(label: "mobile", number: "555-010-000\(index)")])
        }
        let clarification = try #require(await World.resolve(.initiateCall, ["contact_query": .string("Alex")], suite: World.suite(contacts: alexes)).clarification)
        #expect(clarification.question == "I found 5 contacts named Alex. Which one?")
        #expect(clarification.candidates.count == 5)
    }

    // MARK: Permissions

    @Test func contactsPermissionNotDeterminedAsksForPermission() async {
        let suite = World.suite(permissions: [.contacts: .notDetermined])
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Alex Kim")], suite: suite)
        #expect(outcome.permission == .contacts)
    }

    @Test(arguments: [PermissionStatus.denied, .restricted])
    func contactsPermissionDeniedFails(status: PermissionStatus) async {
        let suite = World.suite(permissions: [.contacts: status])
        let outcome = await World.resolve(.composeMessage, ["contact_query": .string("Alex Kim"), "message": .string("Hi")], suite: suite)
        #expect(outcome.failure == ToolFailure(tool: .composeMessage, code: .permissionDenied))
    }

    @Test func limitedContactsAccessIsUsable() async {
        let suite = World.suite(permissions: [.contacts: .limited])
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Alex Kim")], suite: suite)
        #expect(outcome.target?.contactIdentifier == "c-alex-kim")
    }

    @Test func storeFailureIsReportedTruthfully() async {
        let suite = World.suite()
        await suite.contacts.setFailure(.systemFailure)
        let outcome = await World.resolve(.initiateCall, ["contact_query": .string("Alex Kim")], suite: suite)
        #expect(outcome.failure == ToolFailure(tool: .initiateCall, code: .systemError))
    }

    // MARK: search_contacts

    @Test func searchContactsResolvesToQuery() async {
        let outcome = await World.resolve(.searchContacts, ["name": .string("  Alex Kim ")])
        #expect(outcome.action == .searchContacts(query: "Alex Kim"))
    }

    @Test func searchContactsPronounUsesLastContact() async {
        var session = SessionState()
        session.lastContact = ContactReference(contactIdentifier: "c-alex-kim", displayName: "Alex Kim")
        let outcome = await World.resolve(.searchContacts, ["name": .string("him")], session: session)
        #expect(outcome.action == .searchContacts(query: "Alex Kim"))
    }

    @Test func searchContactsNeedsAName() async {
        let outcome = await World.resolve(.searchContacts, ["name": .string("   ")])
        #expect(outcome.clarification?.question == "Who should I look up?")
        #expect(outcome.clarification?.reason == .missingField)
    }
}

@Suite struct ContactMatcherTests {
    private func tier(_ query: String, _ contact: ContactRecord) -> ContactMatch.Rank? {
        ContactMatcher.rank(query: query, contacts: [contact]).first?.rank
    }

    @Test func tiersFollowTheSpecifiedOrder() {
        let contact = ContactRecord(identifier: "c", givenName: "Alex", familyName: "Kim", nickname: "Lexi", organization: "Acme")
        #expect(tier("Alex Kim", contact)?.tier == .fullName)
        #expect(tier("Kim Alex", contact)?.tier == .givenAndFamily)
        #expect(tier("Lexi Kim", contact)?.tier == .givenAndFamily)
        #expect(tier("Lexi", contact)?.tier == .nickname)
        #expect(tier("Alex", contact)?.tier == .givenOnly)
        #expect(tier("Kim", contact)?.tier == .familyOnly)
        #expect(tier("Acme", contact)?.tier == .organization)
        #expect(tier("Alex Acme", contact)?.tier == .nameAndOrganization)
        #expect(tier("Bob", contact) == nil)
        #expect(ContactMatchTier.fullName > .givenAndFamily)
        #expect(ContactMatchTier.givenAndFamily > .nickname)
        #expect(ContactMatchTier.nickname > .givenOnly)
        #expect(ContactMatchTier.givenOnly > .familyOnly)
        #expect(ContactMatchTier.familyOnly > .organization)
    }

    @Test func exactOutranksFuzzyAcrossTiers() {
        let exactGiven = ContactMatch.Rank(isExact: true, tier: .givenOnly, cost: 0)
        let fuzzyFull = ContactMatch.Rank(isExact: false, tier: .fullName, cost: 1)
        #expect(exactGiven > fuzzyFull)
        let cheaper = ContactMatch.Rank(isExact: false, tier: .fullName, cost: 1)
        let pricier = ContactMatch.Rank(isExact: false, tier: .fullName, cost: 3)
        #expect(cheaper > pricier)
    }

    @Test func fuzzyMatchesCarryCost() throws {
        let rank = try #require(tier("Alex Kym", World.alexKim))
        #expect(rank.isExact) // "Kym" is a homophone of "Kim".
        let typo = try #require(tier("Alex Kin", World.alexKim))
        #expect(!typo.isExact)
        #expect(typo.cost > 0)
        #expect(typo.tier == .fullName)
    }

    @Test func fillerWordsAreIgnoredButNotEverything() {
        #expect(ContactMatcher.queryTokens("my Dr. Garcia") == ["garcia"])
        #expect(ContactMatcher.queryTokens("Mr") == ["mr"])
        #expect(ContactMatcher.queryTokens("O'Brien's") == ["obrien"])
    }

    @Test func overlongQueriesDoNotMatch() {
        #expect(ContactMatcher.rank(query: "alex kim alex kim alex kim alex", contacts: World.contacts).isEmpty)
    }
}
