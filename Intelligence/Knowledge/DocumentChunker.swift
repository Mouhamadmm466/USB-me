import Foundation

/// Cuts a parsed document into passages worth retrieving.
///
/// Headings first (a section is the unit a person would quote), then ~800-character windows on
/// sentence boundaries with a sentence of overlap, so an answer is never split across two passages
/// that each look irrelevant on their own. Deterministic: the same file always produces the same
/// chunks, which is what makes the retrieval evaluation meaningful.
public struct DocumentChunker: Sendable {
    public var targetCharacters: Int
    public var maximumCharacters: Int
    public var minimumCharacters: Int
    /// Characters of trailing context repeated at the start of the next passage.
    public var overlapCharacters: Int

    public init(
        targetCharacters: Int = 800,
        maximumCharacters: Int = 1_200,
        minimumCharacters: Int = 80,
        overlapCharacters: Int = 120
    ) {
        self.targetCharacters = targetCharacters
        self.maximumCharacters = maximumCharacters
        self.minimumCharacters = minimumCharacters
        self.overlapCharacters = overlapCharacters
    }

    public func chunks(of document: ParsedDocument, documentID: UUID) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        for page in document.pages {
            for section in sections(in: page.text) {
                for text in windows(of: section.text) {
                    chunks.append(DocumentChunk(
                        documentID: documentID, ordinal: chunks.count,
                        heading: section.heading, page: page.number, text: text
                    ))
                }
            }
        }
        // A document with one short paragraph still deserves one passage.
        if chunks.isEmpty {
            let text = document.pages.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(DocumentChunk(documentID: documentID, ordinal: 0, page: document.pages.first?.number, text: text))
            }
        }
        return chunks
    }

    struct Section: Equatable {
        var heading: String?
        var text: String
    }

    /// Splits on Markdown headings and on short standalone lines that read like titles.
    func sections(in text: String) -> [Section] {
        var sections: [Section] = []
        var heading: String?
        var body: [String] = []

        func flush() {
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeAll()
            guard !joined.isEmpty else { return }
            sections.append(Section(heading: heading, text: joined))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let title = Self.headingTitle(line) {
                flush()
                heading = title
            } else {
                body.append(String(rawLine))
            }
        }
        flush()
        return sections
    }

    /// "# Title", "## Title", or a short line in title case with no sentence punctuation.
    static func headingTitle(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        guard line.count <= 60, !line.hasSuffix("."), !line.hasSuffix(","), !line.hasSuffix(";") else { return nil }
        let words = line.split(separator: " ")
        guard words.count >= 1, words.count <= 8 else { return nil }
        let capitalized = words.filter { $0.first?.isUppercase == true || $0.first?.isNumber == true }
        // Mostly capitalized and no trailing punctuation: a heading, not a sentence.
        return Double(capitalized.count) / Double(words.count) >= 0.6 ? line : nil
    }

    /// Windows of roughly `targetCharacters`, cut on sentence boundaries, overlapping by whole
    /// sentences — never mid-word, so a passage always reads as something a person wrote.
    func windows(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

        var windows: [String] = []
        var current: [String] = []
        var carried = 0
        var length = 0

        /// Emits the window and keeps the last whole sentences that fit in the overlap.
        func flush() {
            let window = current.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !window.isEmpty else { return }
            windows.append(window)
            var carry: [String] = []
            var carryLength = 0
            for sentence in current.reversed() {
                guard carryLength + sentence.count <= overlapCharacters else { break }
                carry.insert(sentence, at: 0)
                carryLength += sentence.count
            }
            current = carry
            carried = carry.count
            length = carryLength
        }

        for sentence in Self.sentences(in: trimmed) {
            if length + sentence.count > maximumCharacters, current.count > carried { flush() }
            current.append(sentence)
            length += sentence.count
            if length >= targetCharacters { flush() }
        }

        // Whatever is left beyond the carried overlap is a passage of its own.
        if current.count > carried {
            let tail = current.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.count >= minimumCharacters { windows.append(tail) }
            else if var last = windows.popLast() {
                last += " " + tail
                windows.append(last)
            }
        }
        return windows
    }

    /// Sentence-ish splitting that keeps the terminator.
    ///
    /// A title ("Dr.", "Prof.") is always followed by a name, so it never ends a sentence. An
    /// abbreviation that can end one ("p.m.", "etc.") does when the next sentence starts as one.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            current.append(character)
            guard character == "." || character == "!" || character == "?" || character == "\n" else { continue }

            var lookahead: [Character] = []
            while let next = iterator.next() {
                lookahead.append(next)
                if next != " " { break }
            }
            let follower = lookahead.last
            if character == ".", let abbreviation = abbreviations.first(where: { current.hasSuffix($0) }) {
                let endsSentences = terminalAbbreviations.contains(abbreviation)
                let startsNew = follower.map { $0.isUppercase } ?? true
                if !endsSentences || !startsNew {
                    current += String(lookahead)
                    continue
                }
            }
            // Keep a closing quote or bracket with the sentence it ends.
            if let follower, follower == "\"" || follower == "'" || follower == ")" || follower == "\u{201D}" {
                current.append(follower)
            } else if let follower {
                pending = follower
            }
            current += String(lookahead.dropLast())
            sentences.append(current)
            current = ""
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    static let abbreviations = [
        "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Sr.", "Jr.", "St.", "vs.", "etc.", "e.g.", "i.e.",
        "Fig.", "No.", "Vol.", "p.", "pp.", "Inc.", "Ltd.", "Co.", "U.S.", "a.m.", "p.m.",
    ]

    /// Abbreviations that can legitimately end a sentence, unlike a title before a name.
    static let terminalAbbreviations: Set<String> = ["etc.", "a.m.", "p.m.", "U.S.", "Inc.", "Ltd.", "Co."]
}
