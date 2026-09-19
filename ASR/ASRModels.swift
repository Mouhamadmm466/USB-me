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
    /// Vocabulary prompt for the final pass (short commands such as "cancel" or "call mom" are
    /// otherwise misheard as "Console" / "Cool Mom"). Deliberately never contains "yes", "okay"
    /// or other affirmations: a prompt raises the chance Whisper emits its words from noise.
    public var domainPrompt: String? = "Voice commands: call, text, message, remind, cancel, schedule, open."
    /// Utterances shorter than this (seconds) whose text is a known Whisper hallucination are
    /// treated as empty.
    public var hallucinationGuardSeconds: Double = 1.2
    /// A final transcript that is only a known silence hallucination ("you", "Okay.") is dropped
    /// unless the speech gate finds at least this much speech in the clip.
    public var minimumSpeechMillisecondsForHallucinationPhrase: Double = 250

    public init() {}
}

/// Cleans Whisper output: removes non-speech annotations and known silence hallucinations.
public enum TranscriptCleaner {
    /// Phrases Whisper is known to emit on silence/noise.
    static let silenceHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching",
        "bye", "bye.", "you", "okay.", "so", "the end", "i'm sorry", "please subscribe",
    ]

    public static func clean(_ raw: String, audioSeconds: Double, guardSeconds: Double) -> String {
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
        if audioSeconds < guardSeconds, isKnownHallucination(text) {
            return ""
        }
        if normalized.isEmpty || normalized.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return "" }
        return text
    }

    /// True when the whole transcript is a phrase Whisper is known to produce from silence/noise.
    public static func isKnownHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        return !normalized.isEmpty && (silenceHallucinations.contains(normalized) || silenceHallucinations.contains(normalized + "."))
    }

    /// Builds Whisper's initial prompt from names so rare proper nouns are recognized.
    public static func biasPrompt(_ names: [String], limit: Int, domain: String? = nil) -> String? {
        let unique = Array(NSOrderedSet(array: names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .compactMap { $0 as? String }
        let contacts = unique.isEmpty ? nil : "Contacts: " + unique.prefix(limit).joined(separator: ", ") + "."
        let parts = [domain, contacts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
