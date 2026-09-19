@testable import Audio
import Core
import Foundation
import Testing

/// Synthetic frame scripts: every sample of frame *k* has the value *k*, so the audio an
/// utterance carries can be traced back to frame indices.
private struct Script {
    var frames: [AudioFrame] = []
    var probabilities: [Float] = []

    /// Returns the script extended by `count` frames at `probability`.
    func add(_ count: Int, _ probability: Float, assistant: Bool = false) -> Script {
        var script = self
        for _ in 0 ..< count {
            let index = script.frames.count
            script.frames.append(AudioFrame(
                samples: [Float](repeating: Float(index), count: 512),
                timestamp: Double(index * 512) / 16_000,
                assistantWasSpeaking: assistant
            ))
            script.probabilities.append(probability)
        }
        return script
    }
}

private struct Run {
    var events: [(frame: Int, event: EndpointEvent)] = []

    var starts: [(frame: Int, onset: SpeechOnset)] {
        events.compactMap { if case let .speechStarted(onset) = $0.event { ($0.frame, onset) } else { nil } }
    }

    var ends: [(frame: Int, utterance: Utterance)] {
        events.compactMap { if case let .speechEnded(utterance) = $0.event { ($0.frame, utterance) } else { nil } }
    }

    var maxDurations: [(frame: Int, utterance: Utterance)] {
        events.compactMap { if case let .maxDurationReached(utterance) = $0.event { ($0.frame, utterance) } else { nil } }
    }

    var timeouts: [Int] {
        events.compactMap { if case .noSpeechTimeout = $0.event { $0.frame } else { nil } }
    }

    var progress: [(frame: Int, progress: UtteranceProgress)] {
        events.compactMap { if case let .speechContinuing(progress) = $0.event { ($0.frame, progress) } else { nil } }
    }
}

private func run(
    _ script: Script,
    detector: inout EndpointDetector,
    keepProgress: Bool = false,
    onProgress: (Int, UtteranceProgress, inout EndpointDetector) -> Void = { _, _, _ in }
) -> Run {
    var result = Run()
    for (index, frame) in script.frames.enumerated() {
        guard let event = detector.process(probability: script.probabilities[index], frame: frame) else { continue }
        if case let .speechContinuing(progress) = event {
            onProgress(index, progress, &detector)
            if !keepProgress { continue }
        }
        result.events.append((index, event))
    }
    return result
}

