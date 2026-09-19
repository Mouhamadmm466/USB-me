@testable import Audio
import Core
import Foundation
import Testing

/// End-to-end checks of the capture-side logic on real recorded speech
/// (`Scripts/generate_audio_fixtures.sh`): framing → `EnergyVADCore` → `EndpointDetector` /
/// `EchoBargeInController`.
@Suite struct AudioFixtureTests {
    // MARK: - Manifest and files

    @Test func manifestDescribesEveryFixtureAndStaysWithinBudget() throws {
        let manifest = try Fixtures.manifest()
        #expect(manifest.sampleRate == 16_000)
        #expect(manifest.channels == 1)
        #expect(manifest.bitsPerSample == 16)
        #expect(manifest.fixtures.count >= 25)

        var totalBytes = 0
        for fixture in manifest.fixtures {
            let url = Fixtures.url(fixture.file)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, "\(fixture.file)")
            totalBytes += size
            let wav = try WAVReader.read(url)
            #expect(wav.sampleRate == 16_000, "\(fixture.file)")
            #expect(wav.channelCount == 1, "\(fixture.file)")
            #expect(wav.bitsPerSample == 16, "\(fixture.file)")
            #expect(abs(wav.duration - fixture.durationSeconds) < 0.01, "\(fixture.file)")
            #expect(fixture.windows.allSatisfy { $0.upperBound <= fixture.durationSeconds }, "\(fixture.file)")
        }
        #expect(totalBytes < 5 * 1_024 * 1_024)

