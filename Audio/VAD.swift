import Core
import Foundation
import Synchronization

/// Tunables for `EnergyVAD`. Defaults were tuned on `Tests/Audio/Fixtures` (clean commands,
/// pink/brown noise mixes down to 5 dB SNR, digital silence, residual echo over room tone).
public struct EnergyVADConfiguration: Sendable, Equatable {
    public var frameSamples = 512
    public var sampleRate: Double = 16_000
    /// Band-limiting before the energy measurement. The high-pass removes DC offset, mains hum,
    /// handling/wind rumble and most of the energy of brown noise; the low-pass drops the top
    /// octave, where pink noise has as much energy as the whole low end of speech.
    public var highPassHz: Double = 150
    public var lowPassHz: Double? = 4_000
    /// SNR (dB above the noise floor) that maps to probability 0.5.
    public var snrMidpointDecibels: Float = 7
    /// Logistic scale in dB: +1 scale ≈ 0.73, +2 ≈ 0.88, +3 ≈ 0.95.
    public var snrScaleDecibels: Float = 1.5
    /// Soft absolute gate (dBFS, band-limited energy): quieter frames are not speech whatever
    /// their SNR, so a near-digital-silence floor cannot turn faint hiss into "speech".
    public var minimumSpeechDecibels: Float = -58
    public var minimumSpeechScaleDecibels: Float = 2
    /// Noise floor tracking in the dB domain with asymmetric time constants: it follows quieter
    /// frames quickly ("attack") and louder frames slowly ("release"), so speech barely moves it.
    public var noiseFloorFallSeconds: Double = 0.2
    public var noiseFloorRiseSeconds: Double = 4
    /// Cap on the slow rise, so a long utterance cannot drag the floor up to speech level.
    public var maxNoiseFloorRiseDecibelsPerSecond: Float = 3
    /// Stationarity: when the last `stationaryWindowFrames` energies deviate by less than
    /// `stationaryDeviationDecibels` (std-dev), the floor rises with `stationaryRiseSeconds`
    /// and without the cap — a fan, car or TV hum is noise; speech is never that steady.
    public var stationaryWindowFrames = 16
    public var stationaryDeviationDecibels: Float = 1.5
    public var stationaryRiseSeconds: Double = 0.4
    /// For the first frames the floor simply tracks the minimum energy seen.
    public var warmupFrames = 4
    public var noiseFloorLimitDecibels: Float = -100

    public init() {}
}

/// Deterministic energy VAD core (value type, no locking). `EnergyVAD` wraps it behind the
/// async `VoiceActivityDetecting` protocol; pipelines and tests can use it directly.
///
/// Per frame: band-limit (biquad high-pass + low-pass, started in steady state so a DC offset
/// produces no start-up transient) → mean power in dB → SNR against the adaptive noise floor
/// (measured *before* the floor sees this frame) → logistic → soft absolute gate.
public struct EnergyVADCore: Sendable {
    public let configuration: EnergyVADConfiguration
    public private(set) var noiseFloorDecibels: Float = 0
    public private(set) var lastEnergyDecibels: Float = -160
    public private(set) var lastSNRDecibels: Float = 0
    public private(set) var framesProcessed = 0

    private var highPass: Biquad
    private var lowPass: Biquad
    private var primed = false
    private var history: [Float]
    private var historyNext = 0
    private var historyCount = 0

    public init(configuration: EnergyVADConfiguration = .init()) {
        self.configuration = configuration
        highPass = .highPass(cutoff: configuration.highPassHz, sampleRate: configuration.sampleRate)
        lowPass = configuration.lowPassHz.map { .lowPass(cutoff: $0, sampleRate: configuration.sampleRate) } ?? .identity
        history = Array(repeating: 0, count: max(1, configuration.stationaryWindowFrames))
    }

    /// Speech probability 0…1 for one frame. Frames of any length are accepted; time
    /// constants use the actual frame duration.
    public mutating func process(_ frame: UnsafeBufferPointer<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        if !primed {
            let first = Double(frame[0].isFinite ? frame[0] : 0)
            highPass.prime(input: first)
            lowPass.prime(input: first * highPass.dcGain)
            primed = true
        }
        var energy = 0.0
        for sample in frame {
            let x = sample.isFinite ? Double(sample) : 0
            let y = lowPass.process(highPass.process(x))
            energy += y * y
        }
        let decibels = Float(10 * log10(energy / Double(frame.count) + 1e-12))
        let dt = Double(frame.count) / configuration.sampleRate
        lastEnergyDecibels = decibels
        pushHistory(decibels)

        let probability: Float
        if framesProcessed == 0 {
            noiseFloorDecibels = max(decibels, configuration.noiseFloorLimitDecibels)
            lastSNRDecibels = 0
            probability = 0
        } else {
            lastSNRDecibels = decibels - noiseFloorDecibels
            probability = Self.logistic((lastSNRDecibels - configuration.snrMidpointDecibels) / configuration.snrScaleDecibels)
                * Self.logistic((decibels - configuration.minimumSpeechDecibels) / configuration.minimumSpeechScaleDecibels)
            updateNoiseFloor(with: decibels, dt: dt)
        }
        framesProcessed += 1
        return probability
    }