/// Equality within a nanosecond (frame times are sums of 32 ms steps).
private func approx(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

private func run(_ script: Script, mode: EndpointDetector.Mode = .automatic, config: EndpointingConfig = .init()) -> Run {
    var detector = EndpointDetector(config: config, mode: mode)
    return run(script, detector: &detector)
}

@Suite struct EndpointDetectorTests {
    // Frame = 32 ms. Defaults: min speech 180 ms → 6 frames; end silence 700 ms → 22 frames;
    // stable end 500 ms → 16 frames; pre-roll 320 ms → 10 frames; trailing keep 150 ms.

    @Test func speechStartAndEndAreDetectedAtTheExpectedFrames() throws {
        let script = Script().add(50, 0.05).add(50, 0.9).add(60, 0.05)
        let result = run(script)

        let start = try #require(result.starts.first)
        #expect(result.starts.count == 1)
        #expect((54 ... 56).contains(start.frame), "onset confirmed after 6 speech frames (frame 55)")
        #expect(abs(start.onset.speechStartTime - 1.6) < 1e-9)
        #expect(abs(start.onset.utteranceStartTime - 1.28) < 1e-9)
        #expect(abs(start.onset.confirmedAt - 56 * 0.032) < 1e-9)
        #expect(!start.onset.duringAssistantSpeech)

        let end = try #require(result.ends.first)
        #expect(result.ends.count == 1)
        #expect((120 ... 122).contains(end.frame), "end after 22 silent frames (frame 121)")
        let utterance = end.utterance
        #expect(abs(utterance.startTime - 1.28) < 1e-9)
        #expect(abs(utterance.speechStartTime - 1.6) < 1e-9)
        #expect(abs(utterance.speechEndTime - 3.2) < 1e-9)
        // Trailing silence trimmed to 150 ms: 1.28 s … 3.35 s.
        #expect(utterance.samples.count == 33_120)
        #expect(abs(utterance.endTime - 3.35) < 1e-9)
        #expect(!utterance.startedDuringAssistantSpeech)
    }

    @Test func preRollHoldsTheTenFramesBeforeOnset() throws {
        let script = Script().add(50, 0.05).add(50, 0.9).add(60, 0.05)
        let utterance = try #require(run(script).ends.first?.utterance)
        #expect(utterance.samples[0] == 40)
        #expect(utterance.samples[5_119] == 49)
        #expect(utterance.samples[5_120] == 50, "speech onset right after the pre-roll")
    }

    @Test func preRollIsShorterWhenSpeechStartsEarly() throws {
        let script = Script().add(3, 0.0).add(20, 0.9).add(30, 0.0)
        let utterance = try #require(run(script).ends.first?.utterance)
        #expect(approx(utterance.startTime, 0))
        #expect(utterance.samples[0] == 0)
        #expect(abs(utterance.speechStartTime - 0.096) < 1e-9)
    }

    @Test func clicksNeverStartAnUtterance() {
        var script = Script().add(20, 0.0)
        for _ in 0 ..< 10 { script = script.add(1, 1.0).add(5, 0.0) }
        for _ in 0 ..< 5 { script = script.add(2, 1.0).add(4, 0.0) }
        script = script.add(40, 0.0)
        #expect(run(script).events.isEmpty)
    }

    @Test func shortDipsDuringOnsetAreTolerated() throws {
        let script = Script().add(10, 0.0).add(3, 0.9).add(1, 0.1).add(3, 0.9).add(30, 0.0)
        let start = try #require(run(script).starts.first)
        #expect(start.frame == 16, "6th speech frame")
        #expect(abs(start.onset.speechStartTime - 0.32) < 1e-9)
    }

    @Test func hysteresisKeepsSpeechAliveBetweenTheTwoThresholds() throws {
        let script = Script().add(10, 0.0).add(10, 0.9).add(40, 0.4).add(30, 0.0)
        let result = run(script)
        #expect(result.starts.count == 1)
        let end = try #require(result.ends.first)
        #expect(abs(end.utterance.speechEndTime - 60 * 0.032) < 1e-9, "0.4 ≥ continue threshold 0.35 counts as speech")

        let weak = Script().add(10, 0.0).add(40, 0.4).add(10, 0.0)
        #expect(run(weak).starts.isEmpty, "0.4 < start threshold 0.5 never starts speech")
    }

    @Test func aPauseShorterThanTheEndSilenceDoesNotSplitTheUtterance() throws {
        let script = Script().add(20, 0.0).add(30, 0.9).add(13, 0.0).add(30, 0.9).add(30, 0.0) // 416 ms pause
        let result = run(script)
        #expect(result.starts.count == 1)
        #expect(result.ends.count == 1)
        let utterance = try #require(result.ends.first?.utterance)
        #expect(abs(utterance.speechStartTime - 20 * 0.032) < 1e-9)
        #expect(abs(utterance.speechEndTime - 93 * 0.032) < 1e-9)
    }

    @Test func aPauseLongerThanTheEndSilenceSplits() {
        let script = Script().add(20, 0.0).add(30, 0.9).add(25, 0.0).add(30, 0.9).add(30, 0.0) // 800 ms pause
        let result = run(script)
        #expect(result.starts.count == 2)
        #expect(result.ends.count == 2)
    }

    @Test func stableTranscriptEndsTheUtteranceAfter500ms() throws {
        let script = Script().add(20, 0.0).add(30, 0.9).add(40, 0.0) // speech frames 20…49
        var detector = EndpointDetector()
        var marked = false
        let result = run(script, detector: &detector) { _, progress, detector in
            // A partial computed on everything so far came back unchanged: mark it stable.
            if !marked, progress.trailingSilence > 0 {
                detector.markTranscriptStable(true, coveringSampleCount: progress.audio.count)
                marked = true
            }
        }
        let end = try #require(result.ends.first)
        #expect(end.frame == 65, "16 silent frames (512 ms ≥ 500 ms) instead of 22")

        let unmarked = run(script)
        #expect(unmarked.ends.first?.frame == 71)
    }

    @Test func stableMarkDoesNotApplyWhenSpeechContinuedAfterThePartial() throws {
        let script = Script().add(20, 0.0).add(30, 0.9).add(40, 0.0)
        var detector = EndpointDetector()
        let result = run(script, detector: &detector) { frame, progress, detector in
            // Partial computed at frame 40, but the user kept talking until frame 49.
            if frame == 40 { detector.markTranscriptStable(true, coveringSampleCount: progress.audio.count) }
        }
        #expect(result.ends.first?.frame == 71)

        var cleared = EndpointDetector()
        let clearedResult = run(script, detector: &cleared) { _, progress, detector in
            if progress.trailingSilence > 0 {
                detector.markTranscriptStable(true)
                detector.markTranscriptStable(false)
            }
        }
        #expect(clearedResult.ends.first?.frame == 71)
    }

    @Test func maxDurationCutsLongSpeechAt15Seconds() throws {
        let script = Script().add(5, 0.0).add(500, 0.9)
        let result = run(script)
        let cut = try #require(result.maxDurations.first)
        // 15 s = 240 000 samples → 469 frames from onset (frame 5) → frame 473.
        #expect((472 ... 474).contains(cut.frame))
        #expect(abs(cut.utterance.speechStartTime - 0.16) < 1e-9)
        #expect(cut.utterance.samples.count == (5 + 469) * 512, "untrimmed: pre-roll + 469 frames")
        #expect(result.ends.isEmpty)
        #expect(result.starts.count == 2, "speech continues, so a new utterance starts")
    }

    @Test func noSpeechTimeoutFiresOnceAfterEightSeconds() throws {
        let script = Script().add(320, 0.0) // 10.24 s
        let result = run(script)
        #expect(result.timeouts.count == 1)
        let frame = try #require(result.timeouts.first)
        #expect((248 ... 250).contains(frame), "8 s = 250 frames → frame 249")
    }

    @Test func noSpeechTimeoutIsSuspendedWhileTheAssistantSpeaks() throws {
        let script = Script().add(200, 0.0, assistant: true).add(270, 0.0)
        let result = run(script)
        #expect(result.timeouts.count == 1)
        let frame = try #require(result.timeouts.first)
        #expect((448 ... 450).contains(frame), "timer starts when the assistant stops (frame 200 + 249)")
    }

    @Test func noSpeechTimeoutRestartsAfterAnUtterance() throws {
        let script = Script().add(20, 0.0).add(20, 0.9).add(300, 0.0)
        let result = run(script)
        let end = try #require(result.ends.first)
        #expect(end.frame == 61)
        #expect(result.timeouts.count == 1)
        let timeout = try #require(result.timeouts.first)
        #expect((310 ... 312).contains(timeout), "8 s of silence after the utterance ended")
    }

    @Test func timeoutCanBeDisabled() {
        var config = EndpointingConfig()
        config.noSpeechTimeoutMilliseconds = 0
        let script = Script().add(400, 0.0)
        #expect(run(script, config: config).timeouts.isEmpty)
    }

    @Test func bargeInModeRequiresStrongerAndLongerSpeech() throws {
        let moderate = Script().add(10, 0.0).add(40, 0.6).add(30, 0.0)
        #expect(run(moderate, mode: .normal).starts.count == 1)
        #expect(run(moderate, mode: .bargeIn).starts.isEmpty, "0.6 < barge-in threshold 0.75")

        let strong = Script().add(10, 0.0).add(40, 0.8).add(30, 0.0)
        let start = try #require(run(strong, mode: .bargeIn).starts.first)
        #expect(start.frame == 19, "320 ms = 10 frames of strong speech")
        #expect(start.onset.duringAssistantSpeech)
    }

    @Test func automaticModeAppliesStrictThresholdsOnlyToFramesCapturedDuringPlayback() {
        let flagged = Script().add(10, 0.0, assistant: true).add(40, 0.6, assistant: true).add(30, 0.0, assistant: true)
        #expect(run(flagged).starts.isEmpty)

        let unflagged = Script().add(10, 0.0).add(40, 0.6).add(30, 0.0)
        #expect(run(unflagged).starts.count == 1)
    }

    @Test func strictOnsetToleratesShorterGaps() {
        let script = Script().add(10, 0.0).add(5, 0.9).add(2, 0.2).add(10, 0.9).add(30, 0.0)
        #expect(approx(run(script, mode: .normal).starts.first?.onset.speechStartTime, 10 * 0.032))
        // Barge-in: the 64 ms gap exceeds the 32 ms strict tolerance, so the onset restarts at frame 17.
        #expect(approx(run(script, mode: .bargeIn).starts.first?.onset.speechStartTime, 17 * 0.032))
    }

    @Test func partialsAreDueEvery700Milliseconds() {
        let script = Script().add(10, 0.0).add(100, 0.9).add(30, 0.0)
        var detector = EndpointDetector()
        let result = run(script, detector: &detector, keepProgress: true)
        let due = result.progress.filter(\.progress.isPartialDue)
        #expect(due.map(\.progress.partialRevision) == Array(1 ... due.count))
        #expect(due.first?.frame == 31, "22 frames (704 ms) after onset at frame 10")
        #expect(zip(due, due.dropFirst()).allSatisfy { $1.frame - $0.frame == 22 })
        #expect(due.count == 5)
    }

    @Test func speechContinuingCarriesTheUtteranceSoFar() throws {
        let script = Script().add(20, 0.0).add(20, 0.9).add(5, 0.0)
        var detector = EndpointDetector()
        let result = run(script, detector: &detector, keepProgress: true)
        let last = try #require(result.progress.last)
        #expect(last.frame == 44)
        #expect(last.progress.audio.count == (10 + 25) * 512, "pre-roll + 25 frames")
        #expect(abs(last.progress.trailingSilence - 5 * 0.032) < 1e-9)
        #expect(approx(last.progress.startTime, 10 * 0.032))
        #expect(detector.isInSpeech)
        #expect(detector.currentUtteranceAudio.count == last.progress.audio.count)
    }

    @Test func adoptedUtteranceContinuesAndIsReturned() throws {
        var detector = EndpointDetector()
        detector.adoptUtterance(samples: [Float](repeating: 0.5, count: 16_000), startTime: 5.0, speechStartTime: 5.32)
        #expect(detector.isInSpeech)
        var event: EndpointEvent?
        for index in 0 ..< 30 {
            let frame = AudioFrame(samples: [Float](repeating: 0, count: 512), timestamp: 6.0 + Double(index) * 0.032, assistantWasSpeaking: false)
            if let next = detector.process(probability: 0, frame: frame), case .speechEnded = next {
                event = next
                break
            }
        }
        guard case let .speechEnded(utterance) = try #require(event) else { return }
        #expect(approx(utterance.startTime, 5.0))
        #expect(approx(utterance.speechStartTime, 5.32))
        #expect(abs(utterance.speechEndTime - 6.0) < 1e-9)
        #expect(utterance.samples.count == 16_000 + 2_400)
        #expect(utterance.startedDuringAssistantSpeech)
    }

    @Test func cancelUtteranceDropsItWithoutAnEvent() {
        let script = Script().add(10, 0.0).add(10, 0.9)
        var detector = EndpointDetector()
        _ = run(script, detector: &detector)
        #expect(detector.isInSpeech)
        detector.cancelUtterance()
        #expect(!detector.isInSpeech)
        #expect(detector.currentUtteranceAudio.isEmpty)
        let silence = Script().add(40, 0.0)
        #expect(run(silence, detector: &detector).ends.isEmpty)
    }

    @Test func captureGapClearsThePreRoll() throws {
        var detector = EndpointDetector()
        for index in 0 ..< 20 {
            _ = detector.process(probability: 0, frame: AudioFrame(
                samples: [Float](repeating: 1, count: 512), timestamp: Double(index) * 0.032, assistantWasSpeaking: false
            ))
        }
        // Two seconds later (engine restart), speech begins.
        var utteranceStart: TimeInterval?
        for index in 0 ..< 10 {
            let frame = AudioFrame(samples: [Float](repeating: 2, count: 512), timestamp: 3.0 + Double(index) * 0.032, assistantWasSpeaking: false)
            if case let .speechStarted(onset) = detector.process(probability: 0.9, frame: frame) {
                utteranceStart = onset.utteranceStartTime
            }
        }
        #expect(approx(utteranceStart, 3.0), "no pre-roll across the gap")
        #expect(detector.currentUtteranceAudio.allSatisfy { $0 == 2 })
    }

    @Test func resetClearsPreRollAndTimers() throws {
        let script = Script().add(200, 0.0)
        var detector = EndpointDetector()
        _ = run(script, detector: &detector)
        detector.reset()
        let next = Script().add(200, 0.0)
        #expect(run(next, detector: &detector).timeouts.isEmpty, "timer restarted: 200 frames < 250")
    }
}
