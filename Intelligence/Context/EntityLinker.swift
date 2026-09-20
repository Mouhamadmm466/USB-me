import Foundation

public struct LinkedEntity: Sendable, Equatable {
    public var entity: IntelligenceEntity
    /// The words in the utterance that matched, as the user said them.
    public var matched: String
    /// Longer matches are better evidence: "beta launch" beats "beta".
    public var words: Int
}

/// A date the user named in passing ("Friday", "tomorrow"), and the window it covers.
public struct LinkedTime: Sendable, Equatable {
    public var phrase: String
    public var start: Date
    public var end: Date
}

/// Finds the parts of the user's world that the utterance is actually about.
///
/// Deterministic and bounded: the utterance is cut into short word runs, each folded and looked up
/// against the indexed titles and aliases, longest first. No fuzzy matching, no model call — a
/// sentence that names nothing known links to nothing, which is what keeps ordinary commands on
/// V1's fast path.
public struct EntityLinker: Sendable {
    public let store: IntelligenceStore
    public var dates: any DatePhraseResolving
    public var maximumWords: Int
    public var maximumEntities: Int

    public init(
        store: IntelligenceStore,
        dates: any DatePhraseResolving,
        maximumWords: Int = 6,
        maximumEntities: Int = 6
    ) {
        self.store = store
        self.dates = dates
        self.maximumWords = maximumWords
        self.maximumEntities = maximumEntities
    }

    public func link(_ utterance: String, now: Date = Date()) async throws -> [LinkedEntity] {
        let words = Self.words(in: utterance)
        guard !words.isEmpty else { return [] }
        let runs = Self.runs(of: words, upTo: maximumWords)
        let candidates = try await store.entitiesNamed(runs.map(\.text))
        guard !candidates.isEmpty else { return [] }

        var byName: [String: [IntelligenceEntity]] = [:]
        for entity in candidates {
            for name in entity.searchNames {
                byName[name.intelligenceFolded, default: []].append(entity)
            }
        }

        var linked: [LinkedEntity] = []
        var claimed = Set<Int>()
        // Longest runs first: "beta launch" wins over "beta", and each word is used once.
        for run in runs.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.start < $1.start }) {
            guard let matches = byName[run.text.intelligenceFolded], !matches.isEmpty else { continue }
            let span = Set(run.start..<(run.start + run.count))
            guard span.isDisjoint(with: claimed) else { continue }
            claimed.formUnion(span)
            for entity in matches where !linked.contains(where: { $0.entity.id == entity.id }) {
                linked.append(LinkedEntity(entity: entity, matched: run.text, words: run.count))
            }
        }
        return Array(
            linked.sorted { ($0.words, $0.entity.importance) > ($1.words, $1.entity.importance) }
                .prefix(maximumEntities)
        )
    }

    /// Dates the user named, resolved by the same parser the tools use.
    public func linkTime(_ utterance: String, now: Date = Date(), calendar: Calendar = .current) -> LinkedTime? {
        let words = Self.words(in: utterance)
        for run in Self.runs(of: words, upTo: 3).sorted(by: { $0.count > $1.count }) {
            guard let date = dates.resolve(run.text, now: now) else { continue }
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
            return LinkedTime(phrase: run.text, start: start, end: end)
        }
        return nil
    }

    // MARK: - Word runs

    struct Run: Sendable {
        var text: String
        var start: Int
        var count: Int
    }

    static func words(in utterance: String) -> [String] {
        utterance
            .replacingOccurrences(of: "[^\\p{L}\\p{N}' ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { word -> String in
                // "sarah chen's deck" has to reach "Sarah Chen": the possessive belongs to the
                // sentence, not to the name.
                var word = String(word)
                for suffix in ["'s", "'s", "'", "'"] where word.count > suffix.count && word.hasSuffix(suffix) {
                    word = String(word.dropLast(suffix.count))
                    break
                }
                return word
            }
            .filter { !$0.isEmpty }
    }

    /// Every 1…`maximum`-word run in the sentence, deduplicated and bounded so a long utterance
    /// cannot turn into an unbounded query.
    static func runs(of words: [String], upTo maximum: Int, limit: Int = 240) -> [Run] {
        var runs: [Run] = []
        var seen = Set<String>()
        for length in 1...max(1, maximum) where length <= words.count {
            for start in 0...(words.count - length) {
                let text = words[start..<(start + length)].joined(separator: " ")
                guard seen.insert(text.intelligenceFolded).inserted else { continue }
                runs.append(Run(text: text, start: start, count: length))
                if runs.count >= limit { return runs }
            }
        }
        return runs
    }
}
