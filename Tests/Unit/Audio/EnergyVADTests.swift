@testable import Audio
import Core
import Foundation
import Testing

@Suite struct EnergyVADTests {
    private func frameTime(_ index: Int) -> Double { Double(index) * Pipeline.frameDuration }

    /// Probabilities of frames whose start time lies in `range`.
    private func slice(_ probabilities: [Float], _ range: ClosedRange<Double>) -> [Float] {
        probabilities.enumerated().filter { range.contains(frameTime($0.offset)) }.map(\.element)
    }

    @Test func digitalSilenceIsNeverSpeech() {
        let probabilities = Pipeline.probabilities(Signals.silence(3))
        #expect(probabilities.allSatisfy { $0 < 0.01 })
    }

    @Test(arguments: [-55, -40, -25] as [Float])
    func steadyWhiteNoiseIsNotSpeech(level: Float) {
        let probabilities = Pipeline.probabilities(Signals.whiteNoise(rmsDecibels: level, seconds: 4, seed: 7))
        let settled = Array(probabilities.dropFirst(16))
        #expect(settled.allSatisfy { $0 < 0.35 })
        #expect(settled.reduce(0, +) / Float(settled.count) < 0.1)
    }

    @Test func steadyPinkNoiseIsNotSpeech() {
        let probabilities = Pipeline.probabilities(Signals.pinkNoise(rmsDecibels: -30, seconds: 4, seed: 11))
        #expect(probabilities.dropFirst(16).allSatisfy { $0 < 0.35 })
    }

    @Test func speechLikeBurstsOverQuietNoiseAreDetected() {
        let noise = Signals.pinkNoise(rmsDecibels: -55, seconds: 3, seed: 3)
        let speech = Signals.concat(Signals.silence(1), Signals.speechLike(seconds: 1, rmsDecibels: -25), Signals.silence(1))
        let probabilities = Pipeline.probabilities(Signals.mix(noise, speech))

        // Syllable cores (200 ms syllables every 250 ms from 1.0 s): clearly speech.
        let cores = [1.05 ... 1.12, 1.30 ... 1.37, 1.55 ... 1.62, 1.80 ... 1.87].flatMap { slice(probabilities, $0) }
        #expect(!cores.isEmpty && cores.allSatisfy { $0 > 0.9 })
        // Before and after: noise only.
        #expect(slice(probabilities, 0.3 ... 0.9).allSatisfy { $0 < 0.2 })
        #expect(slice(probabilities, 2.3 ... 2.9).allSatisfy { $0 < 0.2 })
    }

    @Test func steadyToneIsDetectedAtOnsetThenAbsorbedAsStationaryNoise() {
        let quiet = Signals.whiteNoise(rmsDecibels: -65, seconds: 6, seed: 5)
        let tone = Signals.concat(Signals.silence(1), Signals.sine(frequency: 1_000, amplitude: 0.14, seconds: 5))
        let probabilities = Pipeline.probabilities(Signals.mix(quiet, tone))

        #expect(slice(probabilities, 1.0 ... 1.3).allSatisfy { $0 > 0.9 }, "a tone onset looks like speech to an energy VAD")
        #expect(slice(probabilities, 3.5 ... 5.9).allSatisfy { $0 < 0.35 }, "a steady hum/beep is learned as noise")
    }

    @Test func shortBeepIsReportedAsActivity() {
        // An energy VAD cannot tell a beep from a vowel; the endpointer's minimum speech
        // duration and the ASR decide. Documented behaviour, not a bug.
        let signal = Signals.concat(Signals.silence(1), Signals.sine(frequency: 1_000, amplitude: 0.1, seconds: 0.2), Signals.silence(1))
        let probabilities = Pipeline.probabilities(Signals.mix(signal, Signals.whiteNoise(rmsDecibels: -60, seconds: 2.2, seed: 2)))
        #expect((probabilities.max() ?? 0) > 0.9)
        #expect(slice(probabilities, 1.5 ... 2.1).allSatisfy { $0 < 0.35 })
    }

    @Test func adaptsToANoiseStepWithinTwoSeconds() {
        let signal = Signals.concat(
            Signals.whiteNoise(rmsDecibels: -70, seconds: 2, seed: 9),
            Signals.pinkNoise(rmsDecibels: -35, seconds: 4, seed: 10)
        )
        let probabilities = Pipeline.probabilities(signal)
        #expect(slice(probabilities, 4.0 ... 5.9).allSatisfy { $0 < 0.35 })
    }

    @Test func dcOffsetDoesNotChangeDecisions() {
        let base = Signals.mix(
            Signals.whiteNoise(rmsDecibels: -55, seconds: 3, seed: 21),
            Signals.concat(Signals.silence(1), Signals.speechLike(seconds: 1, rmsDecibels: -28))
        )
        let original = Pipeline.probabilities(base)
        for offset in [0.25, -0.4] as [Float] {
            let shifted = Pipeline.probabilities(base.map { $0 + offset })
            let difference = zip(original, shifted).dropFirst().map { abs($0 - $1) }.max() ?? 1
            #expect(difference < 0.02, "DC offset \(offset)")
        }
    }

    @Test func isDeterministic() {
        let signal = Signals.mix(
            Signals.pinkNoise(rmsDecibels: -45, seconds: 2, seed: 4),
            Signals.concat(Signals.silence(0.5), Signals.speechLike(seconds: 1, rmsDecibels: -30))
        )
        #expect(Pipeline.probabilities(signal) == Pipeline.probabilities(signal))
    }

    @Test func toleratesNonFiniteSamples() {
        var core = EnergyVADCore()
        var frame = [Float](repeating: 0.01, count: 512)
        frame[10] = .nan
        frame[20] = .infinity
        let probability = core.process(frame)
        #expect(probability.isFinite)
        #expect(core.noiseFloorDecibels.isFinite)
    }

    @Test func acceptsOtherFrameSizes() {
        var configuration = EnergyVADConfiguration()
        configuration.frameSamples = 256
        var core = EnergyVADCore(configuration: configuration)
        let signal = Signals.mix(
            Signals.whiteNoise(rmsDecibels: -55, seconds: 2, seed: 8),
            Signals.concat(Signals.silence(1), Signals.speechLike(seconds: 1, rmsDecibels: -25))
        )
        let probabilities = stride(from: 0, to: signal.count - 255, by: 256).map {
            core.process(Array(signal[$0 ..< $0 + 256]))
        }
        let frameTime = { (index: Int) in Double(index) * 256 / 16_000 }
        #expect(probabilities.enumerated().filter { (0.3 ... 0.9).contains(frameTime($0.offset)) }.allSatisfy { $0.element < 0.2 })
        #expect(probabilities.enumerated().filter { (1.05 ... 1.12).contains(frameTime($0.offset)) }.allSatisfy { $0.element > 0.9 })
    }

    @Test func conformsToVoiceActivityDetectingAndResets() async {
        let vad: any VoiceActivityDetecting = EnergyVAD()
        #expect(vad.frameSamples == 512)
        let frames = Pipeline.frames(Signals.mix(
            Signals.whiteNoise(rmsDecibels: -50, seconds: 2, seed: 1),
            Signals.concat(Signals.silence(1), Signals.speechLike(seconds: 1, rmsDecibels: -25))
        ))
        var first: [Float] = []
        for frame in frames { first.append(await vad.speechProbability(frame.samples)) }
        await vad.reset()
        var second: [Float] = []
        for frame in frames { second.append(await vad.speechProbability(frame.samples)) }
        #expect(first == second)
        #expect((first.max() ?? 0) > 0.9)
    }
}
