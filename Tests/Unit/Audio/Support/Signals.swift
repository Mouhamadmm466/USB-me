@testable import Audio
import Core
import Foundation

/// Deterministic PRNG (SplitMix64): synthetic signals are identical on every run and machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Float {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
}

/// Synthetic 16 kHz test signals.
enum Signals {
    static let rate: Double = 16_000

    static func count(_ seconds: Double, rate: Double = rate) -> Int {
        Int((seconds * rate).rounded())
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: count(seconds))
    }

    static func sine(frequency: Double, amplitude: Float, seconds: Double, rate: Double = rate) -> [Float] {
        (0 ..< count(seconds, rate: rate)).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
        }
    }

    static func whiteNoise(rmsDecibels: Float, seconds: Double, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        let raw = (0 ..< count(seconds)).map { _ in generator.gaussian() }
        return scaled(raw, toRMSDecibels: rmsDecibels)
    }

    /// Pink (1/f) noise, Paul Kellet's filter bank over white noise.
    static func pinkNoise(rmsDecibels: Float, seconds: Double, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        var b = [Float](repeating: 0, count: 7)
        let raw = (0 ..< count(seconds)).map { _ -> Float in
            let white = generator.gaussian()
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            let pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
            return pink
        }
        return scaled(raw, toRMSDecibels: rmsDecibels)
    }

    /// Speech-like signal: a harmonic complex (F0 with slight vibrato, harmonics up to 3.4 kHz
    /// with a 1/n tilt) under a syllabic envelope (200 ms raised-cosine syllables every 250 ms).
    static func speechLike(seconds: Double, rmsDecibels: Float, fundamental: Double = 140) -> [Float] {
        let n = count(seconds)
        var phase = 0.0
        let harmonics = Int(3_400 / fundamental)
        var output = [Float](repeating: 0, count: n)
        for index in 0 ..< n {
            let t = Double(index) / rate
            let f0 = fundamental * (1 + 0.03 * sin(2 * .pi * 3 * t))
            phase += 2 * .pi * f0 / rate
            var value = 0.0
            for harmonic in 1 ... harmonics {
                value += sin(Double(harmonic) * phase + Double(harmonic) * 0.7) / Double(harmonic)
            }
            let position = t.truncatingRemainder(dividingBy: 0.25)
            let envelope = position < 0.2 ? pow(sin(.pi * position / 0.2), 2) : 0
            output[index] = Float(value * envelope)
        }
        return scaled(output, toRMSDecibels: rmsDecibels)
    }

    static func concat(_ parts: [Float]...) -> [Float] {
        parts.flatMap { $0 }
    }

    /// Sample-wise sum; the result is as long as the longer input.
    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0 ..< max(a.count, b.count)).map { index in
            (index < a.count ? a[index] : 0) + (index < b.count ? b[index] : 0)
        }
    }

    static func rmsDecibels(_ samples: [Float]) -> Float {
        LevelMeter.decibels(rms: LevelMeter.rms(samples))
    }

    static func scaled(_ samples: [Float], toRMSDecibels decibels: Float) -> [Float] {
        let rms = LevelMeter.rms(samples)
        guard rms > 0 else { return samples }
        let gain = pow(10, decibels / 20) / rms
        return samples.map { $0 * gain }
    }

    /// Estimates the dominant frequency from positive-going zero crossings (linear interpolation).
    static func zeroCrossingFrequency(_ samples: [Float], rate: Double) -> Double {
        var crossings: [Double] = []
        for index in 1 ..< samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
            let fraction = Double(-samples[index - 1] / (samples[index] - samples[index - 1]))
            crossings.append(Double(index - 1) + fraction)
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) * rate / (last - first)
    }
}

/// Framing → VAD → endpoint detector, as the voice session wires them.
struct PipelineResult {
    var probabilities: [Float] = []
    var events: [(frame: Int, event: EndpointEvent)] = []

    var onsets: [(frame: Int, onset: SpeechOnset)] {
        events.compactMap { if case let .speechStarted(onset) = $0.event { ($0.frame, onset) } else { nil } }
    }

    var utterances: [(frame: Int, utterance: Utterance)] {
        events.compactMap { if case let .speechEnded(utterance) = $0.event { ($0.frame, utterance) } else { nil } }
    }

    var timeouts: [Int] {
        events.compactMap { if case .noSpeechTimeout = $0.event { $0.frame } else { nil } }
    }

    var maxDurations: [(frame: Int, utterance: Utterance)] {
        events.compactMap { if case let .maxDurationReached(utterance) = $0.event { ($0.frame, utterance) } else { nil } }
    }
}

enum Pipeline {
    static let frameSamples = 512
    static var frameDuration: TimeInterval { Double(frameSamples) / AudioFrame.sampleRate }

    /// Whole 512-sample frames (the trailing partial frame is dropped), timestamped from 0.
    static func frames(
        _ samples: [Float],
        assistantSpeaking: (TimeInterval) -> Bool = { _ in false }
    ) -> [AudioFrame] {
        stride(from: 0, to: samples.count - frameSamples + 1, by: frameSamples).map { start in
            let timestamp = Double(start) / AudioFrame.sampleRate
            return AudioFrame(
                samples: Array(samples[start ..< start + frameSamples]),
                timestamp: timestamp,
                assistantWasSpeaking: assistantSpeaking(timestamp)
            )
        }
    }

    static func probabilities(_ samples: [Float], configuration: EnergyVADConfiguration = .init()) -> [Float] {
        var vad = EnergyVADCore(configuration: configuration)
        return frames(samples).map { vad.process($0.samples) }
    }

    static func run(
        _ samples: [Float],
        vad configuration: EnergyVADConfiguration = .init(),
        endpointing: EndpointingConfig = .init(),
        mode: EndpointDetector.Mode = .automatic,
        assistantSpeaking: (TimeInterval) -> Bool = { _ in false }
    ) -> PipelineResult {
        var vad = EnergyVADCore(configuration: configuration)
        var detector = EndpointDetector(config: endpointing, mode: mode)
        var result = PipelineResult()
        for (index, frame) in frames(samples, assistantSpeaking: assistantSpeaking).enumerated() {
            let probability = vad.process(frame.samples)
            result.probabilities.append(probability)
            if let event = detector.process(probability: probability, frame: frame) {
                if case .speechContinuing = event { continue }
                result.events.append((index, event))
            }
        }
        return result
    }
}
