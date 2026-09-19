import AVFAudio
@testable import Audio
import Testing

@Suite struct ResamplerTests {
    static func format(_ rate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    /// Streams `input` through one resampler in chunks cycling through `sizes`.
    private func stream(_ input: [Float], rate: Double, sizes: [Int], channels: Int = 1) throws -> [Float] {
        let resampler = try StreamingResampler(inputFormat: Self.format(rate, channels: AVAudioChannelCount(channels)))
        var output: [Float] = []
        var offset = 0
        var index = 0
        while offset < input.count {
            let size = min(sizes[index % sizes.count], input.count - offset)
            let chunk = Array(input[offset ..< offset + size])
            output += try resampler.convert(channels: Array(repeating: chunk, count: channels))
            offset += size
            index += 1
        }
        return output
    }

    /// Middle part of a converted tone (skips the filter's start-up region).
    private func steadyState(_ output: [Float]) -> [Float] {
        Array(output[1_600 ..< output.count - 1_600])
    }

    @Test(arguments: [[480], [4_800], [441, 1_000, 7, 2_048]])
    func downsampling48kPreservesA440HzToneFrequencyAndRMS(chunkSizes: [Int]) throws {
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 1, rate: 48_000)
        let output = try stream(tone, rate: 48_000, sizes: chunkSizes)

        // Every input frame is converted whatever the chunking (the converter must be fed in the
        // slices it requests, or it silently drops the rest of a large tap buffer).
        #expect(abs(output.count - 16_000) <= 2)
        let steady = steadyState(output)
        #expect(abs(Signals.zeroCrossingFrequency(steady, rate: 16_000) - 440) < 0.5)
        #expect(abs(LevelMeter.rms(steady) - 0.5 / Float(2).squareRoot()) < 0.01)
        // Continuity across tap-buffer seams: no step larger than the tone's own maximum slope
        // (2π·440·0.5 / 16 kHz ≈ 0.086).
        let largestStep = zip(steady, steady.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(largestStep < 0.095)
    }

    @Test func downsampling44_1kPreservesToneFrequencyAndRMS() throws {
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 1, rate: 44_100)
        let output = try stream(tone, rate: 44_100, sizes: [4_410])

        #expect(abs(output.count - 16_000) <= 2)
        let steady = steadyState(output)
        #expect(abs(Signals.zeroCrossingFrequency(steady, rate: 16_000) - 440) < 0.5)
        #expect(abs(LevelMeter.rms(steady) - 0.5 / Float(2).squareRoot()) < 0.01)
    }

    @Test func bluetoothWidebandRateIsConvertedToo() throws {
        // HFP wideband routes deliver 24 kHz (some 16 kHz, which passes through).
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 1, rate: 24_000)
        let output = try stream(tone, rate: 24_000, sizes: [2_400])
        #expect(abs(output.count - 16_000) <= 2)
        #expect(abs(Signals.zeroCrossingFrequency(steadyState(output), rate: 16_000) - 440) < 0.5)
    }

    @Test func stereoInputIsDownmixedToMono() throws {
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 1, rate: 48_000)
        let output = try stream(tone, rate: 48_000, sizes: [4_800], channels: 2)
        let steady = steadyState(output)

        #expect(abs(Signals.zeroCrossingFrequency(steady, rate: 16_000) - 440) < 0.5)
        // Identical channels: the downmix must neither drop the signal nor clip it.
        let rms = LevelMeter.rms(steady)
        #expect(rms > 0.3 && rms < 0.75)
    }

    @Test func downsamplingRemovesContentAboveTheNewNyquist() throws {
        // 12 kHz cannot exist at 16 kHz; the anti-aliasing filter must remove it, not fold it to 4 kHz.
        let tone = Signals.sine(frequency: 12_000, amplitude: 0.5, seconds: 1, rate: 48_000)
        let output = try stream(tone, rate: 48_000, sizes: [4_800])
        #expect(LevelMeter.rms(steadyState(output)) < 0.01)
    }

    @Test func sixteenKilohertzMonoPassesThroughUnchanged() throws {
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 0.5)
        let output = try stream(tone, rate: 16_000, sizes: [1_600])
        #expect(output.count == tone.count)
        #expect(zip(output, tone).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func oneShotUpsamplingForPlaybackKeepsLengthRatioAndPitch() throws {
        let tone = Signals.sine(frequency: 440, amplitude: 0.5, seconds: 1)
        let output = try StreamingResampler.resample(tone, from: 16_000, to: 24_000)

        #expect(abs(output.count - 24_000) <= 2, "latency-compensated one-shot conversion keeps the exact length")
        let steady = Array(output[2_400 ..< 21_600])
        #expect(abs(Signals.zeroCrossingFrequency(steady, rate: 24_000) - 440) < 0.5)
        #expect(abs(LevelMeter.rms(steady) - 0.5 / Float(2).squareRoot()) < 0.01)
        #expect(try StreamingResampler.resample(tone, from: 16_000, to: 16_000) == tone)
    }

    @Test func rejectsBuffersInAnotherFormat() throws {
        let resampler = try StreamingResampler(inputFormat: Self.format(48_000))
        let buffer = try #require(StreamingResampler.makeBuffer(format: Self.format(44_100), channels: [[0, 0, 0]]))
        #expect(throws: AudioResamplerError.formatMismatch) {
            try resampler.convert(buffer) { _ in }
        }
    }

    @Test func rejectsFormatsWithoutChannelsOrRate() {
        #expect(throws: AudioResamplerError.unsupportedFormat) {
            try StreamingResampler.resample([0, 1], from: 0, to: 16_000)
        }
    }
}
