import Foundation

/// Input and output levels for the UI orb, both 0…1 (0 = at/below the floor, 1 = loud speech).
public struct AudioLevels: Sendable, Equatable {
    public var input: Float
    public var output: Float

    public init(input: Float = 0, output: Float = 0) {
        self.input = input
        self.output = output
    }

    public static let silent = AudioLevels()
}

/// RMS level meter with a perceptual (dB) mapping and asymmetric attack/release smoothing,
/// suitable for driving UI animation. Smoothing is time-based (`exp(-dt/τ)` per update), so the
/// result does not depend on how the audio is chunked.
public struct LevelMeter: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// RMS level (dBFS) that maps to 0.
        public var floorDecibels: Float = -60
        /// RMS level (dBFS) that maps to 1. Close-talk speech peaks around -20…-10 dBFS.
        public var ceilingDecibels: Float = -12
        /// Time constant when the level rises.
        public var attackSeconds: Double = 0.03
        /// Time constant when the level falls (slower, so the orb does not flicker).
        public var releaseSeconds: Double = 0.25
        public var sampleRate: Double = 16_000

        public init() {}
    }

    public let configuration: Configuration
    /// Smoothed level 0…1.
    public private(set) var level: Float = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Feeds a block of samples and returns the smoothed level.
    @discardableResult
    public mutating func process(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return level }
        let target = Self.normalizedLevel(
            rms: Self.rms(samples),
            floorDecibels: configuration.floorDecibels,
            ceilingDecibels: configuration.ceilingDecibels
        )
        let dt = Double(samples.count) / configuration.sampleRate
        let tau = target > level ? configuration.attackSeconds : configuration.releaseSeconds
        let keep = Float(tau > 0 ? exp(-dt / tau) : 0)
        level = target + (level - target) * keep
        return level
    }

    @discardableResult
    public mutating func process(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public mutating func reset() {
        level = 0
    }

    // MARK: - Pure helpers

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// 20·log10(rms), floored at -160 dBFS for silence.
    public static func decibels(rms: Float) -> Float {
        rms > 1e-8 ? 20 * log10(rms) : -160
    }

    /// Maps an RMS value linearly in dB between the floor (0) and the ceiling (1), clamped.
    public static func normalizedLevel(rms: Float, floorDecibels: Float, ceilingDecibels: Float) -> Float {
        guard ceilingDecibels > floorDecibels else { return rms > 0 ? 1 : 0 }
        let db = decibels(rms: rms)
        return min(1, max(0, (db - floorDecibels) / (ceilingDecibels - floorDecibels)))
    }
}

/// Precomputed loudness envelope of a buffer the assistant is about to play, so the output
/// level for the UI can be read by playback position without tapping the output graph.
public struct PlaybackEnvelope: Sendable, Equatable {
    public let sampleRate: Double
    public let hopSamples: Int
    public let sampleCount: Int
    /// Normalised level (0…1) per hop.
    public let levels: [Float]

    public init(
        samples: [Float],
        sampleRate: Double,
        hopDuration: TimeInterval = 0.02,
        floorDecibels: Float = -60,
        ceilingDecibels: Float = -12
    ) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        let hop = max(1, Int((hopDuration * sampleRate).rounded()))
        self.sampleRate = sampleRate
        hopSamples = hop
        sampleCount = samples.count
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / hop + 1)
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let end = min(buffer.count, start + hop)
                let slice = UnsafeBufferPointer(rebasing: buffer[start ..< end])
                levels.append(LevelMeter.normalizedLevel(
                    rms: LevelMeter.rms(slice),
                    floorDecibels: floorDecibels,
                    ceilingDecibels: ceilingDecibels
                ))
                start = end
            }
        }
        self.levels = levels
    }

    public var duration: TimeInterval { Double(sampleCount) / sampleRate }

    /// Level at a sample position; 0 before the start and after the end.
    public func level(atSample position: Int) -> Float {
        guard position >= 0, position < sampleCount, !levels.isEmpty else { return 0 }
        return levels[min(levels.count - 1, position / hopSamples)]
    }

    /// Level at a time offset (seconds) from the start of the buffer.
    public func level(at offset: TimeInterval) -> Float {
        guard offset.isFinite, offset >= 0 else { return 0 }
        return level(atSample: Int(offset * sampleRate))
    }
}
