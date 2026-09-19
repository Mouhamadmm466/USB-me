import Core
import Foundation
import Testing
@testable import Agent

@Suite struct ConfirmationLeadTests {
    @Test func recipientIsReadyOnceItsValueIsClosed() {
        let head = #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex"#
        #expect(ConfirmationLead.messageRecipient(in: head) == nil)
        #expect(ConfirmationLead.messageRecipient(in: head + " Kim") == nil)
        #expect(ConfirmationLead.messageRecipient(in: head + " Kim\"") == "Alex Kim")
        #expect(ConfirmationLead.messageRecipient(in: head + " Kim\",\"message\":\"I'll") == "Alex Kim")
    }

    @Test func onlyMessageProposals() {
        #expect(ConfirmationLead.messageRecipient(in: #"{"type":"proposed_action","tool":"initiate_call","arguments":{"contact_query":"Mom""#) == nil)
        #expect(ConfirmationLead.messageRecipient(in: #"{"type":"answer","speech":"contact_query"#) == nil)
    }

    @Test func escapedOrEmptyValuesAreLeftToThePipeline() {
        #expect(ConfirmationLead.messageRecipient(in: #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Al\"ex""#) == nil)
        #expect(ConfirmationLead.messageRecipient(in: #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"""#) == nil)
    }
}
