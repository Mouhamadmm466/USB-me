import Core
import Foundation

/// An endpointed stretch of speech, ready for final ASR.
public struct Utterance: Sendable, Equatable {
    /// 16 kHz mono samples: pre-roll + speech + at most ~150 ms of trailing silence.
    public let samples: [Float]
    public let sampleRate: Double
    /// Capture timestamp of `samples[0]` (includes the pre-roll).
    public let startTime: TimeInterval
    /// Onset of the first speech frame.
    public let speechStartTime: TimeInterval
    /// End of the last speech frame.
    public let speechEndTime: TimeInterval
    /// The onset was detected with barge-in (strict) thresholds while the assistant was audible.
    public let startedDuringAssistantSpeech: Bool

    public init(
        samples: [Float],
        sampleRate: Double,
        startTime: TimeInterval,
        speechStartTime: TimeInterval,
        speechEndTime: TimeInterval,
        startedDuringAssistantSpeech: Bool
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
        self.speechStartTime = speechStartTime
        self.speechEndTime = speechEndTime
        self.startedDuringAssistantSpeech = startedDuringAssistantSpeech
    }

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var endTime: TimeInterval { startTime + duration }
    public var speechDuration: TimeInterval { speechEndTime - speechStartTime }
}

/// Emitted once when speech onset is confirmed (after the minimum speech duration).
public struct SpeechOnset: Sendable, Equatable {
    public let speechStartTime: TimeInterval
    /// Includes the pre-roll.
    public let utteranceStartTime: TimeInterval
    /// End of the frame that confirmed the onset (detection latency = this − speechStartTime).
    public let confirmedAt: TimeInterval
    public let duringAssistantSpeech: Bool
}

/// Emitted for every frame while an utterance is open.
public struct UtteranceProgress: Sendable, Equatable {
    /// Utterance audio so far (pre-roll included), for partial ASR. Copy-on-write: holding it
    /// costs one copy when the detector next appends, not one per frame.
    public let audio: [Float]
    public let startTime: TimeInterval
    public let speechStartTime: TimeInterval
    /// Current trailing silence (0 while the user is talking).
    public let trailingSilence: TimeInterval
    /// True every `partialIntervalMilliseconds` of utterance audio: run a partial ASR now.
    public let isPartialDue: Bool
    /// Number of partials due so far in this utterance (use as the partial's revision).
    public let partialRevision: Int

    public var duration: TimeInterval { Double(audio.count) / AudioFrame.sampleRate }
}

public enum EndpointEvent: Sendable, Equatable {
    case speechStarted(SpeechOnset)
    case speechContinuing(UtteranceProgress)
    case speechEnded(Utterance)
    /// No speech started within `noSpeechTimeoutMilliseconds` of listening (fires once).
    case noSpeechTimeout
    /// Speech lasted `maxUtteranceMilliseconds`; the utterance so far is returned untrimmed.
    case maxDurationReached(Utterance)
}

