@testable import Audio
import Core
import Foundation
import Telemetry
import Testing

/// Produces consecutive 32 ms frames (sample value = frame index).
private struct FrameClock {
    private(set) var index = 0

    mutating func next(assistant: Bool = false) -> AudioFrame {
        defer { index += 1 }
        return AudioFrame(
            samples: [Float](repeating: Float(index), count: 512),
            timestamp: Double(index * 512) / 16_000,
            assistantWasSpeaking: assistant
        )
    }
}

/// Stand-in for `AudioEngine` playback: records the commands the barge-in flow issues.
private actor FakePlayer: AudioPlaying {
    private(set) var commands: [String] = []
    private(set) var isDucked = false

    func play(_ audio: SynthesizedAudio) async throws {}

    func stopPlayback() async {
        commands.append("stop")
        isDucked = false
    }

    func setDucked(_ ducked: Bool) async {
        commands.append(ducked ? "duck" : "unduck")
        isDucked = ducked
    }

    func apply(_ command: BargeInEvent.PlaybackCommand) async {
        switch command {
        case .duck: await setDucked(true)
        case .unduck: await setDucked(false)
        case .stop: await stopPlayback()
        }
    }
}

@Suite struct EchoBargeInControllerTests {
    static let assistantText = "You have three events tomorrow. The first one is a dentist appointment at nine."

    private func feed(
        _ controller: inout EchoBargeInController,
        _ clock: inout FrameClock,
        _ count: Int,
        _ probability: Float,
        assistant: Bool = false
    ) -> [(frame: Int, event: BargeInEvent)] {
        var events: [(Int, BargeInEvent)] = []
        for _ in 0 ..< count {
            let frame = clock.next(assistant: assistant)
            if let event = controller.process(probability: probability, frame: frame) {
                events.append((clock.index - 1, event))
            }
        }
        return events
    }

    private struct Prepared {
        var controller: EchoBargeInController
        var clock: FrameClock
        let candidate: BargeInCandidate?
    }

    /// Assistant speaking, 20 quiet frames, then 10 strong frames → candidate at frame 29.
    private func controllerWithCandidate() -> Prepared {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        _ = feed(&controller, &clock, 20, 0.1)
        let events = feed(&controller, &clock, 10, 0.9)
        guard case let .candidate(candidate)? = events.last?.event else {
            return Prepared(controller: controller, clock: clock, candidate: nil)
        }
        return Prepared(controller: controller, clock: clock, candidate: candidate)
    }

    @Test func ignoresSpeechWhileTheAssistantIsSilent() {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        #expect(feed(&controller, &clock, 40, 1.0).isEmpty)
        #expect(controller.phase == .idle)
        #expect(!controller.isArmed)
    }

    @Test func strictOnsetRaisesACandidateThatDucks() throws {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        #expect(feed(&controller, &clock, 20, 0.1).isEmpty)
        let events = feed(&controller, &clock, 12, 0.9)
        #expect(events.count == 1)
        let first = try #require(events.first)
        #expect(first.frame == 29, "320 ms of strong speech = 10 frames")
        #expect(first.event.playbackCommand == .duck)
        guard case let .candidate(candidate) = first.event else {
            Issue.record("expected a candidate")
            return
        }
        #expect(candidate.audio.count == 20 * 512, "320 ms pre-roll + 320 ms onset")
        #expect(abs(candidate.speechStartTime - 20 * 0.032) < 1e-9)
        #expect(controller.phase == .candidate)
        #expect(controller.counters.candidates == 1)
    }

    @Test func moderateSpeechDuringPlaybackIsNotACandidate() {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        #expect(feed(&controller, &clock, 60, 0.6).isEmpty, "0.6 would start normal speech, not a barge-in")
    }

