import Core
import Foundation
import Telemetry
@preconcurrency import whisper

/// whisper.cpp with the English-only Whisper base.en model (PRD §3.1).
///
/// - `partial` produces fast, revisable hypotheses for the UI only (reduced audio context, short
///   token budget, single segment). The type it returns (`PartialTranscript`) cannot enter the
///   agent.
/// - `final` transcribes an endpointed utterance with full context and temperature fallback and
///   returns the only type the agent accepts (`FinalTranscript`).
/// Runs on its own serial executor so blocking inference never stalls Swift's cooperative pool.
public actor WhisperRuntime: SpeechRecognizer {
    private let modelURL: URL
    private let config: ASRConfig
    private let logger: PrivacySafeLogger
    private let queue = DispatchSerialQueue(label: "voiceagent.asr.inference", qos: .userInitiated)
    private var handle: WhisperHandle?
    public private(set) var loadMilliseconds: Double = 0
    /// Confirms that a transcript made only of a known silence hallucination ("you", "Okay.")
    /// came from real speech. Its own instance: it is reset for every clip it checks.
    private let speechGate: SileroVAD?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - Parameter speechGateModelURL: Silero VAD model used to verify hallucination-prone
    ///   transcripts (nil disables the check; the length-based guard still applies).
    public init(modelURL: URL, config: ASRConfig = ASRConfig(), speechGateModelURL: URL? = nil, logger: PrivacySafeLogger = .shared) {
        self.modelURL = modelURL
        self.config = config
        self.logger = logger
        speechGate = speechGateModelURL.flatMap { try? SileroVAD(modelURL: $0) }
    }

    public var isLoaded: Bool { handle != nil }

    public func load() throws {
        guard handle == nil else { return }
        WhisperBackend.initialize()
        let watch = Stopwatch()
        var params = whisper_context_default_params()
        params.use_gpu = Self.gpuAvailable && config.useGPU
        params.flash_attn = params.use_gpu
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            logger.log(.error(domain: "asr", code: "model_load_failed"))
            throw ASRError.modelLoadFailed
        }
        handle = WhisperHandle(context: context)
        loadMilliseconds = watch.elapsedMilliseconds
        logger.log(.modelLifecycle(model: "whisper", phase: "loaded", milliseconds: Int(loadMilliseconds)))
    }

    public func unload() {
        handle = nil
        logger.log(.modelLifecycle(model: "whisper", phase: "unloaded", milliseconds: nil))
    }

    // MARK: - SpeechRecognizer

    public func partial(_ samples: [Float], revision: Int) async throws -> PartialTranscript {
        let seconds = Double(samples.count) / AudioFrame.sampleRate
        let text = try transcribe(samples, final: false, prompt: nil)
        return PartialTranscript(
            text: TranscriptCleaner.clean(text, audioSeconds: seconds, guardSeconds: config.hallucinationGuardSeconds),
            revision: revision,
            audioDurationSeconds: seconds
        )
    }

    public func final(_ samples: [Float], context: ASRContext) async throws -> FinalTranscript {
        let seconds = Double(samples.count) / AudioFrame.sampleRate
        let prompt = TranscriptCleaner.biasPrompt(context.biasPhrases, limit: config.maxBiasNames, domain: config.domainPrompt)
        let raw = try transcribe(samples, final: true, prompt: prompt)
        var text = TranscriptCleaner.clean(raw, audioSeconds: seconds, guardSeconds: config.hallucinationGuardSeconds)
        // "you" / "Okay." on noise longer than the guard: keep it only if the VAD heard speech
        // ("okay" would otherwise count as a yes to a pending action).
        if TranscriptCleaner.isKnownHallucination(text), let speechGate,
           speechGate.speechMilliseconds(in: samples) < config.minimumSpeechMillisecondsForHallucinationPhrase {
            text = ""
        }
        return FinalTranscript(
            text: text,
            audioDurationSeconds: seconds
        )
    }

    // MARK: - Inference

    private func transcribe(_ samples: [Float], final: Bool, prompt: String?) throws -> String {
        try load()
        guard let context = handle?.context else { throw ASRError.modelLoadFailed }
        guard !samples.isEmpty else { return "" }
        // Whisper needs at least ~1 s of audio; pad short utterances with silence.
        var audio = samples
        let minimum = Int(AudioFrame.sampleRate * 1.05)
        if audio.count < minimum { audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.threadCount(config.threads))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = !final
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = final ? config.finalTemperatureIncrement : 0
        params.max_tokens = final ? 0 : Int32(config.partialMaxTokens)
        params.audio_ctx = final ? 0 : Int32(Self.partialAudioContext(samples: audio.count, cap: config.partialAudioContext))
        params.detect_language = false

        let watch = Stopwatch()
        let status: Int32 = "en".withCString { language in
            params.language = language
            if let prompt {
                return prompt.withCString { promptPointer in
                    params.initial_prompt = promptPointer
                    return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
                }
            }
            return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else {
            logger.log(.error(domain: "asr", code: "whisper_full_failed"))
            throw ASRError.inferenceFailed(Int(status))
        }
        var text = ""
        for segment in 0..<whisper_full_n_segments(context) {
            if let piece = whisper_full_get_segment_text(context, segment) {
                text += String(cString: piece)
            }
        }
        logger.log(.stageLatency(stage: final ? .endpointToFinalTranscript : .partialTranscript, milliseconds: Int(watch.elapsedMilliseconds)))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Encoder frames needed for the audio (50 per second) plus headroom, capped. Smaller context
    /// makes partial passes several times faster than the fixed 30-second window.
    static func partialAudioContext(samples: Int, cap: Int) -> Int {
        guard cap > 0 else { return 0 }
        let seconds = Double(samples) / AudioFrame.sampleRate
        let frames = Int((seconds * 50).rounded(.up)) + 64
        return min(1500, max(256, min(cap, frames)))
    }

    static var gpuAvailable: Bool {
        #if targetEnvironment(simulator) || arch(x86_64)
        return false
        #else
        return true
        #endif
    }

    static func threadCount(_ requested: Int?) -> Int {
        if let requested { return requested }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #if os(iOS)
        return max(2, min(4, cores - 2))
        #else
        return max(2, min(8, cores))
        #endif
    }
}

public enum ASRError: Error, Equatable, Sendable {
    case modelLoadFailed
    case vadLoadFailed
    case inferenceFailed(Int)
}

/// Owns the whisper context; touched only on WhisperRuntime's serial executor.
final class WhisperHandle: @unchecked Sendable {
    let context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }
}

/// Silences whisper.cpp logging (it can echo transcripts) and initializes once.
enum WhisperBackend {
    private static let initialized: Bool = {
        whisper_log_set({ _, _, _ in }, nil)
        return true
    }()

    static func initialize() {
        _ = initialized
    }
}
