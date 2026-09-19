import Core
import Foundation

/// Which part of a contact's name a spoken query matched. Higher is better.
public enum ContactMatchTier: Int, Sendable, Comparable, CaseIterable {
    /// Query tokens matched several unrelated fields (e.g. nickname + organization).
    case mixed = 1
    case organization = 2
    case familyOnly = 3
    case givenOnly = 4
    case nickname = 5
    /// Personal name plus organization ("Alex at Acme").
    case nameAndOrganization = 6
    /// Given (or nickname) and family name, but not the whole name in order.
    case givenAndFamily = 7
    /// The whole name (or the whole display name for single-field contacts).
    case fullName = 8

    public static func < (lhs: ContactMatchTier, rhs: ContactMatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One ranked contact match. Two matches with equal `rank` are "equally good".
public struct ContactMatch: Sendable, Equatable {
    public struct Rank: Sendable, Hashable, Comparable {
        /// Every token matched exactly (or as a homophone).
        public let isExact: Bool
        public let tier: ContactMatchTier
        /// Sum of fuzzy token costs (0 for exact matches).
        public let cost: Int

        /// Better ranks compare greater.
        public static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.isExact != rhs.isExact { return !lhs.isExact }
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.cost > rhs.cost
        }
    }

    public let contact: ContactRecord
    public let rank: Rank
}

/// Deterministic ranking of contacts against a spoken name.
///
/// Every query token must be explained by some name field (given, family, nickname, organization);
/// a contact that leaves a spoken token unexplained is not a match. Matches are ordered by
/// exactness (exact/homophone above fuzzy), then tier (full name > given+family > nickname >
/// given > family > organization), then fuzzy cost; ties break by display name, then identifier.
public enum ContactMatcher {
    /// Words dropped from a spoken name when something else remains ("my", "Dr.", "Mrs.").
    static let fillerWords: Set<String> = [
        "my", "the", "a", "an", "mr", "mrs", "ms", "miss", "mister", "dr", "doctor", "prof", "professor", "please",
    ]
    static let maxQueryTokens = 6

    private enum Field: Int, Comparable {
        case given = 0, family, nickname, organization
        static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct FieldToken {
        let field: Field
        let position: Int
        let token: NameToken
    }

    public static func queryTokens(_ query: String) -> [String] {
        let words = TextTokens.words(query)
        let meaningful = words.filter { !fillerWords.contains($0) }
        return meaningful.isEmpty ? words : meaningful
    }

    /// All matching contacts, best first.
    public static func rank(query: String, contacts: [ContactRecord]) -> [ContactMatch] {
        let words = queryTokens(query)
        guard !words.isEmpty, words.count <= maxQueryTokens else { return [] }
        let spoken = words.map(NameToken.make)
        let matches = contacts.compactMap { contact -> ContactMatch? in
            match(spoken: spoken, contact: contact).map { ContactMatch(contact: contact, rank: $0) }
        }
        return matches.sorted(by: isOrderedBefore)
    }

    /// The best matches (all sharing the top rank).
    public static func best(query: String, contacts: [ContactRecord]) -> [ContactMatch] {
        let ranked = rank(query: query, contacts: contacts)
        guard let top = ranked.first?.rank else { return [] }
        return ranked.filter { $0.rank == top }
    }

    static func isOrderedBefore(_ lhs: ContactMatch, _ rhs: ContactMatch) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
        let leftName = TextTokens.fold(lhs.contact.displayName)
        let rightName = TextTokens.fold(rhs.contact.displayName)
        if leftName != rightName { return leftName < rightName }
        return lhs.contact.identifier < rhs.contact.identifier
    }

    // MARK: - Per-contact matching

    private static func fieldTokens(of contact: ContactRecord) -> [FieldToken] {
        var tokens: [FieldToken] = []
        let fields: [(Field, String)] = [
            (.given, contact.givenName), (.family, contact.familyName),
            (.nickname, contact.nickname), (.organization, contact.organization),
        ]
        for (field, text) in fields {
            for (position, word) in TextTokens.words(text).enumerated() {
                tokens.append(FieldToken(field: field, position: position, token: NameToken.make(word)))
            }
        }
        return tokens
    }

