import Core
import Foundation
import Telemetry

/// Barge-in tunables not (yet) in `EndpointingConfig`; see the report for the proposed fields.
public struct BargeInSettings: Sendable, Equatable {
    /// After playback stops, frames this long are still treated as possible echo (room
    /// reverberation, acoustic path, AEC re-convergence).
    public var echoTailMilliseconds = 250
    /// A candidate without a verdict from `evaluate` is resolved after this long.
    public var candidateTimeoutMilliseconds = 1_500
    /// On timeout, confirm if strong speech (≥ the barge-in threshold) lasted this long after
    /// the candidate, i.e. the user kept talking over the ducked assistant; otherwise reject.
    public var persistentSpeechMilliseconds = 700
    /// After a rejection no new candidate starts for this long, so one long echo phrase does not
    /// make the assistant pump between ducked and unducked.
    public var rejectionCooldownMilliseconds = 300
    /// Transcripts with fewer words are rejected unless they contain an interruption keyword
    /// that the assistant is not itself saying.
    public var minimumTranscriptWords = 2
    /// Without a keyword, a transcript needs at least this many words the assistant is not
    /// saying: faint residual echo decodes to fragments of the reply plus one garbled word
    /// ("is the day"), a real interruption to new content ("call mom instead").
    public var minimumNovelWords = 2
    public var interruptionKeywords: Set<String> = [
        "stop", "wait", "cancel", "no", "nope", "yes", "yeah", "yep", "pause", "quiet", "enough",
        "hold", "hang", "hey", "actually", "nevermind", "never", "sorry", "excuse",
    ]
    /// Normalised transcripts that ASR produces on noise, music or silence; never a barge-in.
    public var ignoredTranscripts: Set<String> = [
        "you", "thank you", "thanks", "thank you for watching", "thanks for watching", "bye", "bye bye",
        "so", "the", "uh", "um", "hmm", "mm", "oh", "ah", "blank audio", "music", "silence", "inaudible",
    ]

    public init() {}
}

public struct BargeInCandidate: Sendable, Equatable {
    /// Pre-roll + onset audio: run the quick partial ASR on this.
    public let audio: [Float]
    public let utteranceStartTime: TimeInterval
    public let speechStartTime: TimeInterval
    /// Frame time at which the candidate was raised.
    public let detectedAt: TimeInterval
}

public struct BargeInConfirmation: Sendable, Equatable {
    public enum Reason: String, Sendable, CaseIterable, SafeLabelConvertible {
        /// The transcript differs from what the assistant is saying.
        case distinctSpeech
        /// The transcript contains an interruption keyword ("stop", "wait", "no"…) the
        /// assistant is not saying.
        case interruptionKeyword
        /// No verdict in time, but the user kept talking over the ducked assistant.
        case persistentSpeech
    }

    public let reason: Reason
    /// Echo similarity of the transcript (nil when decided without one).
    public let similarity: Double?
    /// Everything captured since the candidate's pre-roll: the start of the new utterance.
    public let audio: [Float]
    public let utteranceStartTime: TimeInterval
    public let speechStartTime: TimeInterval
}

public struct BargeInRejection: Sendable, Equatable {
    public enum Reason: String, Sendable, CaseIterable, SafeLabelConvertible {
        /// The transcript is (mostly) the assistant's own words.
        case echo
        case emptyTranscript
        /// A known ASR hallucination ("thank you", "you", "[BLANK_AUDIO]"…).
        case ignoredTranscript
        case tooShort
        /// No verdict in time and no sustained speech.
        case timeout
        /// `evaluate` was called with no candidate pending (stale verdict; nothing to undo).
        case noCandidate
    }

    public let reason: Reason
    public let similarity: Double?
}

public enum BargeInEvent: Sendable, Equatable {
    /// Possible barge-in: duck TTS and run a quick ASR partial on `candidate.audio`, then call
    /// `evaluate(candidateTranscript:assistantText:)`.
    case candidate(BargeInCandidate)
    /// Stop TTS now; continue the user's utterance from `audio`
    /// (`EndpointDetector.adoptUtterance`).
    case confirmedBargeIn(BargeInConfirmation)
    /// It was the assistant's own voice (or nothing): unduck and keep speaking.
    case rejectedEcho(BargeInRejection)

    public enum PlaybackCommand: String, Sendable, Equatable {
        case duck
        case stop
        case unduck
    }

    /// What the caller must do to TTS playback in response to this event.
    public var playbackCommand: PlaybackCommand {
        switch self {
        case .candidate: .duck
        case .confirmedBargeIn: .stop
        case .rejectedEcho: .unduck
        }
    }
}

