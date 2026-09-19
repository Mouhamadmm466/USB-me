import Core
import Foundation

/// In-memory contacts. Identifiers are exactly the ones given (e.g. fixture ids like "c-alex-kim").
public actor FakeContactsStore: ContactsStore {
    private var contacts: [ContactRecord]
    private var failure: ToolAdapterError?
    public private(set) var fetchCount = 0

    public init(contacts: [ContactRecord] = [], failure: ToolAdapterError? = nil) {
        self.contacts = contacts
        self.failure = failure
    }

    public func setContacts(_ contacts: [ContactRecord]) {
        self.contacts = contacts
    }

    /// Every subsequent read throws `failure` (nil clears it).
    public func setFailure(_ failure: ToolAdapterError?) {
        self.failure = failure
    }

    public func allContacts() async throws -> [ContactRecord] {
        fetchCount += 1
        if let failure { throw failure }
        return contacts
    }

    public func contact(identifier: String) async throws -> ContactRecord? {
        fetchCount += 1
        if let failure { throw failure }
        return contacts.first { $0.identifier == identifier }
    }
}