    @Test func assistantsOwnWordsAreRejectedAsEcho() throws {
        var prepared = controllerWithCandidate()
        #expect(prepared.candidate != nil)
        let verdict = prepared.controller.evaluate(candidateTranscript: "the first one is a dentist", assistantText: Self.assistantText)
        guard case let .rejectedEcho(rejection) = verdict else {
            Issue.record("expected echo rejection, got \(verdict)")
            return
        }
        #expect(rejection.reason == .echo)
        #expect(try #require(rejection.similarity) >= 0.55)
        #expect(verdict.playbackCommand == .unduck)
        #expect(prepared.controller.counters.rejectedEcho == 1)
        #expect(prepared.controller.phase == .monitoring, "still speaking: keep watching")
        #expect(prepared.controller.isAssistantSpeaking)
    }

    @Test func distinctUserSpeechIsConfirmedAndKeepsAllCapturedAudio() throws {
        var prepared = controllerWithCandidate()
        let initial = try #require(prepared.candidate)
        // ASR takes ~5 frames; the user keeps talking meanwhile.
        #expect(feed(&prepared.controller, &prepared.clock, 5, 0.9).isEmpty)
        let verdict = prepared.controller.evaluate(candidateTranscript: "What's the weather like today?", assistantText: Self.assistantText)
        guard case let .confirmedBargeIn(confirmation) = verdict else {
            Issue.record("expected confirmation, got \(verdict)")
            return
        }
        #expect(confirmation.reason == .distinctSpeech)
        #expect(try #require(confirmation.similarity) < 0.55)
        #expect(confirmation.audio.count == initial.audio.count + 5 * 512)
        #expect(confirmation.audio.prefix(initial.audio.count).elementsEqual(initial.audio))
        #expect(confirmation.speechStartTime == initial.speechStartTime)
        #expect(verdict.playbackCommand == .stop)
        #expect(!prepared.controller.isAssistantSpeaking)
        #expect(prepared.controller.phase == .idle)
        #expect(prepared.controller.counters.confirmed == 1)
    }

    @Test func interruptionKeywordConfirmsEvenAsASingleWord() {
        var prepared = controllerWithCandidate()
        guard case let .confirmedBargeIn(confirmation) = prepared.controller.evaluate(candidateTranscript: "Stop.", assistantText: Self.assistantText) else {
            Issue.record("expected confirmation")
            return
        }
        #expect(confirmation.reason == .interruptionKeyword)
        #expect(prepared.controller.counters.confirmedByKeyword == 1)

        // …unless the assistant is saying that word itself.
        var echoing = controllerWithCandidate()
        let verdict = echoing.controller.evaluate(candidateTranscript: "stop", assistantText: "The bus stop is on Main Street.")
        #expect(verdict == .rejectedEcho(BargeInRejection(reason: .tooShort, similarity: 1)))
    }

