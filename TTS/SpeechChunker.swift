import Core
import Foundation

/// Splits assistant text into speakable chunks (PRD §6.1: TTS begins from the first stable
/// semantic sentence/chunk). The first chunk is kept short so audio starts quickly; later chunks
/// follow sentence and clause boundaries so prosody stays natural.
public struct SpeechChunker: Sendable {
    public let firstChunkMaxWords: Int
    public let maxChunkWords: Int

    public init(config: TTSConfig = TTSConfig()) {
        firstChunkMaxWords = config.firstChunkMaxWords
        maxChunkWords = config.maxChunkWords
    }

    public func chunks(for text: String) -> [String] {
        let sentences = Self.sentences(in: SpeechTextNormalizer.normalize(text))
        var chunks: [String] = []
        for sentence in sentences {
            for piece in split(sentence, firstLimit: chunks.isEmpty ? firstChunkMaxWords : maxChunkWords) {
                // Merge short follow-up sentences into the previous chunk (not into the first one).
                if chunks.count > 1, let last = chunks.last,
                   Self.wordCount(last) + Self.wordCount(piece) <= maxChunkWords, Self.endsSentence(last) {
                    chunks[chunks.count - 1] = last + " " + piece
                } else {
                    chunks.append(piece)
                }
            }
        }
        return chunks.filter { !$0.isEmpty }
    }

    /// Splits a sentence longer than `firstLimit` words at clause boundaries, then at word
    /// boundaries; pieces after the first may be up to `maxChunkWords` long.
    func split(_ sentence: String, firstLimit: Int) -> [String] {
        guard Self.wordCount(sentence) > firstLimit else { return [sentence] }
        var pieces: [String] = []
        var remaining = sentence
        var currentLimit = firstLimit
        while Self.wordCount(remaining) > currentLimit {
            let words = remaining.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Prefer the last clause boundary (, ; : —) within the limit.
            var cut = -1
            for index in stride(from: min(currentLimit, words.count) - 1, through: 2, by: -1) {
                if let last = words[index].last, ",;:—–".contains(last) {
                    cut = index
                    break
                }
            }
            if cut < 0 { cut = min(currentLimit, words.count) - 1 }
            pieces.append(words[0...cut].joined(separator: " "))
            remaining = words[(cut + 1)...].joined(separator: " ")
            currentLimit = maxChunkWords
        }
        if !remaining.isEmpty { pieces.append(remaining) }
        return pieces
    }

    static func wordCount(_ text: String) -> Int {
        text.split(separator: " ", omittingEmptySubsequences: true).count
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’)")).last else { return false }
        return ".!?".contains(last)
    }

    /// Sentence segmentation that ignores abbreviations, decimals and times.
    static func sentences(in text: String) -> [String] {
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "a.m", "p.m", "no", "approx"]
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if ".!?".contains(character) {
                // Absorb closing quotes/brackets.
                while index + 1 < characters.count, "\"”’)".contains(characters[index + 1]) {
                    index += 1
                    current.append(characters[index])
                }
                let nextIsBoundary = index + 1 >= characters.count || characters[index + 1] == " "
                let previousWord = current.dropLast().split(separator: " ").last.map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".\"“")) } ?? ""
                let isDecimal = character == "." && index + 1 < characters.count && characters[index + 1].isNumber
                if nextIsBoundary, !isDecimal, !(character == "." && abbreviations.contains(previousWord)) {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}

/// Incremental chunker for streamed model speech: emits a chunk as soon as a complete sentence
/// (or a long-enough clause for the first chunk) is available.
public struct StreamingSpeechChunker: Sendable {
    private let chunker: SpeechChunker
    private var buffer = ""
    private var emittedCount = 0

    public init(chunker: SpeechChunker = SpeechChunker()) {
        self.chunker = chunker
    }

    /// Adds text and returns chunks that are now complete.
    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        let sentences = SpeechChunker.sentences(in: buffer)
        guard sentences.count > 1 || (sentences.first.map(SpeechChunker.endsSentence) ?? false) else {
            // First chunk may be emitted early at a clause boundary once it is long enough.
            if emittedCount == 0, let first = sentences.first,
               SpeechChunker.wordCount(first) >= chunker.firstChunkMaxWords,
               let comma = first.lastIndex(where: { ",;:".contains($0) }) {
                let chunk = String(first[...comma]).trimmingCharacters(in: .whitespaces)
                buffer = String(first[first.index(after: comma)...])
                emittedCount += 1
                return [chunk]
            }
            return []
        }
        let complete = SpeechChunker.endsSentence(buffer.trimmingCharacters(in: .whitespaces)) ? sentences : Array(sentences.dropLast())
        buffer = SpeechChunker.endsSentence(buffer.trimmingCharacters(in: .whitespaces)) ? "" : (sentences.last ?? "")
        emittedCount += complete.count
        return complete.map(SpeechTextNormalizer.normalize)
    }

    /// Flushes whatever remains at the end of the stream.
    public mutating func finish() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespaces)
        buffer = ""
        return rest.isEmpty ? [] : chunker.chunks(for: rest)
    }
}

/// Prepares text for the phonemizer: reads phone numbers digit by digit, drops symbols TTS
/// would read literally, and normalizes quotes.
public enum SpeechTextNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "–", with: " to ")
            .replacingOccurrences(of: "…", with: "...")
        result = spellPhoneNumbers(result)
        result = String(String.UnicodeScalarView(result.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }))
        return result.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    /// "555-010-4477" → "5 5 5, 0 1 0, 4 4 7 7" so digits are read one at a time.
    static func spellPhoneNumbers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\+?\d{1,3}?[ -]?\(?\d{3}\)?[ -]\d{3}-\d{4}|\b\d{3}-\d{4}\b"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let groups = result[range]
                .split(whereSeparator: { " -()".contains($0) })
                .map { $0.filter(\.isNumber).map(String.init).joined(separator: " ") }
                .filter { !$0.isEmpty }
            result.replaceSubrange(range, with: groups.joined(separator: ", "))
        }
        return result
    }
}
