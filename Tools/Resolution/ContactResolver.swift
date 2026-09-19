import Core
import Foundation

/// Resolves a spoken contact reference against the native contacts store.
struct ContactResolver {
    enum Outcome {
        case contact(ContactRecord)
        case clarification(reason: ClarificationReason, question: String, candidates: [ClarificationCandidate])
        case failure(ToolFailureCode)
    }

    /// Words that refer to the person just discussed ("call him back").
    static let pronouns: Set<String> = [
        "him", "her", "them", "he", "she", "they", "his", "hers", "their", "that person", "this person",
        "the same person", "same person", "that contact", "this contact", "the same contact", "same contact",
        "him again", "her again", "them again", "that guy", "this guy",
    ]

    /// Maximum candidates offered in an ambiguity clarification.
    static let maxCandidates = 8

    let store: any ContactsStore

    static func isPronoun(_ query: String) -> Bool {
        pronouns.contains(TextTokens.phrase(query))
    }

    /// Order: pinned selection (a contact id from a previous clarification), pronoun → the session's
    /// last contact, otherwise ranked name matching.
    func resolve(
        query: String?,
        pinned: ClarificationCandidate?,
        session: SessionState,
        purpose: ClarificationText.Purpose
    ) async -> Outcome {
        do {
            if let pinned, pinned.kind == .contact {
                if let contact = try await store.contact(identifier: pinned.identifier) { return .contact(contact) }
                return .clarification(
                    reason: .contactNotFound,
                    question: ClarificationText.contactNotFound(pinned.displayText, purpose: purpose),
                    candidates: []
                )
            }
            guard let query else {
                return .clarification(reason: .missingField, question: ClarificationText.whoTo(purpose), candidates: [])
            }
            if Self.isPronoun(query) {
                guard let last = session.lastContact else {
                    return .clarification(reason: .contactNotFound, question: ClarificationText.whoDoYouMean, candidates: [])
                }
                if let contact = try await store.contact(identifier: last.contactIdentifier) { return .contact(contact) }
                return .clarification(
                    reason: .contactNotFound,
                    question: ClarificationText.contactNotFound(last.displayName, purpose: purpose),
                    candidates: []
                )
            }
            let best = ContactMatcher.best(query: query, contacts: try await store.allContacts())
            switch best.count {
            case 0:
                return .clarification(
                    reason: .contactNotFound,
                    question: ClarificationText.contactNotFound(query, purpose: purpose),
                    candidates: []
                )
            case 1:
                return .contact(best[0].contact)
            default:
                let contacts = best.map(\.contact)
                return .clarification(
                    reason: .contactAmbiguous,
                    question: ClarificationText.contactAmbiguous(names: contacts.map(\.displayName), query: query),
                    candidates: Self.candidates(for: Array(contacts.prefix(Self.maxCandidates)))
                )
            }
        } catch {
            return .failure(ToolAdapterError.failureCode(for: error))
        }
    }

    /// Candidates whose display text tells duplicates apart ("Alex Kim, Acme" /
    /// "Alex Kim, mobile ending in 0101") and whose match terms include every name field.
    static func candidates(for contacts: [ContactRecord]) -> [ClarificationCandidate] {
        let folded = contacts.map { TextTokens.fold($0.displayName) }
        return contacts.enumerated().map { index, contact in
            let duplicates = contacts.indices.filter { folded[$0] == folded[index] }
            var display = contact.displayName
            var extraTerms: [String] = []
            if duplicates.count > 1 {
                let organizations = duplicates.map { TextTokens.fold(contacts[$0].organization) }
                let organization = contact.organization.trimmingCharacters(in: .whitespacesAndNewlines)
                if !organization.isEmpty, organizations.filter({ $0 == TextTokens.fold(organization) }).count == 1 {
                    display += ", \(organization)"
                } else if let phone = PhoneSelector.usablePhones(of: contact).first ?? contact.phones.first {
                    let lastFour = PhoneNumbers.lastFour(phone.number)
                    display += ", \(phone.label ?? "number") ending in \(lastFour)"
                    extraTerms += [lastFour, phone.label].compactMap { $0 }
                }
            }
            let terms = [contact.displayName, contact.givenName, contact.familyName, contact.nickname, contact.organization] + extraTerms
            var seen = Set<String>()
            let matchTerms = terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert(TextTokens.fold($0)).inserted }
            return ClarificationCandidate(kind: .contact, identifier: contact.identifier, displayText: display, matchTerms: matchTerms)
        }
    }
}
