import Foundation
import Synchronization

/// A folded name token with its precomputed phonetic features.
struct NameToken: Sendable, Hashable {
    let text: String
    let scalars: [UInt32]
    let phonetic: DoubleMetaphone.Code?
    let vowelSkeleton: String
    let isNumeric: Bool

    private static let encoder = DoubleMetaphone(maxLength: 8)
    /// Tokens repeat across contacts and across turns; features are computed once per spelling.
    private static let cache = Mutex<[String: NameToken]>([:])
    private static let cacheLimit = 50_000

    /// The token for a folded word, from the shared cache when possible.
    static func make(_ folded: String) -> NameToken {
        if let cached = cache.withLock({ $0[folded] }) { return cached }
        let token = NameToken(folded)
        cache.withLock { storage in
            if storage.count >= cacheLimit { storage.removeAll(keepingCapacity: true) }
            storage[folded] = token
        }
        return token
    }

    init(_ folded: String) {
        text = folded
        scalars = folded.unicodeScalars.map(\.value)
        phonetic = Self.encoder.encode(folded)
        vowelSkeleton = Self.skeleton(of: folded)
        isNumeric = !folded.isEmpty && folded.unicodeScalars.allSatisfy { $0.properties.numericType != nil }
    }

    /// Vowel letters in order, with a non-initial "y" treated as "i" ("Kym" -> "i", "Bryan" -> "ia").
    private static func skeleton(of token: String) -> String {
        var result = ""
        for (offset, character) in token.enumerated() {
            switch character {
            case "a", "e", "i", "o", "u": result.append(character)
            case "y" where offset > 0: result.append("i")
            default: break
            }
        }
        return result
    }
}

/// How well one spoken name token matches one stored name token.
enum TokenMatchKind: Sendable, Equatable {
    /// Identical after folding.
    case exact
    /// Spelled differently but pronounced the same ("Jon"/"John", "Kym"/"Kim", "Steven"/"Stephen").
    /// Treated exactly like `.exact`: speech recognition cannot tell these apart.
    case homophone
    /// Similar (ASR error, known diminutive). `cost` orders fuzzy matches (lower is better).
    case fuzzy(cost: Int)

    var cost: Int {
        switch self {
        case .exact, .homophone: 0
        case let .fuzzy(cost): cost
        }
    }

    var isExactClass: Bool {
        switch self {
        case .exact, .homophone: true
        case .fuzzy: false
        }
    }
}

enum NameSimilarity {
    /// Compares a spoken token with a stored token. Deterministic; nil when they do not match.
    ///
    /// Fuzzy costs: edit distance 1 + same sound = 1, edit distance 1 = 2, known diminutive = 2,
    /// edit distance 2 + same sound = 3, edit distance 2 = 4, same sound only = 4.
    /// Edit-distance thresholds: none for tokens of 1–2 characters, ≤ 1 for 3–5, ≤ 2 for ≥ 6.
    static func match(_ spoken: NameToken, _ stored: NameToken) -> TokenMatchKind? {
        if spoken.text == stored.text { return .exact }
        if spoken.isNumeric || stored.isNumeric { return nil }

        let shortest = min(spoken.scalars.count, stored.scalars.count)
        let longest = max(spoken.scalars.count, stored.scalars.count)
        var soundsAlike = false
        if shortest >= 3, let spokenCode = spoken.phonetic, let storedCode = stored.phonetic {
            soundsAlike = spokenCode.matches(storedCode)
        }

        if soundsAlike, spoken.vowelSkeleton == stored.vowelSkeleton {
            return .homophone
        }
        if Diminutives.related(spoken.text, stored.text) {
            return .fuzzy(cost: 2)
        }
        let threshold = shortest < 3 ? 0 : (longest >= 6 ? 2 : 1)
        // The distance is at least the length difference, so skip the matrix when that is too big.
        if threshold > 0, longest - shortest <= threshold {
            let sameInitial = spoken.scalars.first == stored.scalars.first
            if soundsAlike || sameInitial {
                let distance = EditDistance.damerauLevenshtein(spoken.scalars, stored.scalars)
                if distance <= threshold {
                    return .fuzzy(cost: distance * 2 - (soundsAlike ? 1 : 0))
                }
            }
        }
        if soundsAlike { return .fuzzy(cost: 4) }
        return nil
    }
}

/// Common English given-name diminutives ("Mike" ↔ "Michael"). Only formal ↔ diminutive (and
/// formal ↔ formal spelling variant) pairs are related; two diminutives of the same name ("Ed" /
/// "Ted", "Liz" / "Beth") are not. Only used as a fuzzy signal: an exact or nickname match always
/// ranks higher.
enum Diminutives {
    private struct Group {
        let formal: [String]
        let diminutives: [String]
    }

