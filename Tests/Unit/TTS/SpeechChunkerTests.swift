import Core
import Foundation
import Testing
@testable import TTS

@Suite struct SpeechChunkerTests {
    let chunker = SpeechChunker()

    @Test func shortTextIsOneChunk() {
        #expect(chunker.chunks(for: "Sent to Alex Kim.") == ["Sent to Alex Kim."])
    }

    @Test func firstChunkIsShortAndLaterChunksFollowSentences() {
        let text = "You have three events tomorrow: Team sync at 10 AM, lunch with Priya at noon, and the dentist at 3 PM. The first one is in Room 4. Do you want me to move any of them?"
        let chunks = chunker.chunks(for: text)
        #expect(chunks.count >= 2)
        #expect(SpeechChunker.wordCount(chunks[0]) <= 12)
        #expect(chunks.joined(separator: " ").replacingOccurrences(of: "  ", with: " ") == text)
    }

    @Test func confirmationPromptStartsWithItsFirstClause() {
        // The short first clause starts playing while the rest is synthesized.
        let chunks = chunker.chunks(for: "Text Alex Kim: \u{201C}I'll be 20 minutes late.\u{201D} Should I send it?")
        #expect(chunks == ["Text Alex Kim:", "I'll be 20 minutes late. Should I send it?"])
    }

    @Test func firstClauseNeedsTwoWordsBeforeAndAfter() {
        #expect(chunker.chunks(for: "Okay, I won't call Sam.") == ["Okay, I won't call Sam."])
        #expect(chunker.chunks(for: "Lunch with Priya, Friday.") == ["Lunch with Priya, Friday."])
        #expect(chunker.chunks(for: "Lunch with Priya, Friday at noon.") == ["Lunch with Priya,", "Friday at noon."])
        #expect(SpeechChunker(config: { var config = TTSConfig(); config.firstClauseMinWords = 0; return config }())
            .chunks(for: "Lunch with Priya, Friday at noon.") == ["Lunch with Priya, Friday at noon."])
    }

    @Test func abbreviationsDecimalsAndTimesDoNotSplit() {
        let sentences = SpeechChunker.sentences(in: "Meet Dr. Lee at 3.30 p.m. near St. Mark's. Then go home.")
        #expect(sentences.count == 2)
    }

    @Test func phoneNumbersAreReadDigitByDigit() {
        #expect(SpeechTextNormalizer.normalize("Calling 555-010-4477.") == "Calling 5 5 5, 0 1 0, 4 4 7 7.")
        #expect(SpeechTextNormalizer.normalize("Call +1 555-010-4477") == "Call 1, 5 5 5, 0 1 0, 4 4 7 7")
    }

    @Test func emojiAndCurlyQuotesAreRemoved() {
        #expect(SpeechTextNormalizer.normalize("Done 👍 \u{201C}Dentist\u{201D} added") == "Done Dentist added")
    }

    @Test func veryLongSentenceIsSplitWithinLimits() {
        let words = (1...80).map { "word\($0)" }.joined(separator: " ") + "."
        let chunks = chunker.chunks(for: words)
        #expect(SpeechChunker.wordCount(chunks[0]) <= chunker.firstChunkMaxWords)
        for chunk in chunks.dropFirst() {
            #expect(SpeechChunker.wordCount(chunk) <= chunker.maxChunkWords)
        }
        #expect(chunks.map(SpeechChunker.wordCount).reduce(0, +) == 80)
    }

    @Test func streamingChunkerEmitsCompleteSentencesOnly() {
        var streaming = StreamingSpeechChunker()
        #expect(streaming.append("It's sunny").isEmpty)
        #expect(streaming.append(" today. Tomor") == ["It's sunny today."])
        #expect(streaming.append("row it rains.") == ["Tomorrow it rains."])
        #expect(streaming.finish().isEmpty)
    }
}