/// Endpointing state machine (PRD §6.5): fed one `(probability, frame)` pair per VAD frame.
///
/// - **Hysteresis**: onset needs `speechStartThreshold`; once started, frames count as speech
///   down to `speechContinueThreshold`.
/// - **Onset confirmation**: `minSpeechMilliseconds` of speech frames (short gaps of up to
///   `onsetGapToleranceMilliseconds` allowed) — clicks and pops never start an utterance.
/// - **Pre-roll**: the last `preRollMilliseconds` before onset are kept in a ring buffer and
///   prepended, so the first syllable reaches ASR intact.
/// - **End of utterance**: `endSilenceMilliseconds` of trailing silence, or
///   `stableEndSilenceMilliseconds` once the caller marked a partial transcript covering all the
///   speech so far as stable (`markTranscriptStable(_:coveringSampleCount:)`). Trailing silence is
///   trimmed to `trailingSilenceKeepMilliseconds` (~150 ms).
/// - **Limits**: `maxUtteranceMilliseconds` (measured from onset) and
///   `noSpeechTimeoutMilliseconds` (silence since listening started or the last utterance).
/// - **Barge-in mode**: onset needs `bargeInSpeechThreshold` for `bargeInMinSpeechMilliseconds`
///   (every onset frame must pass the strict threshold, gaps of one frame tolerated), and the
///   no-speech timeout is suspended. In `.automatic` mode (default) this applies exactly to the
///   frames flagged `assistantWasSpeaking` — playback-aware gating.
///
/// Pure value type: no clocks, no I/O; all times come from the frames.
public struct EndpointDetector: Sendable {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Normal thresholds for every frame.
        case normal
        /// Strict barge-in thresholds for every frame.
        case bargeIn
        /// Strict thresholds for frames with `assistantWasSpeaking`, normal otherwise.
        case automatic
    }

    private enum Phase: Equatable {
        case silence
        case onset
        case speech
    }

    public let config: EndpointingConfig
    public let sampleRate: Double
    public var mode: Mode
    /// Trailing silence kept after the last speech frame of a finished utterance.
    public var trailingSilenceKeepMilliseconds = 150
    /// Longest run of sub-threshold frames tolerated while a normal onset is confirmed.
    public var onsetGapToleranceMilliseconds = 64
    /// Same, for strict (barge-in) onsets.
    public var strictOnsetGapToleranceMilliseconds = 32

    private var phase: Phase = .silence
    private var preRoll: SampleRing
    private var utterance: [Float] = []
    private var utteranceStartTime: TimeInterval = 0
    private var speechStartTime: TimeInterval = 0
    private var speechStartOffset = 0
    private var lastSpeechEnd = 0
    private var onsetSpeechSamples = 0
    private var onsetGapSamples = 0
    private var trailingSilenceSamples = 0
    private var strictOnset = false
    private var samplesSincePartial = 0
    private var partialRevision = 0
    private var stableCoverage: Int?
    private var idleSamples = 0
    private var noSpeechReported = false
    private var expectedNextTimestamp: TimeInterval?

    public init(config: EndpointingConfig = .init(), mode: Mode = .automatic, sampleRate: Double = AudioFrame.sampleRate) {
        self.config = config
        self.mode = mode
        self.sampleRate = sampleRate
        preRoll = SampleRing(capacity: Self.samples(config.preRollMilliseconds, sampleRate))
    }

    // MARK: - Inspection

    /// Speech onset has been confirmed and the utterance is open.
    public var isInSpeech: Bool { phase == .speech }
    /// An onset is being confirmed (not yet reported).
    public var isConfirmingOnset: Bool { phase == .onset }
    /// Audio of the open (or tentative) utterance, pre-roll included; empty in silence.
    public var currentUtteranceAudio: [Float] { phase == .silence ? [] : utterance }
    public var currentUtteranceStartTime: TimeInterval? { phase == .silence ? nil : utteranceStartTime }
    public var currentSpeechStartTime: TimeInterval? { phase == .silence ? nil : speechStartTime }

    // MARK: - Feeding

    /// Processes one frame. Returns at most one event.
    public mutating func process(probability: Float, frame: AudioFrame) -> EndpointEvent? {
        let count = frame.samples.count
        guard count > 0 else { return nil }
        if let expected = expectedNextTimestamp, frame.timestamp - expected > 0.5 * Double(count) / sampleRate {
            // Capture gap: audio before it is not contiguous with this frame.
            preRoll.removeAll()
        }
        defer {
            expectedNextTimestamp = frame.timestamp + Double(count) / sampleRate
            preRoll.append(frame.samples)
        }
        let strict = isStrict(frame)

        switch phase {
        case .silence:
            let threshold = strict ? config.bargeInSpeechThreshold : config.speechStartThreshold
            if probability >= threshold {
                beginOnset(frame, strict: strict)
                return confirmOnsetIfReady(frame)
            }
            return tickIdle(count: count, strict: strict)

        case .onset:
            utterance.append(contentsOf: frame.samples)
            if !strict { idleSamples += count }
            let threshold = strictOnset ? config.bargeInSpeechThreshold : config.speechContinueThreshold
            if probability >= threshold {
                onsetSpeechSamples += count
                onsetGapSamples = 0
                lastSpeechEnd = utterance.count
                return confirmOnsetIfReady(frame)
            }
            onsetGapSamples += count
            let tolerance = strictOnset ? strictOnsetGapToleranceMilliseconds : onsetGapToleranceMilliseconds
            if onsetGapSamples > Self.samples(tolerance, sampleRate) {
                clearUtterance()
            }
            return nil

        case .speech:
            utterance.append(contentsOf: frame.samples)
            samplesSincePartial += count
            if probability >= config.speechContinueThreshold {
                lastSpeechEnd = utterance.count
                trailingSilenceSamples = 0
            } else {
                trailingSilenceSamples += count
            }
            if utterance.count - speechStartOffset >= Self.samples(config.maxUtteranceMilliseconds, sampleRate) {
                let result = makeUtterance(trimmed: false)
                finishUtterance()
                return .maxDurationReached(result)
            }
            if trailingSilenceSamples >= requiredEndSilenceSamples {
                let result = makeUtterance(trimmed: true)
                finishUtterance()
                return .speechEnded(result)
            }
            let due = samplesSincePartial >= Self.samples(config.partialIntervalMilliseconds, sampleRate)
            if due {
                samplesSincePartial = 0
                partialRevision += 1
            }
            return .speechContinuing(UtteranceProgress(
                audio: utterance,
                startTime: utteranceStartTime,
                speechStartTime: speechStartTime,
                trailingSilence: Double(trailingSilenceSamples) / sampleRate,
                isPartialDue: due,
                partialRevision: partialRevision
            ))
        }
    }

    // MARK: - Caller hints

    /// The latest partial transcript is stable (unchanged across consecutive partials), so a
    /// shorter trailing silence (`stableEndSilenceMilliseconds`) ends the utterance. Pass the
    /// sample count of the audio that partial was computed on (`UtteranceProgress.audio.count`):
    /// if speech continued after it, the shortcut does not apply. `false` clears the mark.
    public mutating func markTranscriptStable(_ stable: Bool, coveringSampleCount: Int? = nil) {
        guard phase == .speech else { return }
        stableCoverage = stable ? min(coveringSampleCount ?? utterance.count, utterance.count) : nil
    }

    /// Continues an utterance whose start was captured elsewhere (a confirmed barge-in hands
    /// over its candidate audio, so the user's first words are not lost).
    public mutating func adoptUtterance(
        samples: [Float],
        startTime: TimeInterval,
        speechStartTime: TimeInterval,
        startedDuringAssistantSpeech: Bool = true
    ) {
        phase = .speech
        utterance = samples
        utteranceStartTime = startTime
        self.speechStartTime = speechStartTime
        speechStartOffset = min(samples.count, max(0, Int(((speechStartTime - startTime) * sampleRate).rounded())))
        lastSpeechEnd = samples.count
        trailingSilenceSamples = 0
        strictOnset = startedDuringAssistantSpeech
        samplesSincePartial = 0
        partialRevision = 0
        stableCoverage = nil
        idleSamples = 0
        noSpeechReported = false
        expectedNextTimestamp = startTime + Double(samples.count) / sampleRate
    }

    /// Drops the open utterance without an event (e.g. a barge-in candidate rejected as echo).
    public mutating func cancelUtterance() {
        clearUtterance()
    }

    /// Full reset: new listening period (timeouts restart, pre-roll cleared).
    public mutating func reset() {
        clearUtterance()
        preRoll.removeAll()
        idleSamples = 0
        noSpeechReported = false
        expectedNextTimestamp = nil
    }

    // MARK: - Internals

    private func isStrict(_ frame: AudioFrame) -> Bool {
        switch mode {
        case .normal: false
        case .bargeIn: true
        case .automatic: frame.assistantWasSpeaking
        }
    }

    private var requiredEndSilenceSamples: Int {
        let normal = Self.samples(config.endSilenceMilliseconds, sampleRate)
        guard let coverage = stableCoverage, coverage >= lastSpeechEnd else { return normal }
        return min(normal, Self.samples(config.stableEndSilenceMilliseconds, sampleRate))
    }

    private mutating func beginOnset(_ frame: AudioFrame, strict: Bool) {
        phase = .onset
        strictOnset = strict
        utterance = preRoll.snapshot()
        utterance.reserveCapacity(Self.samples(config.maxUtteranceMilliseconds, sampleRate) / 4)
        speechStartOffset = utterance.count
        utteranceStartTime = frame.timestamp - Double(utterance.count) / sampleRate
        speechStartTime = frame.timestamp
        utterance.append(contentsOf: frame.samples)
        onsetSpeechSamples = frame.samples.count
        onsetGapSamples = 0
        lastSpeechEnd = utterance.count
        trailingSilenceSamples = 0
        stableCoverage = nil
        if !strict { idleSamples += frame.samples.count }
    }

    private mutating func confirmOnsetIfReady(_ frame: AudioFrame) -> EndpointEvent? {
        let needed = strictOnset ? config.bargeInMinSpeechMilliseconds : config.minSpeechMilliseconds
        guard onsetSpeechSamples >= Self.samples(needed, sampleRate) else { return nil }
        phase = .speech
        trailingSilenceSamples = 0
        samplesSincePartial = utterance.count - speechStartOffset
        partialRevision = 0
        idleSamples = 0
        noSpeechReported = false
        return .speechStarted(SpeechOnset(
            speechStartTime: speechStartTime,
            utteranceStartTime: utteranceStartTime,
            confirmedAt: frame.timestamp + Double(frame.samples.count) / sampleRate,
            duringAssistantSpeech: strictOnset
        ))
    }

    private mutating func tickIdle(count: Int, strict: Bool) -> EndpointEvent? {
        // The user is not expected to talk while the assistant does: no timeout then.
        guard !strict else {
            idleSamples = 0
            return nil
        }
        idleSamples += count
        guard config.noSpeechTimeoutMilliseconds > 0, !noSpeechReported,
              idleSamples >= Self.samples(config.noSpeechTimeoutMilliseconds, sampleRate)
        else { return nil }
        noSpeechReported = true
        return .noSpeechTimeout
    }

    private func makeUtterance(trimmed: Bool) -> Utterance {
        let keep = Self.samples(trailingSilenceKeepMilliseconds, sampleRate)
        let end = trimmed ? min(utterance.count, lastSpeechEnd + keep) : utterance.count
        return Utterance(
            samples: end == utterance.count ? utterance : Array(utterance[0 ..< end]),
            sampleRate: sampleRate,
            startTime: utteranceStartTime,
            speechStartTime: speechStartTime,
            speechEndTime: utteranceStartTime + Double(lastSpeechEnd) / sampleRate,
            startedDuringAssistantSpeech: strictOnset
        )
    }

    private mutating func finishUtterance() {
        clearUtterance()
        idleSamples = 0
        noSpeechReported = false
    }

    private mutating func clearUtterance() {
        phase = .silence
        utterance = []
        onsetSpeechSamples = 0
        onsetGapSamples = 0
        trailingSilenceSamples = 0
        lastSpeechEnd = 0
        speechStartOffset = 0
        samplesSincePartial = 0
        partialRevision = 0
        stableCoverage = nil
        strictOnset = false
    }

    static func samples(_ milliseconds: Int, _ sampleRate: Double) -> Int {
        max(0, Int((Double(milliseconds) * sampleRate / 1000).rounded(.up)))
    }
}

/// Fixed-capacity ring of the most recent samples (the pre-roll).
struct SampleRing: Sendable {
    let capacity: Int
    private var storage: [Float]
    private var start = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ samples: [Float]) {
        guard capacity > 0, !samples.isEmpty else { return }
        if samples.count >= capacity {
            storage.replaceSubrange(0 ..< capacity, with: samples[(samples.count - capacity)...])
            start = 0
            count = capacity
            return
        }
        for sample in samples {
            let write = (start + count) % capacity
            storage[write] = sample
            if count < capacity {
                count += 1
            } else {
                start = (start + 1) % capacity
            }
        }
    }

    /// Oldest to newest.
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        let first = min(count, capacity - start)
        var result = Array(storage[start ..< start + first])
        if first < count { result.append(contentsOf: storage[0 ..< count - first]) }
        return result
    }

    mutating func removeAll() {
        start = 0
        count = 0
    }
}
