@testable import Audio
import Foundation
import Testing

@Suite struct LevelMeterTests {
    @Test func rmsOfASineIsItsAmplitudeOverRootTwo() {
        let tone = Signals.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.1)
        #expect(abs(LevelMeter.rms(tone) - 0.5 / Float(2).squareRoot()) < 1e-3)
        #expect(LevelMeter.rms(Signals.silence(0.1)) == 0)
        #expect(LevelMeter.rms([]) == 0)
    }

    @Test func normalizedLevelIsLinearInDecibelsAndClamped() {
        func level(_ decibels: Float) -> Float {
            LevelMeter.normalizedLevel(rms: pow(10, decibels / 20), floorDecibels: -60, ceilingDecibels: -12)
        }
        #expect(LevelMeter.normalizedLevel(rms: 0, floorDecibels: -60, ceilingDecibels: -12) == 0)
        #expect(level(-70) == 0)
        #expect(abs(level(-36) - 0.5) < 1e-4)
        #expect(level(-12) > 0.999)
        #expect(level(0) == 1)
    }

    @Test func attackIsFastAndReleaseIsSlow() {
        var meter = LevelMeter()
        // -15 dBFS RMS → target ≈ 0.94. 64 ms with τ_attack = 30 ms reaches ≈ 88 % of it.
        let rise = meter.process(Signals.sine(frequency: 440, amplitude: 0.25, seconds: 0.064))
        #expect(rise > 0.75)
        // 64 ms of silence with τ_release = 250 ms only drops it to ≈ 77 %.
        let fall = meter.process(Signals.silence(0.064))
        #expect(fall < rise && fall > 0.55)
        for _ in 0 ..< 30 { meter.process(Signals.silence(0.064)) }
        #expect(meter.level < 0.01)
        meter.reset()
        #expect(meter.level == 0)
    }

    @Test func playbackEnvelopeReportsLevelByPosition() {
        // 0.5 s silence then 0.5 s at -23 dBFS RMS (→ (−23 + 60) / 48 ≈ 0.771).
        let signal = Signals.concat(Signals.silence(0.5), Signals.sine(frequency: 440, amplitude: 0.1, seconds: 0.5))
        let envelope = PlaybackEnvelope(samples: signal, sampleRate: 16_000)

        #expect(abs(envelope.duration - 1) < 1e-9)
        #expect(envelope.level(at: 0.25) == 0)
        #expect(abs(envelope.level(at: 0.75) - 0.771) < 0.02)
        #expect(envelope.level(at: -0.1) == 0)
        #expect(envelope.level(at: 1.5) == 0)
        #expect(envelope.level(atSample: 12_000) == envelope.level(at: 0.75))
    }
}

@Suite struct PlaybackActivityTrackerTests {
    @Test func audibleFromScheduleUntilTheEchoTailEnds() {
        var tracker = PlaybackActivityTracker(echoTail: 0.25)
        #expect(!tracker.isAssistantAudible(at: 10))

        tracker.bufferScheduled(at: 10)
        #expect(tracker.isPlaying)
        #expect(tracker.isAssistantAudible(at: 10.5))
        #expect(!tracker.isAssistantAudible(at: 9.9), "audio captured before playback began is not echo")

        tracker.bufferFinished(at: 12)
        #expect(!tracker.isPlaying)
        #expect(tracker.isAssistantAudible(at: 12.2), "inside the 250 ms echo tail")
        #expect(!tracker.isAssistantAudible(at: 12.26), "after the echo tail")
    }

    @Test func capturedIntervalsStraddlingTheEdgesAreFlagged() {
        var tracker = PlaybackActivityTracker(echoTail: 0.25)
        tracker.bufferScheduled(at: 10)
        tracker.bufferFinished(at: 12)
        #expect(tracker.isAssistantAudible(from: 9.95, to: 10.05))
        #expect(tracker.isAssistantAudible(from: 12.2, to: 12.35))
        #expect(!tracker.isAssistantAudible(from: 12.26, to: 12.4))
        #expect(!tracker.isAssistantAudible(from: 9.8, to: 9.9))
    }

    @Test func queuedBuffersKeepOneEpisodeOpen() {
        var tracker = PlaybackActivityTracker(echoTail: 0.25)
        tracker.bufferScheduled(at: 1)
        tracker.bufferScheduled(at: 1.5)
        tracker.bufferFinished(at: 3)
        #expect(tracker.isPlaying)
        #expect(tracker.isAssistantAudible(at: 3.5))
        tracker.bufferFinished(at: 4)
        #expect(tracker.outstandingBuffers == 0)
        #expect(tracker.isAssistantAudible(at: 4.2))
        #expect(!tracker.isAssistantAudible(at: 4.3))
    }

    @Test func stopClosesTheEpisodeImmediately() {
        var tracker = PlaybackActivityTracker(echoTail: 0.25)
        tracker.bufferScheduled(at: 1)
        tracker.bufferScheduled(at: 1.2)
        tracker.bufferScheduled(at: 1.4)
        tracker.allStopped(at: 2)
        #expect(tracker.outstandingBuffers == 0)
        #expect(tracker.isAssistantAudible(at: 2.2))
        #expect(!tracker.isAssistantAudible(at: 2.3))
        tracker.bufferFinished(at: 2.5) // late completion of a stopped buffer: ignored
        #expect(!tracker.isAssistantAudible(at: 2.6))
    }

    @Test func anEpisodeStartingInsideTheTailIsMergedWithThePreviousOne() {
        var tracker = PlaybackActivityTracker(echoTail: 0.25)
        tracker.bufferScheduled(at: 10)
        tracker.bufferFinished(at: 12)
        tracker.bufferScheduled(at: 12.1) // next TTS chunk within the tail
        tracker.bufferFinished(at: 13)
        #expect(tracker.isAssistantAudible(at: 12.05), "gap between chunks is still echo-risky")
        #expect(tracker.isAssistantAudible(at: 11))
        #expect(!tracker.isAssistantAudible(at: 13.3))
    }
}
