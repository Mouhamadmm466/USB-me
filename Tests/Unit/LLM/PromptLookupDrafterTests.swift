import Core
import Testing
@testable import LLM

@Suite struct PromptLookupDrafterTests {
    let drafter = PromptLookupDrafter(sources: ["Text Alex Kim that I will be 20 minutes late", "User: Text Alex Kim"])

    @Test func noDraftOutsideAString() {
        #expect(drafter.continuation(after: #"{"type":"proposed_action","#) == nil)
        #expect(drafter.continuation(after: #"{"type":"proposed_action","tool":"compose_message","arguments":{"#) == nil)
    }

    @Test func noDraftForAnEmptyValue() {
        #expect(drafter.continuation(after: #"{"arguments":{"contact_query":""#) == nil)
    }

    @Test func copiesTheRestOfANameFromTheUtterance() {
        #expect(drafter.continuation(after: #"{"arguments":{"contact_query":"Alex"#) == " Kim that I will be 20 minutes late")
    }

    @Test func caseInsensitiveMatch() {
        #expect(drafter.continuation(after: #"{"title":"alex"#) == " Kim that I will be 20 minutes late")
    }

    @Test func singleCharacterKeyMustBeAWholeWord() {
        // "I" must not match the "i" inside "Kim".
        #expect(drafter.continuation(after: #"{"message":"I"#) == " will be 20 minutes late")
    }

    @Test func midWordKeyRecoversAfterARewrite() {
        // The model wrote "I'll" where the user said "I will": "ll" is found inside "will".
        #expect(drafter.continuation(after: #"{"message":"I'll"#) == " be 20 minutes late")
    }

    @Test func prefersTheLongestMatchingKey() {
        let drafter = PromptLookupDrafter(sources: ["call Sam then text Sam that dinner is ready"])
        #expect(drafter.continuation(after: #"{"message":"text Sam"#) == " that dinner is ready")
    }

    @Test func fallsBackToLaterSources() {
        let drafter = PromptLookupDrafter(sources: ["make it 30 minutes", #"Pending action: compose_message {"contact_query":"Alex Kim","message":"I'll be 20 minutes late."}"#])
        #expect(drafter.continuation(after: #"{"contact_query":"Alex"#) == " Kim")
    }

    @Test func stopsBeforeCharactersThatNeedEscaping() {
        let drafter = PromptLookupDrafter(sources: [#"tell her "see you soon" tonight"#, "a\\b"])
        #expect(drafter.continuation(after: #"{"message":"see"#) == " you soon")
    }

    @Test func noDraftAtTheEndOfTheSource() {
        // The longest key only occurs at the end of the utterance: the value is complete, and the
        // shorter key "te" must not jump to "Text".
        #expect(drafter.continuation(after: #"{"message":"20 minutes late"#) == nil)
    }

    @Test func noDraftWhenTheValueEndsAtAClosingQuoteInTheContext() {
        let drafter = PromptLookupDrafter(sources: ["make it 30 minutes", #"Pending: {"contact_query":"Alex Kim","message":"late"}"#])
        #expect(drafter.continuation(after: #"{"contact_query":"Alex Kim"#) == nil)
    }

    @Test func noDraftAfterAnEscapeSequence() {
        #expect(drafter.continuation(after: #"{"message":"say \"Alex"#) == nil)
    }

    @Test func truncatesAtAWordBoundary() {
        var drafter = PromptLookupDrafter(sources: ["remind me to water the plants in the living room every sunday morning"])
        drafter.maximumDraftCharacters = 20
        let draft = drafter.continuation(after: #"{"title":"water"#)
        #expect(draft == " the plants in the")
    }

    @Test func openStringValue() {
        #expect(PromptLookupDrafter.openStringValue(in: #"{"a":"b"#) == "b")
        #expect(PromptLookupDrafter.openStringValue(in: #"{"a":"b","#) == nil)
        #expect(PromptLookupDrafter.openStringValue(in: #"{"a":"#) == nil)
        #expect(PromptLookupDrafter.openStringValue(in: #"{"a":""#) == "")
        #expect(PromptLookupDrafter.openStringValue(in: #"{"a":"x\"#) == nil)
    }

    @Test func promptBuilderPutsTheUtteranceFirst() {
        let request = PromptBuilder().request(
            session: SessionState(), utterance: "call mom", clock: .fixed(.init(timeIntervalSince1970: 0), timeZone: .gmt), maxOutputTokens: 64
        )
        #expect(request.draftSources.first == "call mom")
        #expect(request.draftSources.count == 2)
        #expect(request.suffix.contains(request.draftSources[1]))
        #expect(!request.draftSources[1].contains("<|im_"))
    }
}
