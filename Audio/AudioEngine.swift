import AVFAudio
import Core
import Foundation
import Synchronization
import Telemetry
#if canImport(UIKit)
import UIKit
#endif

public enum AudioEngineError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    /// Ask through `PermissionProviding` first; the audio layer never shows the system prompt.
    case microphonePermissionUndetermined
    case noInputAvailable
    case engineStartFailed(code: Int)
    /// A scheduled buffer never reported completion (engine stopped silently).
    case playbackStalled
    case invalidAudio
}

public struct AudioEngineConfiguration: Sendable, Equatable {
    /// Samples per `AudioFrame` (512 at 16 kHz = 32 ms, the Silero window).
    public var frameSamples = 512
    /// Voice processing (hardware AEC, AGC, noise suppression) on the input node. iOS only by
    /// default: on the Mac it reshapes the device aggregate and is not needed for development.
    #if os(iOS)
    public var voiceProcessing = true
    #else
    public var voiceProcessing = false
    #endif
    /// Frames are flagged `assistantWasSpeaking` for this long after playback ends.
    public var echoTail: TimeInterval = 0.25
    /// Player volume while a possible barge-in is verified (−12 dB).
    public var duckedVolume: Float = 0.25
    /// Bound of the frame stream (`.bufferingNewest`): 96 × 32 ms ≈ 3.1 s (≈ 196 KB). A consumer
    /// that stalls longer loses the *oldest* frames — stale audio is useless for a real-time
    /// conversation and memory stays bounded. Drops are counted (`audio_frames_dropped`) and
    /// visible as a jump in frame timestamps.
    public var maxBufferedFrames = 96
    /// Requested input-tap buffer. AVAudioNode taps support 100–400 ms; 100 ms bounds the
    /// added capture latency.
    public var tapBufferDuration: TimeInterval = 0.1
    /// Player connection format; `SynthesizedAudio` at another rate is resampled first.
    public var playbackSampleRate: Double = 24_000
    public var levelUpdateInterval: TimeInterval = 1.0 / 30
    /// Engine and session stay up this long after the last playback when not capturing, so
    /// back-to-back TTS chunks do not pay the voice-processing start-up cost.
    public var idleShutdownDelay: TimeInterval = 3
    /// A buffer that has not completed this long after its expected end is declared stalled.
    public var playbackWatchdogSlack: TimeInterval = 3
    /// Capture gaps longer than this move the frame clock forward (engine restarts).
    public var clockResyncThreshold: TimeInterval = 0.12
    public var maxRestartAttempts = 3

    public init() {}
}

/// Diagnostics snapshot (content-free).
public struct AudioEngineStatus: Sendable, Equatable {
    public var isRunning = false
    public var isCapturing = false
    public var isPlaying = false
    public var isDucked = false
    public var isInterrupted = false
    public var voiceProcessingActive = false
    public var droppedFrames = 0
    public var route: AudioRoute = .unknown
}

/// One `AVAudioEngine` for both directions, so voice processing can cancel the assistant's own
/// voice: TTS plays through an `AVAudioPlayerNode` in the same engine whose input node has
/// voice processing enabled (see `AudioSessionManager` for the mode decision).
///
/// Capture: input tap at the hardware format → `StreamingResampler` (16 kHz mono Float32) →
/// `AudioFrameAssembler` (exact 512-sample frames, monotonic timestamps, `assistantWasSpeaking`
/// from `PlaybackActivityTracker` incl. a 250 ms echo tail) → `AsyncStream` with
/// `.bufferingNewest(maxBufferedFrames)`. The frame stream survives interruptions and route
/// changes: frames pause and resume automatically (timestamps jump over the gap). It finishes
/// only on `stopCapture()`, a new `startCapture()`, or when the engine cannot be restarted.
///
/// Playback: `play` schedules one buffer and awaits `.dataPlayedBack`; calls may overlap to
/// queue chunks gaplessly. `stopPlayback()` stops the player node, which silences output at the
/// next render cycle (within one ~20 ms IO buffer), and every pending `play` throws
/// `CancellationError`. Cancelling a task awaiting `play` does the same. Interruptions, route
/// changes that remove a private route, configuration changes and media-service resets also
/// stop playback.
///
/// ## Concurrency (`@unchecked Sendable`)
/// `AVAudioEngine`, `AVAudioPlayerNode` and `AVAudioPCMBuffer` are not `Sendable`. They are
/// created, mutated and read only on `queue` (a private serial queue); every public method hops
/// onto it. The input tap runs on an AVFoundation thread (not the real-time render thread) and
/// only touches `capture` and `playbackActivity`, each behind a `Mutex`; it does one small
/// allocation per 32 ms frame (the frame's own array). AVFoundation callbacks (completion
/// handlers, notifications) never touch engine objects directly — they hop onto `queue`.
public final class AudioEngine: AudioCapturing, AudioPlaying, @unchecked Sendable {
    public let configuration: AudioEngineConfiguration
    private let session: any AudioSessionManaging
    private let logger: PrivacySafeLogger?
    private let queue = DispatchQueue(label: "app.voiceagent.audio-engine", qos: .userInteractive)

