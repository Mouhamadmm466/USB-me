import Core
import Foundation

/// Decoding settings for whisper.cpp (Whisper base.en). Stored as configuration so they can be
/// benchmarked (PRD §3.1, §6.5).
public struct ASRConfig: Codable, Sendable, Equatable {
    /// CPU threads for whisper.cpp (nil = platform default).
    public var threads: Int?
    /// Use Metal on devices that support it.
    public var useGPU: Bool = true
    /// Reduced encoder context for partial hypotheses (faster, slightly less accurate). 0 = full.
    public var partialAudioContext: Int = 768
    /// Max tokens for a partial hypothesis.
    public var partialMaxTokens: Int = 48
    /// Temperature fallback increment for the final pass (0 disables fallback).
    public var finalTemperatureIncrement: Float = 0.2
    /// Bias the final pass with up to this many contact names via Whisper's initial prompt.
    public var maxBiasNames: Int = 40
    /// Utterances shorter than this (seconds) whose text is a known Whisper hallucination are
    /// treated as empty.
    public var hallucinationGuardSeconds: Double = 1.2
    /// Above this no-speech probability a known silence hallucination ("you", "thank you") is
    /// dropped whatever the utterance length (Whisper emits them on noise and room tone).
    public var noSpeechThreshold: Float = 0.5

    public init() {}
}

/// Cleans Whisper output: removes non-speech annotations and known silence hallucinations.
public enum TranscriptCleaner {
    /// Phrases Whisper is known to emit on silence/noise.
    static let silenceHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching",
        "bye", "bye.", "you", "okay.", "so", "the end", "i'm sorry", "please subscribe",
    ]

    public static func clean(
        _ raw: String, audioSeconds: Double, guardSeconds: Double,
        noSpeechProbability: Float = 0, noSpeechThreshold: Float = 1
    ) -> String {
        var text = raw
        // Drop [BLANK_AUDIO], (music), *laughs* style annotations.
        for (open, close) in [("[", "]"), ("(", ")"), ("*", "*")] {
            while let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        let isKnownHallucination = silenceHallucinations.contains(normalized) || silenceHallucinations.contains(normalized + ".")
        if isKnownHallucination, audioSeconds < guardSeconds || noSpeechProbability > noSpeechThreshold {
            return ""
        }
        if normalized.isEmpty || normalized.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return "" }
        return text
    }

    /// Builds Whisper's initial prompt from names so rare proper nouns are recognized.
    public static func biasPrompt(_ names: [String], limit: Int) -> String? {
        let unique = Array(NSOrderedSet(array: names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .compactMap { $0 as? String }
        guard !unique.isEmpty else { return nil }
        return "Contacts: " + unique.prefix(limit).joined(separator: ", ") + "."
    }
}
