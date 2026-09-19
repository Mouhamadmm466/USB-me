import Core
import Foundation

/// A file found while enumerating a scope, before ranking.
public struct FileCandidate: Sendable, Hashable {
    public let reference: FileReference
    public let modifiedAt: Date?
    public let byteSize: Int64?

    public init(reference: FileReference, modifiedAt: Date?, byteSize: Int64?) {
        self.reference = reference
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
    }

    public var summary: FileSummary {
        FileSummary(reference: reference, modifiedAt: modifiedAt, byteSize: byteSize)
    }
}

/// Deterministic, case-insensitive file-name matching shared by the real and fake stores.
///
/// Query words must match words of the file name (exact, plural, prefix of ≥ 3 letters, or one
/// typo for words of ≥ 5 letters). File-type words ("pdf", "spreadsheet", "photo") match the
/// extension instead. Ranking: more matched words, all words matched, then name, then path.
public enum FileMatcher {
    static let stopwords: Set<String> = [
        "the", "a", "an", "my", "our", "file", "files", "document", "doc", "docs", "called", "named", "please",
        "open", "show", "find", "of", "for", "with", "and", "in", "on",
    ]
    /// Type words and the extensions they stand for.
    static let typeWords: [String: Set<String>] = [
        "pdf": ["pdf"],
        "spreadsheet": ["xlsx", "xls", "csv", "numbers", "tsv"],
        "excel": ["xlsx", "xls"],
        "csv": ["csv"],
        "presentation": ["pptx", "ppt", "key"],
        "slides": ["pptx", "ppt", "key"],
        "deck": ["pptx", "ppt", "key", "pdf"],
        "keynote": ["key"],
        "powerpoint": ["pptx", "ppt"],
        "word": ["docx", "doc"],
        "text": ["txt", "md", "rtf"],
        "note": ["txt", "md", "rtf"],
        "notes": ["txt", "md", "rtf"],
        "photo": ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff"],
        "picture": ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff"],
        "image": ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "webp"],
        "screenshot": ["png", "jpg", "jpeg", "heic"],
        "video": ["mov", "mp4", "m4v"],
        "audio": ["m4a", "mp3", "wav", "aac"],
        "recording": ["m4a", "mp3", "wav", "aac", "mov"],
        "zip": ["zip"],
        "archive": ["zip"],
    ]

    struct Terms: Equatable {
        let nameWords: [String]
        let typeExtensions: [Set<String>]
    }

    static func terms(of query: String) -> Terms {
        let words = TextTokens.fileNameWords(query)
        var nameWords: [String] = []
        var types: [Set<String>] = []
        for word in words {
            if let extensions = typeWords[word] {
                types.append(extensions)
            } else if !stopwords.contains(word), !nameWords.contains(word) {
                nameWords.append(word)
            }
        }
        // "the document" / "a file": nothing specific left, so use the stopwords themselves.
        if nameWords.isEmpty, types.isEmpty {
            nameWords = words.filter { !["the", "a", "an", "my", "please"].contains($0) }
        }
        return Terms(nameWords: nameWords, typeExtensions: types)
    }

    /// 3 = exact/plural, 2 = prefix (≥ 3 letters), 1 = one typo (≥ 5 letters), 0 = no match.
    static func wordScore(_ word: String, in nameWords: [String]) -> Int {
        let stemmed = TextTokens.stem(word)
        var best = 0
        for candidate in nameWords {
            if candidate == word || TextTokens.stem(candidate) == stemmed { return 3 }
            if word.count >= 3, candidate.hasPrefix(word) { best = max(best, 2) }
            if word.count >= 5, candidate.count >= 5, candidate.first == word.first,
               EditDistance.damerauLevenshtein(word, candidate) <= 1 {
                best = max(best, 1)
            }
        }
        return best
    }

    public static func rank(query: String, candidates: [FileCandidate], limit: Int) -> [FileMatch] {
        let terms = terms(of: query)
        guard !terms.nameWords.isEmpty || !terms.typeExtensions.isEmpty, limit > 0 else { return [] }

        let matches: [FileMatch] = candidates.compactMap { candidate in
            let name = candidate.reference.displayName
            let fileExtension = (name as NSString).pathExtension.lowercased()
            let base = (name as NSString).deletingPathExtension
            let nameWords = TextTokens.fileNameWords(base)

            var score = 0
            var matchedNameWords = 0
            for word in terms.nameWords {
                let points = wordScore(word, in: nameWords)
                if points > 0 {
                    score += points * 10
                    matchedNameWords += 1
                }
            }
            var typeMatched = true
            for extensions in terms.typeExtensions {
                if extensions.contains(fileExtension) {
                    score += 5
                } else {
                    typeMatched = false
                }
            }
            if terms.nameWords.isEmpty {
                // Type-only query ("the pdf"): the type must match.
                guard typeMatched, score > 0 else { return nil }
            } else if matchedNameWords == 0 {
                return nil
            }
            let allTerms = matchedNameWords == terms.nameWords.count && typeMatched
            return FileMatch(summary: candidate.summary, score: score + (allTerms ? 1_000 : 0), matchesAllTerms: allTerms)
        }

        let sorted = matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let leftName = TextTokens.fold(lhs.summary.reference.displayName)
            let rightName = TextTokens.fold(rhs.summary.reference.displayName)
            if leftName != rightName { return leftName < rightName }
            if lhs.summary.reference.scopeIdentifier != rhs.summary.reference.scopeIdentifier {
                return lhs.summary.reference.scopeIdentifier < rhs.summary.reference.scopeIdentifier
            }
            return lhs.summary.reference.relativePath < rhs.summary.reference.relativePath
        }
        return Array(sorted.prefix(limit))
    }
}