    // MARK: queue-confined

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var voiceProcessingActive = false
    private var tapInstalled = false
    private var wantsCapture = false
    private var interrupted = false
    private var ducked = false
    private var playbackQueue: [PlaybackItem] = []
    private var configurationObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var levelTimer: DispatchSourceTimer?
    private var idleShutdown: DispatchWorkItem?
    private var sessionTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var currentRoute: AudioRoute = .unknown

    // MARK: shared with the input-tap thread

    private let capture: CapturePipeline
    private let playbackActivity: Mutex<PlaybackActivityTracker>
    private let statusSnapshot = Mutex(AudioEngineStatus())
    private let levels = AsyncBroadcaster<AudioLevels>(bufferingPolicy: .bufferingNewest(1))

    public init(
        configuration: AudioEngineConfiguration = .init(),
        session: any AudioSessionManaging = AudioSessionManager.shared,
        logger: PrivacySafeLogger? = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.logger = logger
        capture = CapturePipeline(frameSamples: configuration.frameSamples)
        playbackActivity = Mutex(PlaybackActivityTracker(echoTail: configuration.echoTail))
        observeSessionEvents()
        observeForeground()
    }

    deinit {
        sessionTask?.cancel()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
        levelTimer?.cancel()
        idleShutdown?.cancel()
        engine?.stop()
        capture.finish().continuation?.finish()
        for item in playbackQueue { item.continuation.resume(throwing: CancellationError()) }
        levels.finish()
    }

    // MARK: - Public API

    /// Input/output levels (0…1) at ~30 Hz while the engine runs; latest value only.
    public func levelUpdates() -> AsyncStream<AudioLevels> {
        levels.subscribe()
    }

    public var status: AudioEngineStatus {
        statusSnapshot.withLock { $0 }
    }

