import Contacts
import Core
import Foundation
import Testing
@testable import Tools

/// Mapping from native framework objects to the module's value types (no OS permission needed).
@Suite struct NativeAdapterMappingTests {
    @Test func contactsLabelsMapToShortSpokenLabels() {
        #expect(ContactPhoneLabels.normalized(CNLabelPhoneNumberMobile) == "mobile")
        #expect(ContactPhoneLabels.normalized(CNLabelPhoneNumberiPhone) == "iPhone")
        #expect(ContactPhoneLabels.normalized(CNLabelHome) == "home")
        #expect(ContactPhoneLabels.normalized(CNLabelWork) == "work")
        #expect(ContactPhoneLabels.normalized(CNLabelPhoneNumberMain) == "main")
        #expect(ContactPhoneLabels.normalized(CNLabelOther) == "other")
        #expect(ContactPhoneLabels.normalized(CNLabelPhoneNumberWorkFax) == "work fax")
        #expect(ContactPhoneLabels.normalized(CNLabelPhoneNumberPager) == "pager")
        #expect(ContactPhoneLabels.normalized("Grandma's cell") == "Grandma's cell")
        #expect(ContactPhoneLabels.normalized(nil) == nil)
        #expect(ContactPhoneLabels.normalized("") == nil)
    }

    @Test func contactRecordsCarryOnlyTheFetchedFields() {
        let contact = CNMutableContact()
        contact.givenName = "Alex"
        contact.familyName = "Kim"
        contact.nickname = "AK"
        contact.organizationName = "Acme"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberiPhone, value: CNPhoneNumber(stringValue: "(555) 010-1001")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "555-010-2002")),
        ]
        let record = SystemContactsStore.record(from: contact)
        #expect(record.identifier == contact.identifier)
        #expect(record.displayName == "Alex Kim")
        #expect(record.nickname == "AK")
        #expect(record.organization == "Acme")
        #expect(record.phones == [
            LabeledPhone(label: "iPhone", number: "(555) 010-1001"),
            LabeledPhone(label: "work", number: "555-010-2002"),
        ])
        // iPhone counts as mobile when choosing a number.
        #expect(PhoneSelector.select(from: record, requestedLabel: nil, pinned: nil) == .selected(record.phones[0]))
    }

    @Test func displayNameFallsBackToNicknameThenOrganization() {
        #expect(ContactRecord(identifier: "a", givenName: "", nickname: "Mom").displayName == "Mom")
        #expect(ContactRecord(identifier: "b", givenName: "", organization: "Acme Dental").displayName == "Acme Dental")
        #expect(ContactRecord(identifier: "c", givenName: " ").displayName == "Unnamed contact")
    }

    @Test func eventKitAdapterErrorsAreContentFree() {
        #expect(SystemEventKitStore.adapterError(CocoaError(.fileNoSuchFile)) == .systemFailure)
        #expect(ToolAdapterError.failureCode(for: ToolAdapterError.outsideScope) == .invalidArguments)
        #expect(ToolAdapterError.failureCode(for: CancellationError()) == .timeout)
        #expect(ToolAdapterError.scopeNotFound.failureCode == .noAuthorizedScope)
    }
}