        let kinds = Set(manifest.fixtures.map(\.kind))
        #expect(kinds.isSuperset(of: ["command", "silence", "noise", "mix", "pause", "echo_assistant_only", "echo_overlap"]))
        #expect(Set(manifest.fixtures.compactMap(\.voice)).count >= 3, "several different voices")
        #expect(Set(manifest.fixtures(ofKind: "mix").compactMap(\.snr)) == [5, 10, 20])
    }

    @Test func wavReaderDecodesTheHeaderAndSamples() throws {
        // 16-bit mono, samples [0, 16384, -32768].
        var bytes: [UInt8] = Array("RIFF".utf8) + [42, 0, 0, 0] + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0]
        bytes += Array("data".utf8) + [6, 0, 0, 0, 0, 0, 0x00, 0x40, 0x00, 0x80]
        let wav = try WAVReader.parse(Data(bytes))
        #expect(wav.sampleRate == 16_000)
        #expect(wav.mono == [0, 0.5, -1])
        #expect(throws: WAVReaderError.notRIFF) { try WAVReader.parse(Data(Array("RIFX".utf8) + [UInt8](repeating: 0, count: 8))) }
    }

    // MARK: - Endpointing on speech

    @Test(arguments: Fixtures.all(ofKind: "command"))
    func cleanCommandsAreOneUtteranceWithAccurateBoundaries(fixture: Fixture) throws {
        let result = Pipeline.run(try Fixtures.samples(fixture.file))
        let window = try #require(fixture.windows.first)

        #expect(result.onsets.count == 1)
        let utterance = try #require(result.utterances.first?.utterance)
        #expect(result.utterances.count == 1)
        #expect(utterance.speechStartTime >= window.lowerBound - 0.05 && utterance.speechStartTime <= window.lowerBound + 0.1)
        #expect(abs(utterance.speechEndTime - window.upperBound) <= 0.1)
        // The audio handed to ASR contains the whole utterance plus pre-roll and a short tail.
        #expect(utterance.startTime <= window.lowerBound - 0.1)
        #expect(utterance.endTime >= window.upperBound)
        #expect(utterance.endTime <= utterance.speechEndTime + 0.151)
    }

    @Test(arguments: Fixtures.all(ofKind: "command"))
    func vadSeparatesSpeechFramesFromSilenceFrames(fixture: Fixture) throws {
        let probabilities = Pipeline.probabilities(try Fixtures.samples(fixture.file))
        let (speech, silence) = frameScores(probabilities, windows: fixture.windows)
        #expect(speech.recall >= 0.9, "speech frames detected: \(speech)")
        #expect(silence.recall == 1, "silent frames rejected: \(silence)")
    }

    @Test(arguments: Fixtures.all(ofKind: "pause"))
    func aFourHundredMillisecondPauseDoesNotSplitTheUtterance(fixture: Fixture) throws {
        let result = Pipeline.run(try Fixtures.samples(fixture.file))
        let first = try #require(fixture.windows.first)
        let last = try #require(fixture.windows.last)
        #expect(fixture.windows.count == 2)

        #expect(result.onsets.count == 1)
        let utterance = try #require(result.utterances.first?.utterance)
        #expect(result.utterances.count == 1)
        #expect(utterance.speechStartTime <= first.lowerBound + 0.1)
        #expect(utterance.speechEndTime >= last.upperBound - 0.1)
    }

    @Test(arguments: Fixtures.all(ofKind: "mix"))
    func noisyMixesAreEndpointedDownToFiveDecibelsSNR(fixture: Fixture) throws {
        let samples = try Fixtures.samples(fixture.file)
        let result = Pipeline.run(samples)
        let window = try #require(fixture.windows.first)

        #expect(result.onsets.count == 1, "SNR \(fixture.snr ?? -1) dB")
        let utterance = try #require(result.utterances.first?.utterance)
        #expect(result.utterances.count == 1)
        #expect(utterance.speechStartTime >= window.lowerBound - 0.1)
        #expect(utterance.speechStartTime <= window.lowerBound + 0.3, "late onset is still covered by the pre-roll")
        #expect(utterance.startTime <= window.lowerBound, "pre-roll reaches back to the first syllable")
        #expect(utterance.speechEndTime >= window.upperBound - 0.3)
        #expect(utterance.speechEndTime <= window.upperBound + 0.15)

        let (speech, silence) = frameScores(Pipeline.probabilities(samples), windows: fixture.windows)
        #expect(speech.recall >= 0.5, "\(speech)")
        #expect(silence.recall >= 0.98, "\(silence)")
    }

    // MARK: - Silence and noise

    @Test func digitalSilenceNeverStartsSpeechAndTimesOut() throws {
        var config = EndpointingConfig()
        config.noSpeechTimeoutMilliseconds = 2_000
        let result = Pipeline.run(try Fixtures.samples("silence.wav"), endpointing: config)
        #expect(result.onsets.isEmpty)
        #expect(result.timeouts.count == 1)
        #expect(result.timeouts.first.map { abs(Double($0 + 1) * Pipeline.frameDuration - 2.0) <= 0.032 } == true)
    }

    @Test(arguments: Fixtures.all(ofKind: "noise"))
    func noiseBedsAreNeverSpeech(fixture: Fixture) throws {
        let result = Pipeline.run(try Fixtures.samples(fixture.file))
        #expect(result.onsets.isEmpty)
        #expect((result.probabilities.max() ?? 1) < 0.2)
    }

    // MARK: - Echo and barge-in

    /// Plays a fixture into `EchoBargeInController` while "the assistant speaks", with a
    /// simulated quick ASR partial that answers `asrLatencyFrames` after each candidate.
    private struct BargeInRun {
        var candidates: [BargeInCandidate] = []
        var verdicts: [(time: TimeInterval, event: BargeInEvent)] = []

        var confirmations: [(time: TimeInterval, confirmation: BargeInConfirmation)] {
            verdicts.compactMap { if case let .confirmedBargeIn(value) = $0.event { ($0.time, value) } else { nil } }
        }

        var rejections: [BargeInRejection] {
            verdicts.compactMap { if case let .rejectedEcho(value) = $0.event { value } else { nil } }
        }
    }

    private func runBargeIn(
        _ fixture: Fixture,
        asrLatencyFrames: Int = 10,
        transcript: (BargeInCandidate, TimeInterval) -> String
    ) throws -> BargeInRun {
        let samples = try Fixtures.samples(fixture.file)
        let assistantText = try #require(fixture.text)
        let assistantEnd = fixture.assistantRanges.last?.upperBound ?? 0
        var controller = EchoBargeInController(logger: nil)
        var vad = EnergyVADCore()
        var run = BargeInRun()
        var pending: (candidate: BargeInCandidate, dueFrame: Int)?
        controller.assistantDidStartSpeaking(text: assistantText)

        for (index, frame) in Pipeline.frames(samples, assistantSpeaking: { $0 <= assistantEnd + 0.25 }).enumerated() {
            if controller.isAssistantSpeaking, frame.timestamp > assistantEnd {
                controller.assistantDidStopSpeaking()
            }
            let now = frame.timestamp + Pipeline.frameDuration
            switch controller.process(probability: vad.process(frame.samples), frame: frame) {
            case let .candidate(candidate)?:
                run.candidates.append(candidate)
                pending = (candidate, index + asrLatencyFrames)
            case let verdict?:
                run.verdicts.append((now, verdict))
                pending = nil
            case nil:
                break
            }
            if let current = pending, index >= current.dueFrame {
                pending = nil
                let verdict = controller.evaluate(candidateTranscript: transcript(current.candidate, now), assistantText: assistantText)
                run.verdicts.append((now, verdict))
            }
        }
        return run
    }

    /// Words of `text` spoken during `[start, end]`, assuming an even speaking rate over `window`.
    private func words(of text: String, in window: ClosedRange<Double>, from start: Double, to end: Double) -> String {
        let words = text.split(separator: " ")
        let span = window.upperBound - window.lowerBound
        let first = Int(((max(start, window.lowerBound) - window.lowerBound) / span * Double(words.count)).rounded(.down))
        let last = Int(((min(end, window.upperBound) - window.lowerBound) / span * Double(words.count)).rounded(.up))
        guard first < last else { return "" }
        return words[max(0, first) ..< min(words.count, last)].joined(separator: " ")
    }

    @Test func assistantEchoAloneIsNeverConfirmedAsABargeIn() throws {
        let fixture = try #require(try Fixtures.manifest().fixture(named: "echo_assistant_only.wav"))
        let assistant = try #require(fixture.assistantRanges.first)
        let run = try runBargeIn(fixture) { candidate, now in
            // What ASR hears is the assistant's own sentence.
            words(of: fixture.text ?? "", in: assistant, from: candidate.utteranceStartTime, to: now)
        }
        // Without AEC the raw echo is loud speech, so candidates are raised (and ducked)…
        #expect(!run.candidates.isEmpty)
        // …but the transcript check rejects every one of them.
        #expect(run.confirmations.isEmpty)
        #expect(!run.rejections.isEmpty)
        #expect(run.rejections.allSatisfy { $0.reason == .echo || $0.reason == .tooShort || $0.reason == .timeout })
    }

    @Test func userTalkingOverTheAssistantIsConfirmedAfterTheyStart() throws {
        let fixture = try #require(try Fixtures.manifest().fixture(named: "echo_overlap.wav"))
        let assistant = try #require(fixture.assistantRanges.first)
        let user = try #require(fixture.userRanges.first)
        let userText = try #require(fixture.userText)
        let run = try runBargeIn(fixture) { candidate, now in
            // Before the user starts, ASR hears only the echo; afterwards it picks up the user.
            now > user.lowerBound + 0.2
                ? userText
                : words(of: fixture.text ?? "", in: assistant, from: candidate.utteranceStartTime, to: now)
        }
        let confirmation = try #require(run.confirmations.first)
        #expect(run.confirmations.count == 1)
        #expect(confirmation.time > user.lowerBound, "no confirmation from echo alone")
        #expect(confirmation.time < user.lowerBound + 2.0, "the user is not ignored")
        #expect(confirmation.confirmation.reason == .interruptionKeyword, "\"stop\" is not in the assistant's text")
        #expect(confirmation.confirmation.audio.count > 16_000 / 2, "captured audio is handed over as the new utterance")
    }

    @Test func residualEchoAfterAECDoesNotReachTheStrictThresholds() throws {
        let fixture = try #require(try Fixtures.manifest().fixture(named: "echo_residual_assistant_only.wav"))
        let samples = try Fixtures.samples(fixture.file)

        // Normal thresholds would open an utterance on the residual echo…
        #expect(!Pipeline.run(samples, mode: .normal).onsets.isEmpty)
        // …playback-aware (strict) thresholds do not.
        #expect(Pipeline.run(samples, mode: .automatic, assistantSpeaking: { _ in true }).onsets.isEmpty)
        let run = try runBargeIn(fixture) { _, _ in "" }
        #expect(run.candidates.isEmpty)
    }

    @Test func userOverResidualEchoRaisesACandidateQuickly() throws {
        let fixture = try #require(try Fixtures.manifest().fixture(named: "echo_residual_overlap.wav"))
        let user = try #require(fixture.userRanges.first)
        let userText = try #require(fixture.userText)
        let run = try runBargeIn(fixture) { _, _ in userText }

        let candidate = try #require(run.candidates.first)
        #expect(candidate.detectedAt >= user.lowerBound, "the residual echo alone raised no candidate")
        #expect(candidate.detectedAt <= user.lowerBound + 0.6, "strict onset within ~320 ms of speech plus frame rounding")
        #expect(candidate.utteranceStartTime <= user.lowerBound + 0.05, "pre-roll keeps the first word")
        #expect(run.confirmations.count == 1)
    }

    // MARK: - Helpers

    private struct Score: CustomStringConvertible {
        var hits = 0
        var total = 0
        var recall: Double { total > 0 ? Double(hits) / Double(total) : 1 }
        var description: String { "\(hits)/\(total)" }
    }

    /// Speech frames: fully inside a window (60 ms margin), scored p ≥ 0.5. Silence frames: at
    /// least 150 ms from any window, scored p < 0.35 (the continue threshold).
    private func frameScores(_ probabilities: [Float], windows: [ClosedRange<Double>]) -> (speech: Score, silence: Score) {
        var speech = Score()
        var silence = Score()
        for (index, probability) in probabilities.enumerated() {
            let start = Double(index) * Pipeline.frameDuration
            let end = start + Pipeline.frameDuration
            if windows.contains(where: { start >= $0.lowerBound + 0.06 && end <= $0.upperBound - 0.06 }) {
                speech.total += 1
                if probability >= 0.5 { speech.hits += 1 }
            } else if windows.allSatisfy({ end < $0.lowerBound - 0.15 || start > $0.upperBound + 0.15 }) {
                silence.total += 1
                if probability < 0.35 { silence.hits += 1 }
            }
        }
        return (speech, silence)
    }
}
