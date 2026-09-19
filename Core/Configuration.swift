import Foundation

/// Endpointing / VAD thresholds (PRD §6.5). Stored in configuration so they can be benchmarked.
public struct EndpointingConfig: Codable, Sendable, Equatable {
    /// Frame size fed to the VAD (512 samples at 16 kHz = 32 ms, the Silero window).
    public var frameSamples: Int = 512
    /// VAD probability that starts speech.
    public var speechStartThreshold: Float = 0.5
    /// Hysteresis: probability that keeps an utterance alive once started.
    public var speechContinueThreshold: Float = 0.35
    public var minSpeechMilliseconds: Int = 180
    /// Trailing silence that ends an utterance.
    public var endSilenceMilliseconds: Int = 700
    /// Shorter trailing silence accepted when the latest partial transcript was stable.
    public var stableEndSilenceMilliseconds: Int = 500
    public var maxUtteranceMilliseconds: Int = 15_000
    public var noSpeechTimeoutMilliseconds: Int = 8_000
    public var partialIntervalMilliseconds: Int = 700
    /// Audio kept from before speech onset so the first syllable is not clipped.
    public var preRollMilliseconds: Int = 320

    // Barge-in (PRD §6.3/6.4) — stricter while the assistant is speaking.
    public var bargeInSpeechThreshold: Float = 0.75
    public var bargeInMinSpeechMilliseconds: Int = 320
    /// Word-overlap ratio above which a barge-in transcript is treated as the assistant's own echo.
    public var echoSimilarityThreshold: Double = 0.55

    public init() {}
}

public struct LLMConfig: Codable, Sendable, Equatable {
    public var contextLength: Int = 4096
    public var batchSize: Int = 512
    public var maxOutputTokens: Int = 160
    /// nil = runtime default for the platform.
    public var threads: Int?
    /// Layers offloaded to Metal. 0 forces CPU (simulator / Intel Macs).
    public var gpuLayers: Int = 999
    public var useMemoryMap: Bool = true
    /// Emits grammar-forced text in batches instead of sampling it token by token.
    public var jumpForwardDecoding: Bool = true

    public init() {}
}

public struct TTSConfig: Codable, Sendable, Equatable {
    /// One fixed English voice for V1 (PRD §3.3).
    public var voice: String = "af_heart"
    public var speed: Float = 1.0
    /// The first chunk is kept short so audio starts quickly.
    public var firstChunkMaxWords: Int = 12
    public var maxChunkWords: Int = 30

    public init() {}
}

public struct ConfirmationConfig: Codable, Sendable, Equatable {
    public var pendingActionLifetimeSeconds: Double = 120
    public var maxUnclearReprompts: Int = 2

    public init() {}
}

public struct AgentConfiguration: Codable, Sendable, Equatable {
    public var endpointing = EndpointingConfig()
    public var llm = LLMConfig()
    public var tts = TTSConfig()
    public var confirmation = ConfirmationConfig()
    /// Re-open the microphone after the assistant finishes speaking an answer.
    public var continueListeningAfterResponse: Bool = true

    public init() {}

    public static let `default` = AgentConfiguration()
}
