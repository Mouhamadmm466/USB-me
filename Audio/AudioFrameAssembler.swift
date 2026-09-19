import Core
import Foundation

/// Re-blocks arbitrary-length 16 kHz mono chunks (whatever the input tap and the resampler
/// deliver: 320, 1600, 1601 … samples) into exact fixed-size `AudioFrame`s for the VAD.
///
/// **Timestamps** come from a sample clock: frame *k* starts `k × frameSamples / sampleRate`
/// seconds after capture started. They are exact, drift-free and strictly increasing. After a
/// capture gap (engine restart, interruption, route change) the engine calls
/// `resynchronize(toElapsed:)`, which moves the clock forward to wall-clock time and never
/// backwards, so timestamps stay monotonic and still mean "seconds since capture started".
///
/// **`assistantWasSpeaking`** is the OR over every chunk that contributed samples to the frame:
/// a frame captured even partly while assistant audio was audible is flagged (conservative).
///
/// Pure value type; no locking. The engine owns one instance and only touches it from the
/// input-tap callback.
public struct AudioFrameAssembler: Sendable {
    public let frameSamples: Int
    public let sampleRate: Double
    /// Index of the next frame to be emitted (frames emitted so far plus clock jumps).
    public private(set) var nextFrameIndex: Int = 0
    private var pending: [Float]
    private var pendingFlag = false

    public init(frameSamples: Int = 512, sampleRate: Double = AudioFrame.sampleRate) {
        precondition(frameSamples > 0, "frameSamples must be positive")
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.frameSamples = frameSamples
        self.sampleRate = sampleRate
        pending = []
        pending.reserveCapacity(frameSamples)
    }

    /// Samples waiting for the next frame to fill up (always `< frameSamples`).
    public var bufferedSampleCount: Int { pending.count }

    public var frameDuration: TimeInterval { Double(frameSamples) / sampleRate }

    /// Timestamp the next emitted frame will carry.
    public var nextFrameTimestamp: TimeInterval { timestamp(ofFrame: nextFrameIndex) }

    /// Appends samples and calls `emit` once for every completed frame, in order.
    public mutating func append(
        _ samples: UnsafeBufferPointer<Float>,
        assistantWasSpeaking: Bool,
        emit: (AudioFrame) -> Void
    ) {
        guard !samples.isEmpty else { return }
        var index = 0
        while index < samples.count {
            let remaining = samples.count - index
            if pending.isEmpty, remaining >= frameSamples {
                // Fast path: a whole frame straight from the input, one copy.
                let frame = Array(samples[index ..< index + frameSamples])
                emitFrame(frame, flag: assistantWasSpeaking, emit: emit)
                index += frameSamples
                continue
            }
            let take = min(frameSamples - pending.count, remaining)
            pending.append(contentsOf: samples[index ..< index + take])
            pendingFlag = pendingFlag || assistantWasSpeaking
            index += take
            if pending.count == frameSamples {
                let frame = pending
                let flag = pendingFlag
                pending = []
                pending.reserveCapacity(frameSamples)
                pendingFlag = false
                emitFrame(frame, flag: flag, emit: emit)
            }
        }
    }

    /// Convenience for tests and offline processing.
    public mutating func append(_ samples: [Float], assistantWasSpeaking: Bool = false) -> [AudioFrame] {
        var frames: [AudioFrame] = []
        samples.withUnsafeBufferPointer { buffer in
            append(buffer, assistantWasSpeaking: assistantWasSpeaking) { frames.append($0) }
        }
        return frames
    }

    /// Moves the frame clock forward after a capture gap so the next frame's timestamp is close
    /// to `elapsed` (seconds since capture started). Samples of an incomplete frame are dropped
    /// because they belong to audio before the gap. Never moves the clock backwards.
    /// - Returns: `true` if the clock jumped.
    @discardableResult
    public mutating func resynchronize(toElapsed elapsed: TimeInterval) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        let target = Int((elapsed * sampleRate / Double(frameSamples)).rounded(.down))
        guard target > nextFrameIndex else { return false }
        nextFrameIndex = target
        pending.removeAll(keepingCapacity: true)
        pendingFlag = false
        return true
    }

    /// Drops buffered samples and restarts the clock at zero (new capture session).
    public mutating func reset() {
        nextFrameIndex = 0
        pending.removeAll(keepingCapacity: true)
        pendingFlag = false
    }

    private func timestamp(ofFrame index: Int) -> TimeInterval {
        // Integer sample index first: exact for any realistic session length.
        Double(index * frameSamples) / sampleRate
    }

    private mutating func emitFrame(_ samples: [Float], flag: Bool, emit: (AudioFrame) -> Void) {
        let frame = AudioFrame(samples: samples, timestamp: timestamp(ofFrame: nextFrameIndex), assistantWasSpeaking: flag)
        nextFrameIndex += 1
        emit(frame)
    }
}