/// Counters for false-barge-in / self-transcription metrics (content-free).
public struct BargeInCounters: Sendable, Equatable, Codable {
    public var candidates = 0
    public var confirmed = 0
    public var confirmedByKeyword = 0
    public var confirmedByPersistence = 0
    public var rejectedEcho = 0
    public var rejectedShortOrEmpty = 0
    public var rejectedTimeout = 0
    /// Confirmed barge-ins whose new utterance turned out empty or echo-like
    /// (reported through `recordBargeInOutcome`).
    public var falseBargeIns = 0

    public init() {}

    public var falseBargeInRate: Double {
        confirmed > 0 ? Double(falseBargeIns) / Double(confirmed) : 0
    }
}

/// Barge-in logic while the assistant speaks (PRD §6.3/6.4). Pure value type; the caller owns
/// the audio side effects, driven by `BargeInEvent.playbackCommand`:
///
/// 1. Frames arrive through `process(probability:frame:)`. While the assistant is speaking —
///    explicit TTS state from `assistantDidStartSpeaking`/`assistantDidStopSpeaking`, the
///    engine's `assistantWasSpeaking` flag, or the echo tail after playback — an internal
///    `EndpointDetector` in barge-in mode applies the strict thresholds
///    (`bargeInSpeechThreshold` for `bargeInMinSpeechMilliseconds`, adjusted by route echo risk).
/// 2. `.candidate` → caller ducks TTS (~0.25 volume) and runs a quick ASR partial on the
///    candidate audio. Frames keep flowing and are appended to the candidate audio.
/// 3. `evaluate(candidateTranscript:assistantText:)` → `.confirmedBargeIn` (stop TTS, keep the
///    audio as the start of the new utterance) or `.rejectedEcho` (unduck). Empty, hallucinated
///    or too-short transcripts are rejected; otherwise the transcript is compared with the text
///    being spoken (`TranscriptSimilarity.echoSimilarity`, threshold `echoSimilarityThreshold`).
/// 4. No verdict within `candidateTimeoutMilliseconds` → confirmed only if the user kept
///    talking (`persistentSpeechMilliseconds` of strong speech), else rejected.
public struct EchoBargeInController: Sendable {
    public enum Phase: String, Sendable, Equatable {
        /// Assistant silent and outside the echo tail: frames are ignored.
        case idle
        /// Watching for a strict onset.
        case monitoring
        /// A candidate awaits `evaluate`.
        case candidate
    }

    private struct PendingCandidate: Sendable {
        var audio: [Float]
        let utteranceStartTime: TimeInterval
        let speechStartTime: TimeInterval
        let detectedAt: TimeInterval
        var elapsedSamples = 0
        var strongSpeechSamples = 0
    }

    public let config: EndpointingConfig
    public let settings: BargeInSettings
    public let sampleRate: Double
    public private(set) var phase: Phase = .idle
    public private(set) var counters = BargeInCounters()
    public private(set) var isAssistantSpeaking = false
    /// Text the assistant is currently speaking (set by `assistantDidStartSpeaking`).
    public private(set) var assistantText = ""
    public private(set) var echoRisk: EchoRisk

    private var detector: EndpointDetector
    private let logger: PrivacySafeLogger?
    private var tailRemainingSamples = 0
    private var cooldownRemainingSamples = 0
    /// Cleared after a confirmed barge-in: the engine keeps flagging frames for the echo tail
    /// after `stopPlayback`, but those frames are now the user's own speech.
    private var honorsFrameFlag = true
    private var pending: PendingCandidate?

    public init(
        config: EndpointingConfig = .init(),
        settings: BargeInSettings = .init(),
        echoRisk: EchoRisk = .high,
        sampleRate: Double = AudioFrame.sampleRate,
        logger: PrivacySafeLogger? = .shared
    ) {
        self.config = config
        self.settings = settings
        self.echoRisk = echoRisk
        self.sampleRate = sampleRate
        self.logger = logger
        detector = EndpointDetector(config: Self.detectorConfig(config, echoRisk: echoRisk), mode: .bargeIn, sampleRate: sampleRate)
    }

    /// True while frames must be fed to `process`: the assistant is speaking, the echo tail is
    /// running, or a candidate awaits its verdict (its audio keeps growing and its timeout is
    /// counted in frames, even after playback ended).
    public var isArmed: Bool { isAssistantSpeaking || tailRemainingSamples > 0 || pending != nil }