    @Test(arguments: [
        ("", BargeInRejection.Reason.emptyTranscript),
        ("  ...  ", .emptyTranscript),
        ("Thank you.", .ignoredTranscript),
        ("[BLANK_AUDIO]", .ignoredTranscript),
        ("tomorrow", .tooShort),
    ])
    func emptyHallucinatedAndShortTranscriptsAreRejected(transcript: String, reason: BargeInRejection.Reason) {
        var prepared = controllerWithCandidate()
        guard case let .rejectedEcho(rejection) = prepared.controller.evaluate(candidateTranscript: transcript, assistantText: Self.assistantText) else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.reason == reason)
        #expect(prepared.controller.counters.rejectedShortOrEmpty == 1)
    }

    @Test func echoTailKeepsMonitoringFor250Milliseconds() throws {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        _ = feed(&controller, &clock, 10, 0.1)
        _ = feed(&controller, &clock, 5, 0.9)
        controller.assistantDidStopSpeaking()
        #expect(controller.isArmed)
        // Onset completes 5 frames (160 ms) after playback stopped: still inside the tail.
        let events = feed(&controller, &clock, 5, 0.9)
        guard case .candidate? = events.last?.event else {
            Issue.record("expected a candidate inside the echo tail")
            return
        }
    }

    @Test func afterTheEchoTailFramesAreIgnored() {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        _ = feed(&controller, &clock, 10, 0.1)
        controller.assistantDidStopSpeaking()
        _ = feed(&controller, &clock, 8, 0.1) // 256 ms ≥ 250 ms tail
        #expect(!controller.isArmed)
        #expect(feed(&controller, &clock, 30, 0.9).isEmpty, "normal endpointing handles speech after the tail")
        #expect(controller.phase == .idle)
    }

    @Test func aPendingCandidateKeepsTheControllerArmedAfterPlaybackEnds() throws {
        var prepared = controllerWithCandidate()
        prepared.controller.assistantDidStopSpeaking()
        _ = feed(&prepared.controller, &prepared.clock, 20, 0.9) // well past the 250 ms tail
        #expect(prepared.controller.isArmed, "callers gating on isArmed must keep feeding frames")
        #expect(prepared.controller.phase == .candidate)
        // The timeout still resolves it, with all audio captured meanwhile.
        let events = feed(&prepared.controller, &prepared.clock, 30, 0.9)
        guard case let .confirmedBargeIn(confirmation)? = events.first?.event else {
            Issue.record("expected confirmation by persistence")
            return
        }
        #expect(confirmation.reason == .persistentSpeech)
        #expect(confirmation.audio.count == (20 + 47) * 512)
        #expect(!prepared.controller.isArmed)
    }

    @Test func engineFlagArmsMonitoringWithoutExplicitTTSState() {
        var controller = EchoBargeInController(logger: nil)
        var clock = FrameClock()
        _ = feed(&controller, &clock, 10, 0.1, assistant: true)
        let events = feed(&controller, &clock, 10, 0.9, assistant: true)
        guard case .candidate? = events.last?.event else {
            Issue.record("expected a candidate from engine-flagged frames")
            return
        }
    }

    @Test func framesFlaggedAfterAConfirmedBargeInAreTheUsersSpeech() {
        var prepared = controllerWithCandidate()
        _ = prepared.controller.evaluate(candidateTranscript: "no wait, call mom", assistantText: Self.assistantText)
        // The engine keeps flagging frames for its 250 ms echo tail after stopPlayback.
        #expect(feed(&prepared.controller, &prepared.clock, 30, 0.9, assistant: true).isEmpty)
        // The assistant speaks again: flags count again.
        prepared.controller.assistantDidStartSpeaking(text: "Calling mom.")
        let events = feed(&prepared.controller, &prepared.clock, 12, 0.9, assistant: true)
        #expect(events.count == 1)
    }

    @Test func timeoutConfirmsWhenTheUserKeepsTalking() throws {
        var prepared = controllerWithCandidate()
        // No ASR verdict; strong speech continues for the whole 1.5 s timeout (47 frames).
        let events = feed(&prepared.controller, &prepared.clock, 50, 0.9)
        let resolved = try #require(events.first)
        #expect(events.count == 1)
        #expect(resolved.frame == 29 + 47)
        guard case let .confirmedBargeIn(confirmation) = resolved.event else {
            Issue.record("expected confirmation by persistence")
            return
        }
        #expect(confirmation.reason == .persistentSpeech)
        #expect(confirmation.similarity == nil)
        #expect(prepared.controller.counters.confirmedByPersistence == 1)
    }

    @Test func timeoutRejectsWhenTheSpeechStopped() throws {
        var prepared = controllerWithCandidate()
        let events = feed(&prepared.controller, &prepared.clock, 50, 0.1)
        let resolved = try #require(events.first)
        #expect(resolved.event == .rejectedEcho(BargeInRejection(reason: .timeout, similarity: nil)))
        #expect(prepared.controller.counters.rejectedTimeout == 1)
        // A verdict arriving after the timeout is stale.
        let late = prepared.controller.evaluate(candidateTranscript: "hello there", assistantText: Self.assistantText)
        #expect(late == .rejectedEcho(BargeInRejection(reason: .noCandidate, similarity: nil)))
        #expect(prepared.controller.counters.rejectedTimeout == 1)
        #expect(prepared.controller.counters.confirmed == 0)
    }

    @Test func cooldownAfterRejectionPreventsDuckPumping() throws {
        var prepared = controllerWithCandidate()
        _ = prepared.controller.evaluate(candidateTranscript: "a dentist appointment", assistantText: Self.assistantText)
        let rejectedAt = prepared.clock.index
        // The echo phrase continues: 300 ms cooldown (10 frames) + 10 frames of strict onset.
        let events = feed(&prepared.controller, &prepared.clock, 30, 0.9)
        let next = try #require(events.first)
        #expect(next.frame == rejectedAt + 19)
    }

    @Test func duckUnduckAndStopAreSequencedForThePlayer() async throws {
        // Echo: duck while verifying, then unduck; playback never stops.
        let echoPlayer = FakePlayer()
        var echo = controllerWithCandidate()
        await echoPlayer.apply(BargeInEvent.candidate(try #require(echo.candidate)).playbackCommand)
        #expect(await echoPlayer.isDucked)
        await echoPlayer.apply(echo.controller.evaluate(candidateTranscript: "you have three events tomorrow", assistantText: Self.assistantText).playbackCommand)
        #expect(await echoPlayer.commands == ["duck", "unduck"])
        #expect(await echoPlayer.isDucked == false)

        // User: duck, then stop (which also clears the duck).
        let userPlayer = FakePlayer()
        var user = controllerWithCandidate()
        await userPlayer.apply(BargeInEvent.candidate(try #require(user.candidate)).playbackCommand)
        await userPlayer.apply(user.controller.evaluate(candidateTranscript: "set a timer for ten minutes", assistantText: Self.assistantText).playbackCommand)
        #expect(await userPlayer.commands == ["duck", "stop"])
        #expect(await userPlayer.isDucked == false)
    }

    @Test func falseBargeInsAreCounted() {
        var prepared = controllerWithCandidate()
        _ = prepared.controller.evaluate(candidateTranscript: "call mom now please", assistantText: Self.assistantText)
        #expect(prepared.controller.counters.confirmed == 1)
        // The new utterance's final transcript is the judge of a confirmed barge-in.
        let genuine = prepared.controller.recordBargeInOutcome(finalTranscript: "call mom now please", assistantText: Self.assistantText)
        #expect(!genuine)
        #expect(prepared.controller.counters.falseBargeInRate == 0)
        let empty = prepared.controller.recordBargeInOutcome(finalTranscript: "", assistantText: Self.assistantText)
        #expect(empty)
        #expect(prepared.controller.counters.falseBargeInRate == 1)
        let hallucination = prepared.controller.recordBargeInOutcome(finalTranscript: "Thank you.", assistantText: Self.assistantText)
        #expect(hallucination)
        let selfTranscription = prepared.controller.recordBargeInOutcome(
            finalTranscript: "The first one is a dentist appointment",
            assistantText: Self.assistantText
        )
        #expect(selfTranscription)
        #expect(prepared.controller.counters.falseBargeIns == 3)
        prepared.controller.resetCounters()
        #expect(prepared.controller.counters == BargeInCounters())
    }

    @Test func lowEchoRiskRoutesRelaxTheStrictThresholds() {
        var controller = EchoBargeInController(logger: nil)
        #expect(controller.effectiveSpeechThreshold == 0.75)
        #expect(controller.effectiveMinSpeechMilliseconds == 320)
        controller.setEchoRisk(.low)
        #expect(controller.effectiveSpeechThreshold == 0.625)
        #expect(controller.effectiveMinSpeechMilliseconds == 250)

        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        let events = feed(&controller, &clock, 10, 0.7)
        #expect(events.first?.frame == 7, "250 ms = 8 frames at p ≥ 0.625")

        var loudspeaker = EchoBargeInController(echoRisk: .high, logger: nil)
        var otherClock = FrameClock()
        loudspeaker.assistantDidStartSpeaking(text: Self.assistantText)
        #expect(feed(&loudspeaker, &otherClock, 20, 0.7).isEmpty)
    }

    @Test func telemetryIsContentFree() {
        let logger = PrivacySafeLogger(ringCapacity: 50)
        var controller = EchoBargeInController(logger: logger)
        var clock = FrameClock()
        controller.assistantDidStartSpeaking(text: Self.assistantText)
        _ = feed(&controller, &clock, 20, 0.1)
        _ = feed(&controller, &clock, 10, 0.9)
        _ = controller.evaluate(candidateTranscript: "the dentist appointment at nine", assistantText: Self.assistantText)
        _ = feed(&controller, &clock, 12, 0.1)
        _ = feed(&controller, &clock, 10, 0.9)
        _ = controller.evaluate(candidateTranscript: "what is the weather", assistantText: Self.assistantText)

        let lines = logger.recentEvents().map(\.event.renderedLine)
        #expect(lines == [
            "safety barge_in=candidate",
            "safety barge_in=echo_rejected",
            "safety barge_in=candidate",
            "safety barge_in=confirmed",
        ])
        #expect(!lines.joined().contains("dentist"))
        #expect(!lines.joined().contains("weather"))
    }
}

@Suite struct TranscriptSimilarityTests {
    @Test(arguments: [
        ("What's on my calendar tomorrow?", ["whats", "on", "my", "calendar", "tomorrow"]),
        ("Remind me at 9:30 a.m.", ["remind", "me", "at", "nine", "thirty", "am"]),
        ("at 6 PM", ["at", "six", "pm"]),
        ("9am", ["nine", "am"]),
        ("the 21st", ["the", "twenty", "first"]),
        ("twenty-one", ["twenty", "one"]),
        ("10:05", ["ten", "oh", "five"]),
        ("call 5551234", ["call", "five", "five", "five", "one", "two", "three", "four"]),
        ("I’m 100% sure", ["im", "one", "hundred", "percent", "sure"]),
        ("", []),
    ])
    func normalization(text: String, words: [String]) {
        #expect(TranscriptSimilarity.normalizedWords(text) == words)
    }

    static let reference = "You have three events tomorrow. The first one is a dentist appointment at nine."

    @Test func aContiguousStretchOfTheAssistantsTextIsFullySimilar() {
        #expect(TranscriptSimilarity.echoSimilarity(candidate: "the first one is a dentist", reference: Self.reference) == 1)
        #expect(TranscriptSimilarity.echoSimilarity(candidate: "at 9", reference: Self.reference) == 1)
    }

    @Test func asrSlipsOnEchoStayAboveTheThreshold() {
        let similarity = TranscriptSimilarity.echoSimilarity(candidate: "you have tree event tomorrow", reference: Self.reference)
        #expect(similarity >= 0.8)
    }

    @Test func reusingTheAssistantsWordsInADifferentOrderIsNotEcho() {
        let reference = "The first one is at nine and the second one is at five."
        let similarity = TranscriptSimilarity.echoSimilarity(candidate: "what about the one at five", reference: reference)
        #expect(similarity < 0.55)
        #expect(TranscriptSimilarity.unigramContainment(candidate: "what about the one at five", reference: reference) > 0.6)
    }

    @Test func unrelatedOrEmptyTextHasNoSimilarity() {
        #expect(TranscriptSimilarity.echoSimilarity(candidate: "call mom please", reference: Self.reference) == 0)
        #expect(TranscriptSimilarity.echoSimilarity(candidate: "", reference: Self.reference) == 0)
        #expect(TranscriptSimilarity.echoSimilarity(candidate: "hello", reference: "") == 0)
    }

    @Test func repeatedWordsAreMatchedAsAMultiset() {
        // Only one "one" in the reference: the second is unmatched.
        #expect(TranscriptSimilarity.unigramContainment(candidate: "one one", reference: "one two") == 0.5)
    }

    @Test func editDistance() {
        #expect(TranscriptSimilarity.editDistance("kitten", "sitting") == 3)
        #expect(TranscriptSimilarity.editDistance("three", "tree") == 1)
        #expect(TranscriptSimilarity.editDistance("", "abc") == 3)
        #expect(TranscriptSimilarity.editDistance("appointment", "apartment", limit: 1) == 2, "early exit returns limit + 1")
    }
}