/// Plays instantly; can be stopped. Records what was played.
actor FakePlayer: AudioPlaying {
    private(set) var played: [Int] = []
    private var continuation: CheckedContinuation<Void, Error>?
    var holdPlayback = false

    func setHold(_ hold: Bool) { holdPlayback = hold }

    func play(_ audio: SynthesizedAudio) async throws {
        played.append(audio.samples.count)
        if holdPlayback {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func stopPlayback() async {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func setDucked(_ ducked: Bool) async {}
}

struct FakeSynthesizer: SpeechSynthesizer {
    func synthesize(_ text: String) async throws -> SynthesizedAudio {
        SynthesizedAudio(samples: [Float](repeating: 0, count: text.count), sampleRate: 24_000)
    }
}

@Suite struct SpeechQueueTests {
    @Test func speaksEveryChunkInOrder() async {
        let player = FakePlayer()
        let queue = SpeechQueue(synthesizer: FakeSynthesizer(), player: player)
        let result = await queue.speak("First sentence here. Second sentence here. Third one.")
        #expect(result == .finished)
        #expect(await player.played.count >= 2)
    }

    @Test func interruptReturnsInterrupted() async {
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: FakeSynthesizer(), player: player)
        async let result = queue.speak("A long answer that the user interrupts. It keeps going.")
        try? await Task.sleep(for: .milliseconds(50))
        await queue.interrupt()
        #expect(await result == .interrupted)
    }

    @Test func stopReturnsFinishedNotInterrupted() async {
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: FakeSynthesizer(), player: player)
        async let result = queue.speak("Should I send it?")
        try? await Task.sleep(for: .milliseconds(50))
        await queue.stop()
        #expect(await result == .finished)
    }

    @Test func withoutEngineSpeechIsANoOp() async {
        let queue = SpeechQueue(synthesizer: nil, player: nil)
        #expect(await queue.speak("Hello") == .finished)
    }

    @Test func trackerReportsAudibleTextDuringAndShortlyAfterSpeech() async {
        let tracker = SpokenTextTracker(echoTail: 10)
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: FakeSynthesizer(), player: player, tracker: tracker)
        async let result = queue.speak("Should I send it?")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tracker.audibleText() == "Should I send it?")
        await queue.stop()
        _ = await result
        #expect(tracker.audibleText() == "Should I send it?")
        #expect(!tracker.isSpeaking)
    }
}

/// Records what was synthesized (in order).
actor RecordingSynthesizer: SpeechSynthesizer {
    private(set) var texts: [String] = []
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    func synthesize(_ text: String) async throws -> SynthesizedAudio {
        texts.append(text)
        if delay > .zero { try await Task.sleep(for: delay) }
        return SynthesizedAudio(samples: [Float](repeating: 0, count: text.count), sampleRate: 24_000)
    }
}

@Suite struct SpeechLeadTests {
    let confirmation = "Text Alex Kim: \u{201C}I'll be 20 minutes late.\u{201D} Should I send it?"

    @Test func matchingReplyContinuesAfterTheLeadWithoutRepeatingIt() async {
        let synthesizer = RecordingSynthesizer()
        let player = FakePlayer()
        let queue = SpeechQueue(synthesizer: synthesizer, player: player)
        var firstAudio = 0
        let counter = Counter()
        await queue.observeFirstAudio { _ in Task { await counter.increment() } }
        await queue.speakLead("Text Alex Kim:")
        let result = await queue.speak(confirmation)
        #expect(result == .finished)
        // The rest's first chunk is synthesized while the lead-in plays (order not fixed).
        let texts = await synthesizer.texts
        #expect(texts.sorted() == ["I'll be 20 minutes late.", "Should I send it?", "Text Alex Kim:"], "\(texts)")
        #expect(texts.filter { $0 == "Text Alex Kim:" }.count == 1, "the lead-in is not repeated")
        #expect(await player.played == ["Text Alex Kim:".count, "I'll be 20 minutes late.".count, "Should I send it?".count],
                "played in order: lead-in, then the rest")
        try? await Task.sleep(for: .milliseconds(20))
        firstAudio = await counter.value
        #expect(firstAudio == 1, "first audio is reported once, for the lead-in")
        #expect(await queue.speak("Should I call Mom?") == .finished, "later replies are unaffected")
    }

    @Test func differentReplyCutsTheLead() async {
        let synthesizer = RecordingSynthesizer()
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: synthesizer, player: player)
        await queue.speakLead("Text Alex Kim:")
        try? await Task.sleep(for: .milliseconds(30))
        await player.setHold(false)
        let result = await queue.speak("Sorry, I didn't catch that. Could you say it again?")
        #expect(result == .finished)
        #expect(await synthesizer.texts.first == "Text Alex Kim:")
        #expect(await synthesizer.texts.contains("Sorry, I didn't catch that."))
    }

    @Test func bargeInOverTheLeadInterruptsTheReply() async {
        let tracker = SpokenTextTracker(echoTail: 0)
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: RecordingSynthesizer(), player: player, tracker: tracker)
        await queue.speakLead("Text Alex Kim:")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(tracker.isSpeaking)
        await queue.interrupt()
        #expect(!tracker.isSpeaking, "listening goes back to normal thresholds after the barge-in")
        #expect(await queue.speak(confirmation) == .interrupted)
        #expect(!tracker.isSpeaking)
    }

    @Test func emptyLeadIsIgnored() async {
        let synthesizer = RecordingSynthesizer()
        let queue = SpeechQueue(synthesizer: synthesizer, player: FakePlayer())
        await queue.speakLead("")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await synthesizer.texts.isEmpty)
    }

    @Test func trackerCoversTheLeadAndTheReply() async {
        let tracker = SpokenTextTracker(echoTail: 10)
        let player = FakePlayer()
        await player.setHold(true)
        let queue = SpeechQueue(synthesizer: RecordingSynthesizer(), player: player, tracker: tracker)
        await queue.speakLead("Text Alex Kim:")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(tracker.isSpeaking)
        #expect(tracker.audibleText() == "Text Alex Kim:")
        await queue.stop()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!tracker.isSpeaking)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