    /// Effective strict threshold for the current echo risk.
    public var effectiveSpeechThreshold: Float { detector.config.bargeInSpeechThreshold }
    /// Effective strict minimum speech duration for the current echo risk.
    public var effectiveMinSpeechMilliseconds: Int { detector.config.bargeInMinSpeechMilliseconds }

    // MARK: - Assistant (TTS) state

    public mutating func assistantDidStartSpeaking(text: String) {
        isAssistantSpeaking = true
        assistantText = text
        honorsFrameFlag = true
        tailRemainingSamples = 0
        if phase == .idle { phase = .monitoring }
    }

    /// Playback ended or was stopped; the echo tail starts now.
    public mutating func assistantDidStopSpeaking() {
        guard isAssistantSpeaking else { return }
        isAssistantSpeaking = false
        tailRemainingSamples = EndpointDetector.samples(settings.echoTailMilliseconds, sampleRate)
    }

    /// Route changed: high echo risk (loudspeaker) uses the configured barge-in thresholds;
    /// low risk (headphones, HFP headsets) relaxes them halfway towards the normal ones.
    public mutating func setEchoRisk(_ risk: EchoRisk) {
        guard risk != echoRisk else { return }
        echoRisk = risk
        detector = EndpointDetector(config: Self.detectorConfig(config, echoRisk: risk), mode: .bargeIn, sampleRate: sampleRate)
    }

    // MARK: - Frames

    public mutating func process(probability: Float, frame: AudioFrame) -> BargeInEvent? {
        let count = frame.samples.count
        let armed = isAssistantSpeaking || tailRemainingSamples > 0 || (honorsFrameFlag && frame.assistantWasSpeaking)
        if !isAssistantSpeaking, tailRemainingSamples > 0 {
            tailRemainingSamples = max(0, tailRemainingSamples - count)
        }

        if pending != nil {
            pending?.audio.append(contentsOf: frame.samples)
            pending?.elapsedSamples += count
            if probability >= detector.config.bargeInSpeechThreshold {
                pending?.strongSpeechSamples += count
            }
            if let elapsed = pending?.elapsedSamples,
               elapsed >= EndpointDetector.samples(settings.candidateTimeoutMilliseconds, sampleRate) {
                return resolveTimeout()
            }
            return nil
        }

        if cooldownRemainingSamples > 0 {
            cooldownRemainingSamples = max(0, cooldownRemainingSamples - count)
            return nil
        }

        guard armed else {
            if phase != .idle {
                phase = .idle
                detector.reset()
            }
            return nil
        }
        phase = .monitoring

        guard case let .speechStarted(onset) = detector.process(probability: probability, frame: frame) else {
            return nil
        }
        let candidate = BargeInCandidate(
            audio: detector.currentUtteranceAudio,
            utteranceStartTime: onset.utteranceStartTime,
            speechStartTime: onset.speechStartTime,
            detectedAt: onset.confirmedAt
        )
        pending = PendingCandidate(
            audio: candidate.audio,
            utteranceStartTime: candidate.utteranceStartTime,
            speechStartTime: candidate.speechStartTime,
            detectedAt: candidate.detectedAt
        )
        detector.reset()
        phase = .candidate
        counters.candidates += 1
        log("candidate")
        return .candidate(candidate)
    }

    // MARK: - Verdict

    /// Decides a pending candidate from its quick ASR transcript and the text being spoken.
    public mutating func evaluate(candidateTranscript: String, assistantText: String) -> BargeInEvent {
        guard let candidate = pending else {
            return .rejectedEcho(BargeInRejection(reason: .noCandidate, similarity: nil))
        }
        let words = TranscriptSimilarity.normalizedWords(candidateTranscript)
        let reference = TranscriptSimilarity.normalizedWords(assistantText)
        let similarity = TranscriptSimilarity.echoSimilarity(candidateWords: words, referenceWords: reference)

        if words.isEmpty {
            return reject(.emptyTranscript, similarity: similarity)
        }
        if settings.ignoredTranscripts.contains(words.joined(separator: " ")) {
            return reject(.ignoredTranscript, similarity: similarity)
        }
        let spoken = Set(reference)
        if words.contains(where: { settings.interruptionKeywords.contains($0) && !spoken.contains($0) }) {
            return confirm(candidate, reason: .interruptionKeyword, similarity: similarity)
        }
        if words.count < settings.minimumTranscriptWords {
            return reject(.tooShort, similarity: similarity)
        }
        if similarity >= config.echoSimilarityThreshold {
            return reject(.echo, similarity: similarity)
        }
        let novelWords = words.count - TranscriptSimilarity.align(words, to: reference).matches
        if novelWords < settings.minimumNovelWords {
            return reject(.echo, similarity: similarity)
        }
        return confirm(candidate, reason: .distinctSpeech, similarity: similarity)
    }