    public mutating func process(_ frame: [Float]) -> Float {
        frame.withUnsafeBufferPointer { process($0) }
    }

    public mutating func reset() {
        self = EnergyVADCore(configuration: configuration)
    }

    private mutating func updateNoiseFloor(with decibels: Float, dt: Double) {
        let floor = noiseFloorDecibels
        if framesProcessed < configuration.warmupFrames {
            noiseFloorDecibels = min(floor, decibels)
        } else if decibels < floor {
            noiseFloorDecibels = floor + (decibels - floor) * Self.smoothing(dt: dt, tau: configuration.noiseFloorFallSeconds)
        } else {
            let stationary = isStationary
            let tau = stationary ? configuration.stationaryRiseSeconds : configuration.noiseFloorRiseSeconds
            var rise = (decibels - floor) * Self.smoothing(dt: dt, tau: tau)
            if !stationary {
                rise = min(rise, configuration.maxNoiseFloorRiseDecibelsPerSecond * Float(dt))
            }
            noiseFloorDecibels = floor + rise
        }
        noiseFloorDecibels = max(noiseFloorDecibels, configuration.noiseFloorLimitDecibels)
    }

    private var isStationary: Bool {
        guard historyCount == history.count, historyCount > 1 else { return false }
        var mean: Float = 0
        for value in history { mean += value }
        mean /= Float(historyCount)
        var variance: Float = 0
        for value in history { variance += (value - mean) * (value - mean) }
        variance /= Float(historyCount)
        return variance.squareRoot() < configuration.stationaryDeviationDecibels
    }

    private mutating func pushHistory(_ value: Float) {
        history[historyNext] = value
        historyNext = (historyNext + 1) % history.count
        historyCount = min(historyCount + 1, history.count)
    }

    static func logistic(_ x: Float) -> Float {
        1 / (1 + exp(-x))
    }

    /// Fraction of the distance to move this frame for a first-order smoother with time constant `tau`.
    static func smoothing(dt: Double, tau: Double) -> Float {
        tau > 0 ? Float(1 - exp(-dt / tau)) : 1
    }
}

/// Energy-based VAD conforming to `VoiceActivityDetecting` (512-sample frames at 16 kHz).
///
/// Adaptive noise floor with asymmetric attack/release plus a stationarity shortcut, SNR mapped
/// to a probability through a logistic curve, band-limited energy (robust to DC offset, hum and
/// rumble), fully deterministic. It is the cheap always-available detector; the Silero VAD in
/// the ASR module conforms to the same protocol and can replace it.
///
/// `Sendable` via a `Mutex`: calls are serialized, the state machine itself is a value type.
public final class EnergyVAD: VoiceActivityDetecting {
    public let frameSamples: Int
    private let core: Mutex<EnergyVADCore>

    public init(configuration: EnergyVADConfiguration = .init()) {
        frameSamples = configuration.frameSamples
        core = Mutex(EnergyVADCore(configuration: configuration))
    }

    public func speechProbability(_ frame: [Float]) async -> Float {
        probability(frame)
    }

    public func reset() async {
        core.withLock { $0.reset() }
    }

    /// Synchronous variant for real-time pipelines that already run on their own queue.
    public func probability(_ frame: [Float]) -> Float {
        core.withLock { $0.process(frame) }
    }

    /// Current noise floor estimate (dB, band-limited), for diagnostics.
    public var noiseFloorDecibels: Float {
        core.withLock { $0.noiseFloorDecibels }
    }
}

/// Second-order IIR section (RBJ cookbook), Direct Form I, double precision.
struct Biquad: Sendable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func highPass(cutoff: Double, sampleRate: Double, q: Double = 0.5.squareRoot()) -> Biquad {
        guard cutoff > 0, cutoff < sampleRate / 2 else { return .identity }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosw) / 2 / a0,
            b1: -(1 + cosw) / a0,
            b2: (1 + cosw) / 2 / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func lowPass(cutoff: Double, sampleRate: Double, q: Double = 0.5.squareRoot()) -> Biquad {
        guard cutoff > 0, cutoff < sampleRate / 2 else { return .identity }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cosw) / 2 / a0,
            b1: (1 - cosw) / a0,
            b2: (1 - cosw) / 2 / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// Gain at 0 Hz.
    var dcGain: Double {
        let denominator = 1 + a1 + a2
        return abs(denominator) > 1e-12 ? (b0 + b1 + b2) / denominator : 0
    }

    /// Sets the state as if `input` had been applied forever (no start-up transient).
    mutating func prime(input: Double) {
        x1 = input
        x2 = input
        y1 = input * dcGain
        y2 = y1
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
