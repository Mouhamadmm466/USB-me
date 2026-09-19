@testable import Audio
import Core
import Testing

@Suite struct AudioFrameAssemblerTests {
    /// Feeds `input` in chunks cycling through `sizes`.
    private func assemble(_ input: [Float], sizes: [Int], into assembler: inout AudioFrameAssembler) -> [AudioFrame] {
        var frames: [AudioFrame] = []
        var offset = 0
        var index = 0
        while offset < input.count {
            let size = min(sizes[index % sizes.count], input.count - offset)
            frames += assembler.append(Array(input[offset ..< offset + size]))
            offset += size
            index += 1
        }
        return frames
    }

    @Test func emitsExact512SampleFramesFromIrregularChunks() {
        var assembler = AudioFrameAssembler()
        let input = (0 ..< 20_000).map { Float($0) } // sample value = index, to check content/order
        let frames = assemble(input, sizes: [320, 1000, 7, 1537, 512, 1, 4800, 999], into: &assembler)

        #expect(frames.count == 20_000 / 512)
        #expect(assembler.bufferedSampleCount == 20_000 % 512)
        #expect(frames.allSatisfy { $0.samples.count == 512 })
        #expect(frames.flatMap(\.samples) == Array(input[0 ..< frames.count * 512]))
        for (index, frame) in frames.enumerated() {
            #expect(frame.samples.first == Float(index * 512))
            #expect(frame.timestamp == Double(index * 512) / 16_000)
        }
    }

    @Test func timestampsAreStrictlyIncreasingAndDriftFree() {
        var assembler = AudioFrameAssembler()
        // One minute of audio in 100 ms tap-sized chunks (1600 samples at 16 kHz).
        let frames = assemble([Float](repeating: 0, count: 60 * 16_000), sizes: [1600], into: &assembler)

        #expect(frames.count == 60 * 16_000 / 512)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.timestamp > $0.timestamp })
        // Sample clock: the last frame is exactly where 512-sample steps put it, no accumulated error.
        #expect(frames.last?.timestamp == Double((frames.count - 1) * 512) / 16_000)
        #expect(assembler.nextFrameTimestamp == Double(frames.count * 512) / 16_000)
    }

    @Test func assistantFlagIsTheOrOfEveryContributingChunk() {
        var assembler = AudioFrameAssembler()
        let none = assembler.append([Float](repeating: 0, count: 300), assistantWasSpeaking: false)
        #expect(none.isEmpty)

        // Completes frame 0 (300 unflagged + 212 flagged samples) and leaves 88 flagged ones.
        let first = assembler.append([Float](repeating: 0, count: 300), assistantWasSpeaking: true)
        #expect(first.map(\.assistantWasSpeaking) == [true])

        // Frame 1 = 88 flagged + 424 unflagged → flagged; frame 2 only unflagged samples.
        let next = assembler.append([Float](repeating: 0, count: 424 + 512), assistantWasSpeaking: false)
        #expect(next.map(\.assistantWasSpeaking) == [true, false])
    }

    @Test func wholeFramesTakeTheFastPathWithoutMixingFlags() {
        var assembler = AudioFrameAssembler()
        let frames = assembler.append([Float](repeating: 1, count: 1024), assistantWasSpeaking: true)
            + assembler.append([Float](repeating: 2, count: 512), assistantWasSpeaking: false)
        #expect(frames.map(\.assistantWasSpeaking) == [true, true, false])
        #expect(frames.map { $0.samples[0] } == [1, 1, 2])
        #expect(assembler.bufferedSampleCount == 0)
    }

    @Test func resynchronizeOnlyMovesTheClockForward() {
        var assembler = AudioFrameAssembler()
        _ = assembler.append([Float](repeating: 0, count: 512 * 10 + 100))
        #expect(assembler.nextFrameIndex == 10)

        // Behind the sample clock: ignored, buffered samples kept.
        let jumpedBack = assembler.resynchronize(toElapsed: 0.2)
        #expect(!jumpedBack)
        #expect(assembler.nextFrameIndex == 10)
        #expect(assembler.bufferedSampleCount == 100)

        // A 0.66 s gap: the clock jumps to frame ⌊1.0 s / 32 ms⌋ = 31 and the stale partial frame is dropped.
        let jumpedForward = assembler.resynchronize(toElapsed: 1.0)
        #expect(jumpedForward)
        #expect(assembler.nextFrameIndex == 31)
        #expect(assembler.bufferedSampleCount == 0)
        let frames = assembler.append([Float](repeating: 0, count: 512))
        #expect(frames.first?.timestamp == Double(31 * 512) / 16_000)
    }

    @Test func resetRestartsTheClock() {
        var assembler = AudioFrameAssembler()
        _ = assembler.append([Float](repeating: 0, count: 2000))
        assembler.reset()
        #expect(assembler.nextFrameIndex == 0)
        #expect(assembler.bufferedSampleCount == 0)
        let restarted = assembler.append([Float](repeating: 0, count: 512))
        #expect(restarted.first?.timestamp == 0)
    }
}
