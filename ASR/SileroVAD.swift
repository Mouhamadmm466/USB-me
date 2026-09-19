import Core
import Foundation
import Telemetry
@preconcurrency import whisper

/// Streaming Silero VAD (v6.2.0, ggml) through whisper.cpp's VAD API.
///
/// Fed one 512-sample (32 ms) frame at a time; the LSTM state carries across calls
/// (`whisper_vad_detect_speech_no_reset`) and is reset between utterances. Far more robust to
/// cafe/street/TV noise than an energy detector, at ~0.1 ms per frame.
public final class SileroVAD: VoiceActivityDetecting, @unchecked Sendable {
    // All access to `context` is serialized through `lock`.
    private let lock = NSLock()
    private let context: OpaquePointer
    public let frameSamples = 512

    public init(modelURL: URL, threads: Int = 1) throws {
        WhisperBackend.initialize()
        var params = whisper_vad_default_context_params()
        params.n_threads = Int32(threads)
        params.use_gpu = false
        guard let context = whisper_vad_init_from_file_with_params(modelURL.path, params) else {
            PrivacySafeLogger.shared.log(.error(domain: "vad", code: "model_load_failed"))
            throw ASRError.vadLoadFailed
        }
        self.context = context
    }

    deinit {
        whisper_vad_free(context)
    }

    public func speechProbability(_ frame: [Float]) async -> Float {
        probability(frame)
    }

    /// Synchronous variant for callers already on an audio-processing queue.
    public func probability(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        return lock.withLock {
            var samples = frame
            if samples.count < frameSamples { samples.append(contentsOf: [Float](repeating: 0, count: frameSamples - samples.count)) }
            let ok = samples.withUnsafeBufferPointer {
                whisper_vad_detect_speech_no_reset(context, $0.baseAddress, Int32($0.count))
            }
            guard ok, whisper_vad_n_probs(context) > 0, let probabilities = whisper_vad_probs(context) else { return 0 }
            let count = Int(whisper_vad_n_probs(context))
            var maximum: Float = 0
            for index in 0..<count { maximum = max(maximum, probabilities[index]) }
            return maximum
        }
    }

    public func reset() async {
        lock.withLock { whisper_vad_reset_state(context) }
    }
}
