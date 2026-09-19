import Contacts
import Core
import Foundation

/// A contact as read from the native store. Only the fields the agent needs are fetched.
public struct ContactRecord: Codable, Sendable, Hashable, Identifiable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let nickname: String
    public let organization: String
    public let phones: [LabeledPhone]

    public var id: String { identifier }

    public init(
        identifier: String,
        givenName: String,
        familyName: String = "",
        nickname: String = "",
        organization: String = "",
        phones: [LabeledPhone] = []
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.phones = phones
    }

    /// "Given Family"; falls back to the nickname, then the organization.
    public var displayName: String {
        let personal = [givenName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !personal.isEmpty { return personal }
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { return nick }
        let org = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty { return org }
        return "Unnamed contact"
    }

    public var reference: ContactReference {
        ContactReference(contactIdentifier: identifier, displayName: displayName)
    }

    public var summary: ContactSummary {
        ContactSummary(contactIdentifier: identifier, displayName: displayName, phoneNumbers: phones)
    }
}

/// Read access to the user's contacts. Implementations must not block the main thread.
public protocol ContactsStore: Sendable {
    func allContacts() async throws -> [ContactRecord]
    func contact(identifier: String) async throws -> ContactRecord?
}

/// Maps Contacts framework phone labels to short spoken labels.
public enum ContactPhoneLabels {
    /// "mobile", "iPhone", "home", "work", "main", "other", "home fax", "work fax", "other fax",
    /// "pager", "Apple Watch"; custom labels are returned as the user typed them.
    public static func normalized(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        switch label {
        case CNLabelPhoneNumberMobile: return "mobile"
        case CNLabelPhoneNumberiPhone: return "iPhone"
        case CNLabelHome: return "home"
        case CNLabelWork: return "work"
        case CNLabelPhoneNumberMain: return "main"
        case CNLabelOther: return "other"
        case CNLabelPhoneNumberHomeFax: return "home fax"
        case CNLabelPhoneNumberWorkFax: return "work fax"
        case CNLabelPhoneNumberOtherFax: return "other fax"
        case CNLabelPhoneNumberPager: return "pager"
        case CNLabelPhoneNumberAppleWatch: return "Apple Watch"
        default:
            let localized = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: label)
            let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// `ContactsStore` over `CNContactStore`.
///
/// `@unchecked Sendable`: `store` is only ever used on the private serial `queue`, so it is never
/// accessed concurrently; everything returned is a value type.
public final class SystemContactsStore: ContactsStore, @unchecked Sendable {
    private let store: CNContactStore
    private let queue = DispatchQueue(label: "app.voiceagent.tools.contacts", qos: .userInitiated)

    public init() {
        store = CNContactStore()
    }

    private static func keysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]
    }

    static func record(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organization: contact.organizationName,
            phones: contact.phoneNumbers.map { labeled in
                LabeledPhone(label: ContactPhoneLabels.normalized(labeled.label), number: labeled.value.stringValue)
            }
        )
    }

    private static func adapterError(_ error: any Error) -> ToolAdapterError {
        guard let contactsError = error as? CNError else { return .systemFailure }
        switch contactsError.code {
        case .authorizationDenied: return .permissionDenied
        case .recordDoesNotExist: return .notFound
        default: return .systemFailure
        }
    }

    public func allContacts() async throws -> [ContactRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch())
                    request.unifyResults = true
                    request.sortOrder = .givenName
                    var records: [ContactRecord] = []
                    try self.store.enumerateContacts(with: request) { contact, _ in
                        records.append(Self.record(from: contact))
                    }
                    continuation.resume(returning: records)
                } catch {
                    continuation.resume(throwing: Self.adapterError(error))
                }
            }
        }
    }

    public func contact(identifier: String) async throws -> ContactRecord? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let contact = try self.store.unifiedContact(withIdentifier: identifier, keysToFetch: Self.keysToFetch())
                    continuation.resume(returning: Self.record(from: contact))
                } catch {
                    let mapped = Self.adapterError(error)
                    if mapped == .notFound {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: mapped)
                    }
                }
            }
        }
    }
}
