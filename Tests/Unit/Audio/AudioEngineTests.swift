@testable import Audio
import Core
import Foundation
import Synchronization
import Testing

/// Session double: records calls and lets tests post system events.
private final class FakeSession: AudioSessionManaging {
    private let broadcaster = AsyncBroadcaster<AudioSessionEvent>(bufferingPolicy: .unbounded)
    private let state = Mutex((configured: 0, activated: 0, deactivated: 0, active: false))

    func configure() throws { state.withLock { $0.configured += 1 } }

    func activate() throws {
        state.withLock {
            $0.activated += 1
            $0.active = true
        }
    }

    func deactivate() {
        state.withLock {
            $0.deactivated += 1
            $0.active = false
        }
    }

    func events() -> AsyncStream<AudioSessionEvent> { broadcaster.subscribe() }
    var currentRoute: AudioRoute { AudioRoute(output: .builtInSpeaker, input: .builtInMic) }
    var isActive: Bool { state.withLock { $0.active } }
    var subscriberCount: Int { broadcaster.subscriberCount }
    var calls: (configured: Int, activated: Int, deactivated: Int) {
        state.withLock { ($0.configured, $0.activated, $0.deactivated) }
    }

    func post(_ event: AudioSessionEvent) { broadcaster.yield(event) }
}

/// Polls until `condition` holds (engine work hops through a private queue).
private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// The live engine needs audio hardware and microphone permission, which CI does not have.
/// These tests cover everything that does not start `AVAudioEngine`.
@Suite struct AudioEngineTests {
    @Test func defaultsFollowTheAudioContract() {
        let configuration = AudioEngineConfiguration()
        #expect(configuration.frameSamples == 512)
        #expect(configuration.duckedVolume == 0.25)
        #expect(configuration.echoTail == 0.25)
        #expect(configuration.maxBufferedFrames == 96)
        #expect(configuration.playbackSampleRate == 24_000)
        #if os(iOS)
        #expect(configuration.voiceProcessing)
        #else
        #expect(!configuration.voiceProcessing)
        #endif
    }

    @Test func idleEngineStateChangesDoNotTouchHardware() async throws {
        let session = FakeSession()
        let engine = AudioEngine(session: session, logger: nil)
        #expect(engine.status == AudioEngineStatus())

        await engine.setDucked(true)
        #expect(engine.status.isDucked)
        await engine.stopPlayback()
        #expect(!engine.status.isDucked, "stopping playback also restores full volume")
        await engine.setDucked(false)
        await engine.stopCapture()
        #expect(!engine.status.isCapturing)
        #expect(session.calls.activated == 0)

        try await engine.play(SynthesizedAudio(samples: [], sampleRate: 24_000))
        await #expect(throws: AudioEngineError.invalidAudio) {
            try await engine.play(SynthesizedAudio(samples: [0.1, 0.2], sampleRate: 0))
        }
    }

    @Test func playFromACancelledTaskThrowsCancellationErrorWithoutStartingAudio() async {
        let session = FakeSession()
        let engine = AudioEngine(session: session, logger: nil)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let task = Task {
            // Parks until cancelled, so `play` is always called from a cancelled task.
            for await _ in gate {}
            try await engine.play(SynthesizedAudio(samples: [0.1, 0.2], sampleRate: 24_000))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        open.finish()
        #expect(session.calls.activated == 0)
    }

    @Test func sessionEventsReachTheEngine() async {
        let session = FakeSession()
        let engine = AudioEngine(session: session, logger: nil)
        #expect(await eventually { session.subscriberCount == 1 })

        session.post(.interruptionBegan(reason: .otherAudio))
        #expect(await eventually { engine.status.isInterrupted })
        session.post(.interruptionEnded(shouldResume: false))
        #expect(await eventually { !engine.status.isInterrupted })

        let speaker = AudioRoute(output: .builtInSpeaker, input: .builtInMic)
        session.post(.routeChanged(reason: .override, previous: nil, current: speaker))
        #expect(await eventually { engine.status.route == speaker })
        #expect(session.calls.activated == 0, "nothing was capturing or playing, so nothing restarts")
    }
}

@Suite struct AsyncBroadcasterTests {
    @Test func everySubscriberReceivesEveryValue() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingPolicy: .unbounded)
        let a = broadcaster.subscribe()
        let b = broadcaster.subscribe()
        #expect(broadcaster.subscriberCount == 2)
        for value in 1 ... 3 { broadcaster.yield(value) }
        broadcaster.finish()

        var receivedA: [Int] = []
        for await value in a { receivedA.append(value) }
        var receivedB: [Int] = []
        for await value in b { receivedB.append(value) }
        #expect(receivedA == [1, 2, 3])
        #expect(receivedB == [1, 2, 3])
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test func latestOnlyPolicyKeepsTheNewestValue() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingPolicy: .bufferingNewest(1))
        let stream = broadcaster.subscribe()
        for value in 1 ... 5 { broadcaster.yield(value) }
        broadcaster.finish()
        var received: [Int] = []
        for await value in stream { received.append(value) }
        #expect(received == [5])
    }

    @Test func subscribingAfterFinishYieldsAFinishedStream() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingPolicy: .unbounded)
        broadcaster.finish()
        var count = 0
        for await _ in broadcaster.subscribe() { count += 1 }
        #expect(count == 0)
    }

    @Test func cancelledSubscribersAreDropped() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingPolicy: .unbounded)
        let task = Task {
            for await _ in broadcaster.subscribe() {}
        }
        #expect(await eventually { broadcaster.subscriberCount == 1 })
        task.cancel()
        #expect(await eventually { broadcaster.subscriberCount == 0 })
    }
}

@Suite struct AudioSessionManagerTests {
    @Test func sessionEventsFanOutToEverySubscriber() async {
        let manager = AudioSessionManager(logger: nil)
        let engineSide = manager.events()
        let agentSide = manager.events()
        manager.post(.interruptionBegan(reason: .otherAudio))
        manager.post(.interruptionEnded(shouldResume: true))

        var engineEvents: [AudioSessionEvent] = []
        for await event in engineSide {
            engineEvents.append(event)
            if engineEvents.count == 2 { break }
        }
        var agentEvents: [AudioSessionEvent] = []
        for await event in agentSide {
            agentEvents.append(event)
            if agentEvents.count == 2 { break }
        }
        let expected: [AudioSessionEvent] = [.interruptionBegan(reason: .otherAudio), .interruptionEnded(shouldResume: true)]
        #expect(engineEvents == expected)
        #expect(agentEvents == expected)
    }

    #if !os(iOS)
    @Test func macOSFallbackIsANoOpThatTracksActivation() throws {
        let manager = AudioSessionManager(logger: nil)
        try manager.configure()
        #expect(!manager.isActive)
        try manager.activate()
        #expect(manager.isActive)
        manager.deactivate()
        #expect(!manager.isActive)
        #expect(manager.currentRoute == .unknown)
    }
    #endif
}