    public func startCapture() async throws -> AsyncStream<AudioFrame> {
        try Self.checkRecordPermission()
        return try await onQueue {
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioFrame.self,
                bufferingPolicy: .bufferingNewest(self.configuration.maxBufferedFrames)
            )
            self.capture.begin(continuation)?.finish()
            self.wantsCapture = true
            self.interrupted = false
            self.cancelIdleShutdown()
            do {
                // Fresh tap = fresh resampler state for the new stream.
                self.removeTap()
                try self.startEngineIfNeeded()
            } catch {
                self.wantsCapture = false
                self.finishCaptureStream()
                self.scheduleIdleShutdownIfNeeded()
                self.publishStatus()
                throw error
            }
            self.publishStatus()
            return stream
        }
    }

    public func stopCapture() async {
        await onQueue {
            self.wantsCapture = false
            self.removeTap()
            self.finishCaptureStream()
            if self.playbackQueue.isEmpty {
                self.stopEngine(deactivateSession: true)
            }
            self.publishStatus()
        }
    }

    public func play(_ audio: SynthesizedAudio) async throws {
        try Task.checkCancellation()
        guard !audio.samples.isEmpty else { return }
        guard audio.sampleRate > 0 else { throw AudioEngineError.invalidAudio }
        let ticket = PlaybackTicket()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { self.schedule(audio, ticket: ticket, continuation: continuation) }
            }
        } onCancel: {
            ticket.cancelled.store(true, ordering: .relaxed)
            queue.async { self.failAllPlayback(CancellationError()) }
        }
    }

    public func stopPlayback() async {
        await onQueue {
            self.failAllPlayback(CancellationError())
        }
    }

    public func setDucked(_ ducked: Bool) async {
        await onQueue {
            self.ducked = ducked
            self.player?.volume = ducked ? self.configuration.duckedVolume : 1
            self.publishStatus()
        }
    }

    // MARK: - Capture path (input-tap thread)

    private func handleInput(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let start = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : Self.hostSeconds()
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let speaking = playbackActivity.withLock { $0.isAssistantAudible(from: start, to: start + duration) }
        let (frames, continuation) = capture.process(
            buffer,
            hostTime: start,
            assistantWasSpeaking: speaking,
            resyncThreshold: configuration.clockResyncThreshold
        )
        guard let continuation, !frames.isEmpty else { return }
        var dropped = 0
        for frame in frames {
            if case .dropped = continuation.yield(frame) { dropped += 1 }
        }
        if dropped > 0 {
            let total = capture.recordDropped(dropped)
            if total / 50 != (total - dropped) / 50 {
                logger?.log(.counter(name: "audio_frames_dropped", value: total))
            }
        }
    }

    // MARK: - Playback (queue)

    private func schedule(_ audio: SynthesizedAudio, ticket: PlaybackTicket, continuation: CheckedContinuation<Void, any Error>) {
        guard !ticket.cancelled.load(ordering: .relaxed), !interrupted else {
            continuation.resume(throwing: CancellationError())
            return
        }
        do {
            try startEngineIfNeeded()
            guard let engine, let player, let format = playerFormat else {
                throw AudioEngineError.engineStartFailed(code: -1)
            }
            let samples = audio.sampleRate == format.sampleRate
                ? audio.samples
                : try StreamingResampler.resample(audio.samples, from: audio.sampleRate, to: format.sampleRate)
            guard let buffer = StreamingResampler.makeBuffer(format: format, channels: [samples]) else {
                throw AudioEngineError.invalidAudio
            }
            let now = Self.hostSeconds()
            var item = PlaybackItem(
                ticket: ticket,
                continuation: continuation,
                envelope: PlaybackEnvelope(samples: samples, sampleRate: format.sampleRate),
                duration: Double(samples.count) / format.sampleRate,
                scheduledAt: now
            )
            if playbackQueue.isEmpty { item.startedAt = now + engine.outputNode.presentationLatency }
            playbackQueue.append(item)
            playbackActivity.withLock { $0.bufferScheduled(at: now) }
            cancelIdleShutdown()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.finishPlayback(ticket) }
            }
            player.volume = ducked ? configuration.duckedVolume : 1
            if engine.isRunning, !player.isPlaying { player.play() }
            startLevelTimerIfNeeded()
            publishStatus()
        } catch {
            continuation.resume(throwing: error)
            scheduleIdleShutdownIfNeeded()
        }
    }

    private func finishPlayback(_ ticket: PlaybackTicket) {
        guard let index = playbackQueue.firstIndex(where: { $0.ticket === ticket }) else { return }
        let item = playbackQueue.remove(at: index)
        let now = Self.hostSeconds()
        playbackActivity.withLock { $0.bufferFinished(at: now) }
        if index == 0, !playbackQueue.isEmpty, playbackQueue[0].startedAt == nil {
            playbackQueue[0].startedAt = now
        }
        if playbackQueue.isEmpty { scheduleIdleShutdownIfNeeded() }
        publishStatus()
        item.continuation.resume()
    }

    /// Stops the player (silent at the next render cycle) and fails every pending `play`.
    private func failAllPlayback(_ error: any Error) {
        let items = playbackQueue
        playbackQueue.removeAll()
        player?.stop()
        if !items.isEmpty {
            playbackActivity.withLock { $0.allStopped(at: Self.hostSeconds()) }
        }
        if ducked {
            ducked = false
            player?.volume = 1
        }
        for item in items { item.continuation.resume(throwing: error) }
        if !items.isEmpty { scheduleIdleShutdownIfNeeded() }
        publishStatus()
    }

    // MARK: - Engine lifecycle (queue)

    private func startEngineIfNeeded() throws {
        if wantsCapture, configuration.voiceProcessing, !voiceProcessingActive, engine != nil {
            // Built for playback-only without voice processing (e.g. no microphone permission
            // yet): rebuild so capture gets echo cancellation.
            teardownGraph(invalidated: false)
        }
        if let engine, engine.isRunning, !wantsCapture || tapInstalled { return }
        try session.configure()
        if !session.isActive { try session.activate() }
        try buildGraphIfNeeded()
        guard let engine else { throw AudioEngineError.engineStartFailed(code: -1) }
        if wantsCapture, !tapInstalled { try installTap() }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                logger?.log(.error(domain: "audio_engine", code: "start_failed"))
                throw AudioEngineError.engineStartFailed(code: (error as NSError).code)
            }
        }
        if let player, engine.isRunning, !player.isPlaying { player.play() }
        restartAttempts = 0
        currentRoute = session.currentRoute
        logger?.log(.audioRoute(kind: SafeLabel(currentRoute.output)))
        startLevelTimerIfNeeded()
        publishStatus()
    }

    private func buildGraphIfNeeded() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var voiceProcessing = false
        if configuration.voiceProcessing {
            // Must happen while the engine is stopped and before any connection is made.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessing = true
            } catch {
                logger?.log(.error(domain: "audio_engine", code: "voice_processing_unavailable"))
            }
        }
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: configuration.playbackSampleRate, channels: 1) else {
            throw AudioEngineError.invalidAudio
        }
        // The player is connected with the TTS format; the main mixer converts to the hardware.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Posted on an internal queue; never touch (or release) the engine here.
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
        self.engine = engine
        self.player = player
        playerFormat = format
        voiceProcessingActive = voiceProcessing
    }

    /// Drops the graph. After a media-services reset the old objects are dead: do not call them.
    private func teardownGraph(invalidated: Bool) {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if !invalidated {
            if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
            player?.stop()
            engine?.stop()
        }
        tapInstalled = false
        engine = nil
        player = nil
        playerFormat = nil
        voiceProcessingActive = false
        capture.setResampler(nil)
    }

    private func installTap() throws {
        guard let engine else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }
        capture.setResampler(try StreamingResampler(inputFormat: format, outputSampleRate: AudioFrame.sampleRate))
        if tapInstalled { input.removeTap(onBus: 0) }
        let bufferSize = AVAudioFrameCount(max(256, (format.sampleRate * configuration.tapBufferDuration).rounded()))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.handleInput(buffer, time: time)
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func finishCaptureStream() {
        let (continuation, dropped) = capture.finish()
        continuation?.finish()
        if dropped > 0 {
            logger?.log(.counter(name: "audio_frames_dropped", value: dropped))
        }
    }

    private func stopEngine(deactivateSession: Bool) {
        cancelIdleShutdown()
        stopLevelTimer()
        removeTap()
        player?.stop()
        engine?.stop()
        if deactivateSession, session.isActive { session.deactivate() }
        levels.yield(.silent)
        publishStatus()
    }

    private func restart() {
        guard !interrupted, wantsCapture || !playbackQueue.isEmpty else { return }
        removeTap()
        if restartAttempts >= 1 {
            // A plain restart already failed: rebuild the whole graph (voice processing can get
            // stuck after interruptions).
            teardownGraph(invalidated: false)
        }
        do {
            try startEngineIfNeeded()
        } catch {
            restartAttempts += 1
            guard restartAttempts <= configuration.maxRestartAttempts else {
                logger?.log(.error(domain: "audio_engine", code: "restart_failed"))
                restartAttempts = 0
                wantsCapture = false
                finishCaptureStream()
                failAllPlayback(error)
                stopEngine(deactivateSession: true)
                return
            }
            let delay = 0.25 * Double(1 << (restartAttempts - 1))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restart()
            }
        }
    }

    private func handleConfigurationChange() {
        // The engine stopped itself: the hardware format (rate/channels) changed.
        logger?.log(.counter(name: "audio_engine_configuration_change", value: 1))
        failAllPlayback(CancellationError())
        if wantsCapture { restart() }
    }

    // MARK: - Session events (queue)

    private func observeSessionEvents() {
        let stream = session.events()
        sessionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.queue.async { self.handleSessionEvent(event) }
            }
        }
    }

    private func handleSessionEvent(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            // The system has already stopped the engine. Frames pause; the stream stays open.
            interrupted = true
            failAllPlayback(CancellationError())
            removeTap()
        case let .interruptionEnded(shouldResume):
            interrupted = false
            // Without `shouldResume` wait for the user (a new `startCapture()` restarts).
            if shouldResume, wantsCapture {
                restartAttempts = 0
                restart()
            }
        case let .routeChanged(reason, previous, current):
            currentRoute = current
            let response = AudioRouter.response(to: reason, previous: previous, current: current)
            if response.contains(.stopPlayback) {
                failAllPlayback(CancellationError())
            }
            if response.contains(.reapplySessionConfiguration) {
                try? session.configure()
            }
            if response.contains(.verifyEngineRunning), engine?.isRunning != true {
                restart()
            }
        case .mediaServicesWereLost:
            failAllPlayback(CancellationError())
            teardownGraph(invalidated: true)
        case .mediaServicesWereReset:
            failAllPlayback(CancellationError())
            teardownGraph(invalidated: true)
            interrupted = false
            restartAttempts = 0
            if wantsCapture { restart() }
        }
        publishStatus()
    }

    private func observeForeground() {
        #if canImport(UIKit) && !os(watchOS)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Without the `audio` background mode iOS stops the engine in the background;
            // bring it back if a session is still active.
            self.queue.async {
                if self.wantsCapture, !self.interrupted, self.engine?.isRunning != true {
                    self.restartAttempts = 0
                    self.restart()
                }
            }
        }
        #endif
    }

    // MARK: - Levels, watchdog, idle shutdown (queue)

    private func startLevelTimerIfNeeded() {
        guard levelTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: configuration.levelUpdateInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.levelTick() }
        timer.resume()
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    private func levelTick() {
        let now = Self.hostSeconds()
        if let head = playbackQueue.first,
           now > (head.startedAt ?? head.scheduledAt) + head.duration + configuration.playbackWatchdogSlack {
            logger?.log(.error(domain: "audio_engine", code: "playback_stalled"))
            failAllPlayback(AudioEngineError.playbackStalled)
        }
        let input: Float = wantsCapture ? capture.inputLevel : 0
        var output: Float = 0
        if let head = playbackQueue.first, let startedAt = head.startedAt {
            output = head.envelope.level(at: now - startedAt)
            if ducked {
                let meter = LevelMeter.Configuration()
                let shift = LevelMeter.decibels(rms: configuration.duckedVolume) / (meter.ceilingDecibels - meter.floorDecibels)
                output = max(0, output + shift)
            }
        }
        levels.yield(AudioLevels(input: input, output: output))
        if !wantsCapture, playbackQueue.isEmpty {
            stopLevelTimer()
            levels.yield(.silent)
        }
    }

    private func scheduleIdleShutdownIfNeeded() {
        guard !wantsCapture, playbackQueue.isEmpty, engine?.isRunning == true else { return }
        idleShutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.wantsCapture, self.playbackQueue.isEmpty else { return }
            self.stopEngine(deactivateSession: true)
        }
        idleShutdown = work
        queue.asyncAfter(deadline: .now() + configuration.idleShutdownDelay, execute: work)
    }

    private func cancelIdleShutdown() {
        idleShutdown?.cancel()
        idleShutdown = nil
    }

    private func publishStatus() {
        let snapshot = AudioEngineStatus(
            isRunning: engine?.isRunning ?? false,
            isCapturing: wantsCapture,
            isPlaying: !playbackQueue.isEmpty,
            isDucked: ducked,
            isInterrupted: interrupted,
            voiceProcessingActive: voiceProcessingActive,
            droppedFrames: capture.droppedFrames,
            route: currentRoute
        )
        statusSnapshot.withLock { $0 = snapshot }
    }

    // MARK: - Helpers

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func onQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    private static func checkRecordPermission() throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return
        case .undetermined: throw AudioEngineError.microphonePermissionUndetermined
        case .denied: throw AudioEngineError.microphonePermissionDenied
        @unknown default: throw AudioEngineError.microphonePermissionDenied
        }
    }

    /// Host clock in seconds (same clock as `AVAudioTime.hostTime`).
    static func hostSeconds() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
}