    private struct Assignment {
        var used: [Int] = []
        var kinds: [TokenMatchKind] = []
        var cost = 0
        var fieldPenalty = 0

        func isBetter(than other: Assignment?) -> Bool {
            guard let other else { return true }
            if cost != other.cost { return cost < other.cost }
            return fieldPenalty < other.fieldPenalty
        }
    }

    /// Optimal assignment of spoken tokens to distinct stored tokens (small exhaustive search).
    private static func assign(spoken: [NameToken], stored: [FieldToken]) -> Assignment? {
        // Candidate stored tokens per spoken token.
        let options: [[(index: Int, kind: TokenMatchKind)]] = spoken.map { token in
            stored.enumerated().compactMap { index, candidate in
                NameSimilarity.match(token, candidate.token).map { (index, $0) }
            }
        }
        if options.contains(where: \.isEmpty) { return nil }

        var best: Assignment?
        func search(_ depth: Int, _ current: Assignment) {
            if let best, current.cost > best.cost { return }
            if depth == spoken.count {
                if current.isBetter(than: best) { best = current }
                return
            }
            for option in options[depth] where !current.used.contains(option.index) {
                var next = current
                next.used.append(option.index)
                next.kinds.append(option.kind)
                next.cost += option.kind.cost
                next.fieldPenalty += stored[option.index].field.rawValue * 10 + stored[option.index].position
                search(depth + 1, next)
            }
        }
        search(0, Assignment())
        return best
    }

    private static func match(spoken: [NameToken], contact: ContactRecord) -> ContactMatch.Rank? {
        let stored = fieldTokens(of: contact)
        guard !stored.isEmpty, let assignment = assign(spoken: spoken, stored: stored) else { return nil }

        let usedFields = Set(assignment.used.map { stored[$0].field })
        func fieldFullyCovered(_ field: Field) -> Bool {
            let indices = stored.indices.filter { stored[$0].field == field }
            return !indices.isEmpty && indices.allSatisfy(assignment.used.contains)
        }
        func has(_ field: Field) -> Bool { stored.contains { $0.field == field } }

        let personal: Set<Field> = [.given, .family]
        // Stored tokens are ordered given, family, nickname, organization; an in-order assignment
        // means the name was said the way it is written ("Alex Kim", not "Kim Alex").
        let inOrder = assignment.used == assignment.used.sorted()
        let tier: ContactMatchTier
        if has(.given) || has(.family) {
            let personalCovered = (!has(.given) || fieldFullyCovered(.given)) && (!has(.family) || fieldFullyCovered(.family))
            if usedFields.isSubset(of: personal), personalCovered, inOrder {
                tier = .fullName
            } else if usedFields.isSubset(of: personal), personalCovered {
                // Whole name, said in a different order.
                tier = .givenAndFamily
            } else if usedFields.contains(.family), !usedFields.isDisjoint(with: [.given, .nickname]),
                      usedFields.isSubset(of: [.given, .family, .nickname]) {
                tier = .givenAndFamily
            } else if usedFields == [.nickname] {
                tier = .nickname
            } else if usedFields == [.given] {
                tier = .givenOnly
            } else if usedFields == [.family] {
                tier = .familyOnly
            } else if usedFields == [.organization] {
                tier = .organization
            } else if usedFields.contains(.organization), !usedFields.isDisjoint(with: [.given, .family, .nickname]) {
                tier = .nameAndOrganization
            } else {
                tier = .mixed
            }
        } else {
            // No personal name: the display name is the nickname, else the organization.
            let displayField: Field = has(.nickname) ? .nickname : .organization
            if usedFields == [displayField], fieldFullyCovered(displayField) {
                tier = .fullName
            } else if usedFields == [.nickname] {
                tier = .nickname
            } else if usedFields == [.organization] {
                tier = .organization
            } else {
                tier = .mixed
            }
        }
        return ContactMatch.Rank(
            isExact: assignment.kinds.allSatisfy(\.isExactClass),
            tier: tier,
            cost: assignment.cost
        )
    }
}
