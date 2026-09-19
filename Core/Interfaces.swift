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

    public init(cacheablePrefix: String, suffix: String, grammar: String?, maxOutputTokens: Int) {
        self.cacheablePrefix = cacheablePrefix
        self.suffix = suffix
        self.grammar = grammar
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct LLMGenerationStats: Sendable, Codable, Equatable {
    public var cachedPrefixTokens: Int = 0
    public var promptTokens: Int = 0
    public var sampledTokens: Int = 0
    public var forcedTokens: Int = 0
    public var promptEvalMilliseconds: Double = 0
    public var timeToFirstTokenMilliseconds: Double = 0
    public var totalMilliseconds: Double = 0
    public var stoppedReason: String = "unknown"

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
