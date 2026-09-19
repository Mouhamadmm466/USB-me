import Foundation

// MARK: - Clock

/// Injectable time source so tests and the evaluation harness are deterministic.
public struct AgentClock: Sendable {
    public let now: @Sendable () -> Date
    public let calendar: Calendar

    public init(now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent) {
        self.now = now
        self.calendar = calendar
    }

    public var timeZone: TimeZone { calendar.timeZone }

    public static func fixed(_ date: Date, timeZone: TimeZone) -> AgentClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return AgentClock(now: { date }, calendar: calendar)
    }
}

// MARK: - Language model

public struct LLMRequest: Sendable, Equatable {
    /// Static prefix (system prompt, tool schema, few-shot examples) in the model's chat format.
    /// Runtimes cache its evaluated state and reuse it while it is unchanged.
    public let cacheablePrefix: String
    /// Per-turn content: session state, recent turns, the user's utterance, generation prompt.
    public let suffix: String
    /// llama.cpp GBNF grammar that constrains the output.
    public let grammar: String?
    public let maxOutputTokens: Int
    /// Text the runtime may copy speculative draft tokens from (the utterance first, then the
    /// turn context). Empty = the suffix. Drafts are always verified against the model's own
    /// choices, so this can change speed but never output.
    public let draftSources: [String]

    public init(cacheablePrefix: String, suffix: String, grammar: String?, maxOutputTokens: Int, draftSources: [String] = []) {
        self.cacheablePrefix = cacheablePrefix
        self.suffix = suffix
        self.grammar = grammar
        self.maxOutputTokens = maxOutputTokens
        self.draftSources = draftSources
    }
}

public struct LLMGenerationStats: Sendable, Codable, Equatable {
    public var cachedPrefixTokens: Int = 0
    public var promptTokens: Int = 0
    /// Leading suffix tokens already evaluated by `prime` before the request arrived.
    public var primedTokens: Int = 0
    public var sampledTokens: Int = 0
    public var forcedTokens: Int = 0
    public var promptEvalMilliseconds: Double = 0
    public var timeToFirstTokenMilliseconds: Double = 0
    public var totalMilliseconds: Double = 0
    public var stoppedReason: String = "unknown"
    /// Time inside llama_decode + GPU synchronization (prompt suffix, sampled and forced tokens).
    public var decodeMilliseconds: Double = 0
    /// Time choosing tokens under the grammar.
    public var samplingMilliseconds: Double = 0
    public var decodeCalls: Int = 0
    /// Steps where no high-probability token satisfied the grammar and the whole vocabulary had
    /// to be constrained (slow path).
    public var grammarFallbacks: Int = 0
    /// Prompt-lookup draft tokens evaluated, and how many matched the model's own greedy choice.
    public var draftTokens: Int = 0
    public var acceptedDraftTokens: Int = 0
    /// Per decode call: tokens in the call and its duration (profiling batch-size costs).
    public var decodeCallTokens: [Int] = []
    public var decodeCallMilliseconds: [Double] = []

    public init() {}
}

public enum LLMStreamEvent: Sendable, Equatable {
    /// Decoded UTF-8 text delta.
    case text(String)
    case completed(LLMGenerationStats)
}

public protocol LanguageModel: Sendable {
    var modelIdentifier: String { get }
    /// Loads (if needed) and evaluates the cacheable prefix ahead of the first turn.
    func prepare(cacheablePrefix: String) async throws
    func generate(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// Evaluates the beginning of the next request's suffix (the turn context up to the
    /// utterance) while the user is still speaking. The next `generate` whose suffix starts with
    /// `suffixHead` only evaluates the rest; any other request ignores it. Optional optimization.
    func prime(cacheablePrefix: String, suffixHead: String) async
}

extension LanguageModel {
    public func prime(cacheablePrefix: String, suffixHead: String) async {}
}

// MARK: - Speech recognition

public struct ASRContext: Sendable, Equatable {
    /// Proper nouns (e.g. contact names) used to bias decoding. Never logged.
    public let biasPhrases: [String]

    public init(biasPhrases: [String] = []) {
        self.biasPhrases = biasPhrases
    }
}

public protocol SpeechRecognizer: Sendable {
    /// Fast, revisable hypothesis for UI feedback only.
    func partial(_ samples: [Float], revision: Int) async throws -> PartialTranscript
    /// Final transcription of an endpointed utterance.
    func final(_ samples: [Float], context: ASRContext) async throws -> FinalTranscript
}

// MARK: - Speech synthesis

public struct SynthesizedAudio: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

public protocol SpeechSynthesizer: Sendable {
    func synthesize(_ text: String) async throws -> SynthesizedAudio
}

// MARK: - Speech output

/// How the coordinator speaks. The voice layer implements it with Kokoro TTS + playback; text
/// mode, tests and the evaluation harness use `SilentSpeechOutput`.
public protocol SpeechOutput: Sendable {
    /// Speaks `text` and returns when playback finishes or is interrupted by barge-in.
    func speak(_ text: String) async -> SpeechOutputResult
    /// Stops any speech immediately.
    func stop() async
    /// Starts speaking the beginning of a reply whose later part is not known yet; a `speak`
    /// whose text starts with `lead` continues after it. Optional (default: nothing early).
    func speakLead(_ lead: String) async
}

extension SpeechOutput {
    public func speakLead(_ lead: String) async {}
}

public enum SpeechOutputResult: Sendable, Equatable {
    case finished
    /// The user started talking over the assistant (credible barge-in).
    case interrupted
}

public struct SilentSpeechOutput: SpeechOutput {
    public init() {}
    public func speak(_ text: String) async -> SpeechOutputResult { .finished }
    public func stop() async {}
}

// MARK: - Audio I/O

/// 16 kHz mono float32 frame from the capture pipeline.
public struct AudioFrame: Sendable, Equatable {
    public let samples: [Float]
    /// Seconds since capture started.
    public let timestamp: TimeInterval
    /// True when assistant speech was playing while this frame was captured.
    public let assistantWasSpeaking: Bool

    public init(samples: [Float], timestamp: TimeInterval, assistantWasSpeaking: Bool) {
        self.samples = samples
        self.timestamp = timestamp
        self.assistantWasSpeaking = assistantWasSpeaking
    }

    public static let sampleRate: Double = 16_000
}

public protocol AudioCapturing: AnyObject, Sendable {
    func startCapture() async throws -> AsyncStream<AudioFrame>
    func stopCapture() async
}

public protocol AudioPlaying: AnyObject, Sendable {
    /// Plays to completion; throws `CancellationError` if stopped.
    func play(_ audio: SynthesizedAudio) async throws
    func stopPlayback() async
    /// Temporarily lowers assistant volume while a possible barge-in is verified.
    func setDucked(_ ducked: Bool) async
}

// MARK: - Voice activity detection

/// Streaming VAD over 16 kHz mono frames. Implementations: energy VAD (Audio module) and
/// Silero VAD via whisper.cpp (ASR module).
public protocol VoiceActivityDetecting: AnyObject, Sendable {
    /// Samples per frame this detector expects (512 for Silero at 16 kHz).
    var frameSamples: Int { get }
    /// Speech probability 0...1 for one frame. Stateful across calls.
    func speechProbability(_ frame: [Float]) async -> Float
    func reset() async
}

// MARK: - Permissions

public protocol PermissionProviding: Sendable {
    func status(for kind: PermissionKind) async -> PermissionStatus
    /// Shows the system prompt only when status is `.notDetermined`; never loops.
    func request(_ kind: PermissionKind) async -> PermissionStatus
}
