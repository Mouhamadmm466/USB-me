import ASR
import Audio
import Core
import Foundation
import Testing

/// Speech-recognition and VAD tests on the checked-in `say`-generated fixtures, using the exact
/// pinned Whisper base.en and Silero VAD models from ModelCache/ (skipped when absent).
@Suite(.serialized) struct ASRFixtureTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Tests/Audio/Fixtures")
    static let whisperModel = root.appendingPathComponent("ModelCache/ggml-base.en.bin")
    static let vadModel = root.appendingPathComponent("ModelCache/ggml-silero-v6.2.0.bin")
    static var modelsAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperModel.path) && FileManager.default.fileExists(atPath: vadModel.path)
    }

    static let runtime = WhisperRuntime(modelURL: whisperModel)

    struct Manifest: Decodable {
        struct Fixture: Decodable {
            let file: String
            let kind: String
            let text: String?
            let snr: Int?
            let speechWindows: [[Double]]
            let userText: String?
        }
        let fixtures: [Fixture]
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    }

    @Test(.enabled(if: modelsAvailable)) func cleanCommandsTranscribeAccurately() async throws {
        var errors: [String: Double] = [:]
        for fixture in try Self.manifest().fixtures where fixture.kind == "command" {
            let samples = try WAV.read(Self.fixtures.appendingPathComponent(fixture.file))
            let final = try await Self.runtime.final(samples, context: ASRContext())
            let wer = WordErrorRateTest.compute(reference: fixture.text ?? "", hypothesis: final.text)
            errors[fixture.file] = wer
            #expect(wer <= 0.34, "\(fixture.file): '\(final.text)' WER \(wer)")
        }
        let mean = errors.values.reduce(0, +) / Double(max(1, errors.count))
        #expect(mean <= 0.12, "mean WER \(mean)")
    }

    @Test(.enabled(if: modelsAvailable)) func noisyMixesStayUsableAtModerateSNR() async throws {
        for fixture in try Self.manifest().fixtures where fixture.kind == "mix" && (fixture.snr ?? 0) >= 10 {
            let samples = try WAV.read(Self.fixtures.appendingPathComponent(fixture.file))
            let final = try await Self.runtime.final(samples, context: ASRContext())
            let wer = WordErrorRateTest.compute(reference: fixture.text ?? "", hypothesis: final.text)
            #expect(wer <= 0.5, "\(fixture.file): '\(final.text)' WER \(wer)")
        }
    }

    @Test(.enabled(if: modelsAvailable)) func silenceAndNoiseProduceNoTranscript() async throws {
        for file in ["silence.wav", "noise_pink.wav", "noise_brown.wav"] {
            let samples = try WAV.read(Self.fixtures.appendingPathComponent(file))
            let final = try await Self.runtime.final(samples, context: ASRContext())
            #expect(final.text.isEmpty, "\(file) hallucinated '\(final.text)'")
        }
    }

    @Test(.enabled(if: modelsAvailable)) func contactNamesBiasRecognition() async throws {
        let samples = try WAV.read(Self.fixtures.appendingPathComponent("cmd_text_alex_samantha.wav"))
        let final = try await Self.runtime.final(samples, context: ASRContext(biasPhrases: ["Alex Kim", "Priya Patel"]))
        #expect(final.text.lowercased().contains("alex"))
    }

    @Test(.enabled(if: modelsAvailable)) func partialHypothesisIsFastAndRelated() async throws {
        let samples = try WAV.read(Self.fixtures.appendingPathComponent("cmd_text_alex_samantha.wav"))
        let partial = try await Self.runtime.partial(Array(samples.prefix(Int(16_000 * 2.0))), revision: 1)
        #expect(partial.revision == 1)
        #expect(partial.text.lowercased().contains("text") || partial.text.lowercased().contains("alex"))
    }

    @Test(.enabled(if: modelsAvailable)) func sileroVADFindsSpeechAndIgnoresNoise() async throws {
        let vad = try SileroVAD(modelURL: Self.vadModel)
        for fixture in try Self.manifest().fixtures where fixture.kind == "command" || fixture.kind == "noise" || fixture.kind == "silence" {
            await vad.reset()
            let samples = try WAV.read(Self.fixtures.appendingPathComponent(fixture.file))
            var speechFrames = 0
            var index = 0
            while index + 512 <= samples.count {
                if vad.probability(Array(samples[index..<(index + 512)])) > 0.5 { speechFrames += 1 }
                index += 512
            }
            let speechSeconds = Double(speechFrames * 512) / 16_000
            let expected = fixture.speechWindows.reduce(0) { $0 + ($1[1] - $1[0]) }
            if expected == 0 {
                #expect(speechSeconds < 0.2, "\(fixture.file): \(speechSeconds)s of false speech")
            } else {
                #expect(abs(speechSeconds - expected) < max(0.35, expected * 0.4), "\(fixture.file): \(speechSeconds)s vs \(expected)s")
            }
        }
    }

    @Test(.enabled(if: modelsAvailable)) func endpointingWithSileroYieldsOneUtterancePerCommand() async throws {
        let vad = try SileroVAD(modelURL: Self.vadModel)
        for fixture in try Self.manifest().fixtures where fixture.kind == "command" || fixture.file.hasPrefix("pause_") {
            await vad.reset()
            var detector = EndpointDetector(config: EndpointingConfig())
            let samples = try WAV.read(Self.fixtures.appendingPathComponent(fixture.file)) + [Float](repeating: 0, count: 16_000)
            var utterances: [Utterance] = []
            var index = 0
            while index + 512 <= samples.count {
                let frame = AudioFrame(samples: Array(samples[index..<(index + 512)]), timestamp: Double(index) / 16_000, assistantWasSpeaking: false)
                if case let .speechEnded(utterance)? = detector.process(probability: vad.probability(frame.samples), frame: frame) {
                    utterances.append(utterance)
                }
                index += 512
            }
            #expect(utterances.count == 1, "\(fixture.file): \(utterances.count) utterances")
            if let utterance = utterances.first, let window = fixture.speechWindows.first {
                #expect(abs(utterance.speechStartTime - window[0]) < 0.2, "\(fixture.file) start")
            }
        }
    }

    /// Self-transcription guard: the assistant's own voice picked up by the mic must be recognized
    /// as echo, not as a user barge-in.
    @Test(.enabled(if: modelsAvailable)) func assistantEchoIsRejectedAndRealInterruptionIsConfirmed() async throws {
        let manifest = try Self.manifest()
        guard let echo = manifest.fixtures.first(where: { $0.file == "echo_assistant_only.wav" }),
              let overlap = manifest.fixtures.first(where: { $0.file == "echo_overlap.wav" }),
              let assistantText = echo.text else {
            Issue.record("echo fixtures missing"); return
        }
        let echoSamples = try WAV.read(Self.fixtures.appendingPathComponent(echo.file))
        let echoTranscript = try await Self.runtime.partial(echoSamples, revision: 1).text
        var controller = EchoBargeInController()
        controller.assistantDidStartSpeaking(text: assistantText)
        #expect(controller.evaluate(candidateTranscript: echoTranscript, assistantText: assistantText).playbackCommand == .unduck,
                "echo transcript '\(echoTranscript)' was not rejected")

        let overlapSamples = try WAV.read(Self.fixtures.appendingPathComponent(overlap.file))
        let userText = overlap.userText ?? ""
        let start = Int(16_000 * 1.0)
        let userPortion = Array(overlapSamples[min(start, overlapSamples.count)...])
        let overlapTranscript = try await Self.runtime.partial(userPortion, revision: 1).text
        var second = EchoBargeInController()
        second.assistantDidStartSpeaking(text: assistantText)
        let verdict = second.evaluate(candidateTranscript: overlapTranscript, assistantText: assistantText)
        #expect(verdict.playbackCommand == .stop || userText.isEmpty,
                "interruption '\(overlapTranscript)' (user said '\(userText)') was not confirmed")
    }
}

enum WAV {
    /// Reads 16-bit PCM mono WAV into Float samples.
    static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
                return body.withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
                }
            }
            offset += 8 + size + (size % 2)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}

enum WordErrorRateTest {
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference), hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0...hyp.count)
        for (i, r) in ref.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hyp.count)
            for (j, h) in hyp.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    static func normalize(_ text: String) -> [String] {
        let map = ["twenty": "20", "six": "6", "whats": "what's", "i'll": "i will", "pm": "p.m.", "p.m": "p.m."]
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" ? $0 : " " }
        return String(cleaned).split(separator: " ").flatMap { word -> [String] in
            let mapped = map[String(word)] ?? String(word)
            return mapped.split(separator: " ").map(String.init)
        }
    }
}