    /// After a confirmed barge-in, report the final transcript of the new utterance. Empty,
    /// hallucinated or echo-like results count as a false barge-in (the assistant was cut off
    /// by its own voice). Returns true if it was false.
    @discardableResult
    public mutating func recordBargeInOutcome(finalTranscript: String, assistantText: String) -> Bool {
        let words = TranscriptSimilarity.normalizedWords(finalTranscript)
        let reference = TranscriptSimilarity.normalizedWords(assistantText)
        let isFalse = words.isEmpty
            || settings.ignoredTranscripts.contains(words.joined(separator: " "))
            || TranscriptSimilarity.echoSimilarity(candidateWords: words, referenceWords: reference) >= config.echoSimilarityThreshold
        if isFalse {
            counters.falseBargeIns += 1
            log("false_positive")
        }
        return isFalse
    }

    /// Forgets any candidate and the speaking state (counters are kept).
    public mutating func reset() {
        phase = .idle
        pending = nil
        isAssistantSpeaking = false
        assistantText = ""
        tailRemainingSamples = 0
        cooldownRemainingSamples = 0
        honorsFrameFlag = true
        detector.reset()
    }

    public mutating func resetCounters() {
        counters = BargeInCounters()
    }

    // MARK: - Internals

    private mutating func resolveTimeout() -> BargeInEvent? {
        guard let candidate = pending else { return nil }
        if candidate.strongSpeechSamples >= EndpointDetector.samples(settings.persistentSpeechMilliseconds, sampleRate) {
            return confirm(candidate, reason: .persistentSpeech, similarity: nil)
        }
        return reject(.timeout, similarity: nil)
    }

    private mutating func confirm(
        _ candidate: PendingCandidate,
        reason: BargeInConfirmation.Reason,
        similarity: Double?
    ) -> BargeInEvent {
        pending = nil
        phase = .idle
        isAssistantSpeaking = false
        tailRemainingSamples = 0
        honorsFrameFlag = false
        detector.reset()
        counters.confirmed += 1
        switch reason {
        case .distinctSpeech:
            log("confirmed")
        case .interruptionKeyword:
            counters.confirmedByKeyword += 1
            log("confirmed_keyword")
        case .persistentSpeech:
            counters.confirmedByPersistence += 1
            log("timeout_confirmed")
        }
        return .confirmedBargeIn(BargeInConfirmation(
            reason: reason,
            similarity: similarity,
            audio: candidate.audio,
            utteranceStartTime: candidate.utteranceStartTime,
            speechStartTime: candidate.speechStartTime
        ))
    }

    private mutating func reject(_ reason: BargeInRejection.Reason, similarity: Double?) -> BargeInEvent {
        pending = nil
        phase = isArmed ? .monitoring : .idle
        cooldownRemainingSamples = EndpointDetector.samples(settings.rejectionCooldownMilliseconds, sampleRate)
        detector.reset()
        switch reason {
        case .echo:
            counters.rejectedEcho += 1
            log("echo_rejected")
        case .emptyTranscript:
            counters.rejectedShortOrEmpty += 1
            log("empty_rejected")
        case .ignoredTranscript:
            counters.rejectedShortOrEmpty += 1
            log("hallucination_rejected")
        case .tooShort:
            counters.rejectedShortOrEmpty += 1
            log("short_rejected")
        case .timeout:
            counters.rejectedTimeout += 1
            log("timeout_rejected")
        case .noCandidate:
            break
        }
        return .rejectedEcho(BargeInRejection(reason: reason, similarity: similarity))
    }

    private func log(_ outcome: SafeLabel) {
        logger?.log(.safety(check: "barge_in", outcome: outcome))
    }

    /// Barge-in thresholds for a route: the configured values on risky routes; halfway towards
    /// the normal start threshold / minimum speech on low-risk (head-worn) routes.
    static func detectorConfig(_ base: EndpointingConfig, echoRisk: EchoRisk) -> EndpointingConfig {
        var config = base
        if echoRisk == .low {
            config.bargeInSpeechThreshold = (base.speechStartThreshold + base.bargeInSpeechThreshold) / 2
            config.bargeInMinSpeechMilliseconds = (base.minSpeechMilliseconds + base.bargeInMinSpeechMilliseconds) / 2
        }
        return config
    }
}
