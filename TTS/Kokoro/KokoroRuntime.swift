import Core
import Foundation
import KokoroSwift
import MLX
import Telemetry

/// Kokoro 82M (v1.0 weights, `mlx-community/Kokoro-82M-bf16`) through KokoroSwift on MLX, with one
/// fixed English voice (`af_heart`) for V1 (PRD §3.3). Device-only: MLX needs Apple-silicon Metal.
///
/// Runs on its own serial executor; synthesis of one chunk blocks that queue only.
public actor KokoroRuntime: SpeechSynthesizer {
    private let modelURL: URL
    private let voiceURL: URL
    private let config: TTSConfig
    private let logger: PrivacySafeLogger
    private let queue = DispatchSerialQueue(label: "voiceagent.tts.inference", qos: .userInitiated)
    private var engine: KokoroEngineBox?
    public private(set) var loadMilliseconds: Double = 0

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    public init(modelURL: URL, voiceURL: URL, config: TTSConfig = TTSConfig(), logger: PrivacySafeLogger = .shared) {
        self.modelURL = modelURL
        self.voiceURL = voiceURL
        self.config = config
        self.logger = logger
    }

    public var isLoaded: Bool { engine != nil }

    public func load() throws {
        guard engine == nil else { return }
        let watch = Stopwatch()
        // Keep MLX's buffer cache small: the LLM shares the GPU and unified memory.
        Memory.cacheLimit = 64 * 1024 * 1024
        let arrays = try MLX.loadArrays(url: voiceURL)
        guard let voice = arrays["voice"] else {
            logger.log(.error(domain: "tts", code: "voice_missing"))
            throw TTSError.voiceMissing
        }
        let tts = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        engine = KokoroEngineBox(tts: tts, voice: voice)
        loadMilliseconds = watch.elapsedMilliseconds
        logger.log(.modelLifecycle(model: "kokoro", phase: "loaded", milliseconds: Int(loadMilliseconds)))
    }

    /// Runs one short synthesis so shaders are compiled before the first real reply.
    public func warmUp() throws {
        try load()
        _ = try synthesizeNow("Ready.")
    }

    public func unload() {
        engine = nil
        Memory.clearCache()
        logger.log(.modelLifecycle(model: "kokoro", phase: "unloaded", milliseconds: nil))
    }

    public func synthesize(_ text: String) async throws -> SynthesizedAudio {
        try Task.checkCancellation()
        try load()
        return try synthesizeNow(text)
    }

    private func synthesizeNow(_ text: String) throws -> SynthesizedAudio {
        guard let engine else { throw TTSError.notLoaded }
        let watch = Stopwatch()
        let (samples, _) = try engine.tts.generateAudio(voice: engine.voice, language: .enUS, text: text, speed: config.speed)
        let audio = SynthesizedAudio(samples: samples, sampleRate: Self.sampleRate)
        logger.log(.stageLatency(stage: .ttsSynthesis, milliseconds: Int(watch.elapsedMilliseconds)))
        return audio
    }
}

public enum TTSError: Error, Equatable, Sendable {
    case notLoaded
    case voiceMissing
}

/// KokoroTTS and MLXArray are not Sendable; they are only touched on KokoroRuntime's executor.
final class KokoroEngineBox: @unchecked Sendable {
    let tts: KokoroTTS
    let voice: MLXArray

    init(tts: KokoroTTS, voice: MLXArray) {
        self.tts = tts
        self.voice = voice
    }
}