/// Capture-path state shared by the engine queue (start/stop/reconfigure) and the input-tap
/// thread (conversion + framing).
///
/// `@unchecked Sendable`: every field is read and written only while holding `lock`, and the
/// non-`Sendable` pieces (`StreamingResampler` and the tap's `AVAudioPCMBuffer`) never escape a
/// locked region. The lock is uncontended in practice (the queue touches it only on
/// start/stop) and the tap thread is AVFoundation's delivery thread, not the real-time render
/// thread, so a short critical section there is safe.
private final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let frameSamples: Int
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var resampler: StreamingResampler?
    private var assembler: AudioFrameAssembler
    private var meter = LevelMeter()
    /// Host time (s) of the first captured sample of the current stream.
    private var startHostTime: TimeInterval?
    private var dropped = 0
    private var conversionErrors = 0

    init(frameSamples: Int) {
        self.frameSamples = frameSamples
        assembler = AudioFrameAssembler(frameSamples: frameSamples)
    }

    /// Starts a new stream (fresh frame clock); returns the stream it replaces.
    func begin(_ continuation: AsyncStream<AudioFrame>.Continuation) -> AsyncStream<AudioFrame>.Continuation? {
        lock.withLock {
            let previous = self.continuation
            self.continuation = continuation
            assembler = AudioFrameAssembler(frameSamples: frameSamples)
            meter.reset()
            startHostTime = nil
            dropped = 0
            return previous
        }
    }

    /// Ends the stream; returns its continuation (to finish outside the lock) and drop count.
    func finish() -> (continuation: AsyncStream<AudioFrame>.Continuation?, dropped: Int) {
        lock.withLock {
            let result = (continuation, dropped)
            continuation = nil
            resampler = nil
            startHostTime = nil
            dropped = 0
            meter.reset()
            return result
        }
    }

    /// Installs the converter for the (possibly new) hardware input format.
    func setResampler(_ resampler: StreamingResampler?) {
        lock.withLock { self.resampler = resampler }
    }

    var inputLevel: Float {
        lock.withLock { meter.level }
    }

    var droppedFrames: Int {
        lock.withLock { dropped }
    }

    func recordDropped(_ count: Int) -> Int {
        lock.withLock {
            dropped += count
            return dropped
        }
    }

    /// Converts one tap buffer and returns the completed frames plus the continuation to
    /// yield them to (yielding happens outside the lock).
    func process(
        _ buffer: AVAudioPCMBuffer,
        hostTime start: TimeInterval,
        assistantWasSpeaking speaking: Bool,
        resyncThreshold: TimeInterval
    ) -> (frames: [AudioFrame], continuation: AsyncStream<AudioFrame>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let resampler else { return ([], nil) }
        if let origin = startHostTime {
            // After a gap (restart, interruption) move the frame clock to wall-clock time.
            let elapsed = start - origin
            let sampleClock = assembler.nextFrameTimestamp + Double(assembler.bufferedSampleCount) / AudioFrame.sampleRate
            if elapsed - sampleClock > resyncThreshold {
                assembler.resynchronize(toElapsed: elapsed)
            }
        } else {
            startHostTime = start
        }
        var frames: [AudioFrame] = []
        do {
            try resampler.convert(buffer) { samples in
                self.assembler.append(samples, assistantWasSpeaking: speaking) { frames.append($0) }
            }
        } catch {
            conversionErrors += 1
        }
        for frame in frames { meter.process(frame.samples) }
        return (frames, continuation)
    }
}

/// Identity + cancellation flag of one `play` call (set from the task's cancellation handler).
private final class PlaybackTicket: Sendable {
    let cancelled = Atomic<Bool>(false)
}

private struct PlaybackItem {
    let ticket: PlaybackTicket
    let continuation: CheckedContinuation<Void, any Error>
    let envelope: PlaybackEnvelope
    let duration: TimeInterval
    let scheduledAt: TimeInterval
    /// Estimated host time the buffer became audible (UI levels, watchdog).
    var startedAt: TimeInterval?
}
