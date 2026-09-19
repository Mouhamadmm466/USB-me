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
    /// Prompt-lookup speculative decoding: up to this many tokens copied from the request are
    /// verified in the same decode call as the current token (0 = off). Also the number of
    /// recurrent-state rollback snapshots llama.cpp keeps (`n_rs_seq`), which costs about
    /// 80 MB of memory per token for Nemotron-H.
    ///
    /// Off by default: on the A17 Pro, 2–8 token decode calls cost almost linearly more than one
    /// token and the snapshots add ~20% to every multi-token call, so with the short argument
    /// values of real commands speculation was slower (1.73 s vs 1.51 s P50, Docs/DEVICE_MATRIX.md).
    /// It halves decode calls on CPU hosts, where it can be enabled for evaluation runs.
    public var speculativeDraftTokens: Int = 0
    /// Drafts only fill a decode call up to this many tokens. On Metal, llama.cpp multiplies small
    /// batches (≤ 8 rows) with mat-vec kernels at close to single-token cost; larger batches
    /// switch to mat-mat kernels that cost about twice as much (measured on A17 Pro).
    public var speculativeMaxBatchTokens: Int = 8

    public init() {}
}

public struct TTSConfig: Codable, Sendable, Equatable {
    /// One fixed English voice for V1 (PRD §3.3).
    public var voice: String = "af_heart"
    public var speed: Float = 1.0
    /// The first chunk is kept short so audio starts quickly.
    public var firstChunkMaxWords: Int = 12
    /// The first chunk also ends at the first clause boundary (, ; :) after at least this many
    /// words ("Text Alex Kim:" | "“I'll be late.” Should I send it?"), 0 = off. The next chunk is
    /// synthesized while the first one plays.
    public var firstClauseMinWords: Int = 2
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