    private static let groups: [Group] = [
        Group(formal: ["abigail"], diminutives: ["abby", "abbie"]),
        Group(formal: ["alexander"], diminutives: ["alex", "xander", "sasha"]),
        Group(formal: ["alexandra"], diminutives: ["alex", "alexa", "lexi", "sasha"]),
        Group(formal: ["allison", "alison"], diminutives: ["ally", "allie"]),
        Group(formal: ["amanda"], diminutives: ["mandy"]),
        Group(formal: ["andrew"], diminutives: ["andy", "drew"]),
        Group(formal: ["anthony"], diminutives: ["tony"]),
        Group(formal: ["barbara"], diminutives: ["barb", "barbie"]),
        Group(formal: ["benjamin"], diminutives: ["ben", "benny"]),
        Group(formal: ["charles"], diminutives: ["charlie", "chuck"]),
        Group(formal: ["christopher"], diminutives: ["chris", "topher"]),
        Group(formal: ["christina", "christine"], diminutives: ["chris", "tina", "chrissy"]),
        Group(formal: ["cynthia"], diminutives: ["cindy"]),
        Group(formal: ["daniel"], diminutives: ["dan", "danny"]),
        Group(formal: ["danielle"], diminutives: ["dani"]),
        Group(formal: ["david"], diminutives: ["dave", "davey"]),
        Group(formal: ["deborah", "debra"], diminutives: ["debbie", "deb"]),
        Group(formal: ["dorothy"], diminutives: ["dot", "dottie"]),
        Group(formal: ["edward"], diminutives: ["ed", "eddie", "ted", "ned"]),
        Group(formal: ["elizabeth"], diminutives: ["liz", "lizzie", "beth", "betty", "eliza", "libby"]),
        Group(formal: ["frederick"], diminutives: ["fred", "freddie"]),
        Group(formal: ["gabriel"], diminutives: ["gabe"]),
        Group(formal: ["gregory"], diminutives: ["greg"]),
        Group(formal: ["jacob"], diminutives: ["jake"]),
        Group(formal: ["james"], diminutives: ["jim", "jimmy", "jamie"]),
        Group(formal: ["jeffrey", "geoffrey"], diminutives: ["jeff"]),
        Group(formal: ["jennifer"], diminutives: ["jen", "jenny"]),
        Group(formal: ["jessica"], diminutives: ["jess", "jessie"]),
        Group(formal: ["john"], diminutives: ["johnny", "jack"]),
        Group(formal: ["jonathan"], diminutives: ["jon", "jonny"]),
        Group(formal: ["joseph"], diminutives: ["joe", "joey"]),
        Group(formal: ["joshua"], diminutives: ["josh"]),
        Group(formal: ["katherine", "catherine", "kathryn", "katharine"], diminutives: ["kate", "katie", "kathy", "cathy", "kat"]),
        Group(formal: ["kathleen"], diminutives: ["kathy"]),
        Group(formal: ["kenneth"], diminutives: ["ken", "kenny"]),
        Group(formal: ["kimberly"], diminutives: ["kim"]),
        Group(formal: ["lawrence", "laurence"], diminutives: ["larry"]),
        Group(formal: ["leonard"], diminutives: ["leo", "len", "lenny"]),
        Group(formal: ["madeline", "madeleine"], diminutives: ["maddie", "maddy"]),
        Group(formal: ["margaret"], diminutives: ["maggie", "meg", "peggy"]),
        Group(formal: ["matthew"], diminutives: ["matt"]),
        Group(formal: ["michael"], diminutives: ["mike", "mikey", "mick"]),
        Group(formal: ["nathan", "nathaniel"], diminutives: ["nate", "nat"]),
        Group(formal: ["nicholas"], diminutives: ["nick", "nicky"]),
        Group(formal: ["nicole"], diminutives: ["nikki"]),
        Group(formal: ["olivia"], diminutives: ["liv"]),
        Group(formal: ["patricia"], diminutives: ["pat", "patty", "trish"]),
        Group(formal: ["patrick"], diminutives: ["pat", "paddy"]),
        Group(formal: ["peter"], diminutives: ["pete"]),
        Group(formal: ["raymond"], diminutives: ["ray"]),
        Group(formal: ["rebecca"], diminutives: ["becky", "becca"]),
        Group(formal: ["richard"], diminutives: ["rick", "ricky", "rich", "dick"]),
        Group(formal: ["robert"], diminutives: ["rob", "bob", "bobby", "robby", "bert"]),
        Group(formal: ["ronald"], diminutives: ["ron", "ronnie"]),
        Group(formal: ["samantha"], diminutives: ["sam", "sammy"]),
        Group(formal: ["samuel"], diminutives: ["sam", "sammy"]),
        Group(formal: ["stanley"], diminutives: ["stan"]),
        Group(formal: ["stephanie"], diminutives: ["steph"]),
        Group(formal: ["stephen", "steven"], diminutives: ["steve"]),
        Group(formal: ["susan"], diminutives: ["sue", "susie"]),
        Group(formal: ["theodore"], diminutives: ["theo", "ted", "teddy"]),
        Group(formal: ["thomas"], diminutives: ["tom", "tommy"]),
        Group(formal: ["timothy"], diminutives: ["tim", "timmy"]),
        Group(formal: ["victoria"], diminutives: ["vicky", "tori"]),
        Group(formal: ["vincent"], diminutives: ["vince"]),
        Group(formal: ["walter"], diminutives: ["walt"]),
        Group(formal: ["william"], diminutives: ["will", "bill", "billy", "liam"]),
        Group(formal: ["zachary"], diminutives: ["zach", "zack"]),
    ]

    /// name -> (group index, is formal)
    private static let memberships: [String: [(group: Int, formal: Bool)]] = {
        var map: [String: [(group: Int, formal: Bool)]] = [:]
        for (index, group) in groups.enumerated() {
            for name in group.formal { map[name, default: []].append((index, true)) }
            for name in group.diminutives { map[name, default: []].append((index, false)) }
        }
        return map
    }()

    static func related(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs, let left = memberships[lhs], let right = memberships[rhs] else { return false }
        return left.contains { leftEntry in
            right.contains { $0.group == leftEntry.group && ($0.formal || leftEntry.formal) }
        }
    }
}
