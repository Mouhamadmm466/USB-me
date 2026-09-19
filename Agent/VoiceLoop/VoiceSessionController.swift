import Agent
import ASR
import Audio
import Core
import Foundation
import Telemetry
import TTS

/// Glue for the real-time voice loop (PRD §6, Phases 6–7):
///
/// mic frames → VAD → `EndpointDetector` → partial Whisper (UI only) → final Whisper →
/// `AgentCoordinator.handle(.speech(...))` → `SpeechQueue` (Kokoro) playback, with
/// `EchoBargeInController` watching the microphone while the assistant speaks.
///
/// Frames are processed on the main actor (≈31 per second, each a few microseconds of logic);
/// VAD and ASR inference run in their own actors, and turn handling runs in a separate task so
/// capture never stalls while the model thinks.
///
/// The same `AudioEngine` must be both `capture` and the `SpeechQueue`'s player: hardware echo
/// cancellation only subtracts that engine's own playback.
@MainActor
public final class VoiceSessionController {
    public struct Dependencies: Sendable {
        public var capture: any AudioCapturing
        public var recognizer: any SpeechRecognizer
        public var vad: any VoiceActivityDetecting
        public var speech: SpeechQueue
        public var permissions: any PermissionProviding
        /// Contact names used to bias the final Whisper pass (never logged).
        public var biasNames: @Sendable () async -> [String]
        /// Audio-session events (interruptions, route changes). nil in tests.
        public var sessionEvents: (@Sendable () -> AsyncStream<AudioSessionEvent>)?
        /// Current route's echo risk at session start.
        public var initialEchoRisk: EchoRisk
        /// Input/output levels for the orb. nil in tests.
        public var levels: (@Sendable () -> AsyncStream<AudioLevels>)?
        public var metrics: PerformanceMetrics?

        public init(capture: any AudioCapturing, recognizer: any SpeechRecognizer, vad: any VoiceActivityDetecting,
                    speech: SpeechQueue, permissions: any PermissionProviding,
                    biasNames: @escaping @Sendable () async -> [String] = { [] },
                    sessionEvents: (@Sendable () -> AsyncStream<AudioSessionEvent>)? = nil,
                    initialEchoRisk: EchoRisk = .high,
                    levels: (@Sendable () -> AsyncStream<AudioLevels>)? = nil,
                    metrics: PerformanceMetrics? = nil) {
            self.capture = capture
            self.recognizer = recognizer
            self.vad = vad
            self.speech = speech
            self.permissions = permissions
            self.biasNames = biasNames
            self.sessionEvents = sessionEvents
            self.initialEchoRisk = initialEchoRisk
            self.levels = levels
            self.metrics = metrics
        }
    }

    public private(set) var isActive = false
    /// Re-open the microphone after an answer (Settings → Voice). Read at the end of every turn.
    public var continueListeningAfterResponse: Bool
    public private(set) var bargeInCounters = BargeInCounters()
    /// Set when the capture stream ended unexpectedly (engine could not restart).
    public private(set) var captureFailed = false

    private let coordinator: AgentCoordinator
    private let dependencies: Dependencies
    private let configuration: AgentConfiguration
    private var endpoint: EndpointDetector
    private var bargeIn: EchoBargeInController
    private var transcripts = TranscriptBuffer()
    private var captureTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var partialInFlight = false
    private var candidateInFlight = false
    private var assistantWasSpeaking = false
    private var biasNames: [String] = []
    private var frameRemainder: [Float] = []
    private var remainderStartTime: TimeInterval = 0
    /// After a confirmed barge-in the adopted utterance keeps receiving frames even while the
    /// interrupted turn is still unwinding.
    private var continuingBargeInUtterance = false
    /// An utterance that ended while the previous turn was still finishing.
    private var queuedUtterance: Utterance?
    /// Capture time just past the newest frame processed (the endpoint clock).
    private var latestCaptureTime: TimeInterval = 0
    /// Uptimes of the last spoken utterance's end of speech and endpoint decision, until the
    /// reply's first audio starts (then recorded as latency and cleared).
    private var pendingFirstAudio: (endOfSpeech: TimeInterval, endpoint: TimeInterval)?

    public init(coordinator: AgentCoordinator, dependencies: Dependencies, configuration: AgentConfiguration = .default) {
        self.coordinator = coordinator
        self.dependencies = dependencies
        self.configuration = configuration
        continueListeningAfterResponse = configuration.continueListeningAfterResponse
        endpoint = EndpointDetector(config: configuration.endpointing)
        bargeIn = EchoBargeInController(config: configuration.endpointing, echoRisk: dependencies.initialEchoRisk)
    }

    // MARK: - Session control

    /// Starts listening. Requests the microphone just in time (PRD §11).
    @discardableResult
    public func start() async -> Bool {
        guard !isActive else { return true }
        let status = await dependencies.permissions.request(.microphone)
        guard status == .granted else {
            coordinator.transition(to: .permissionRequired, reason: .permissionDenied)
            return false
        }
        do {
            let frames = try await dependencies.capture.startCapture()
            isActive = true
            captureFailed = false
            coordinator.setSessionActive(true)
            biasNames = await dependencies.biasNames()
            endpoint.reset()
            transcripts.reset()
            frameRemainder.removeAll()
            continuingBargeInUtterance = false
            queuedUtterance = nil
            // The VAD is reset once per session (not per turn) so its noise model is kept.
            await dependencies.vad.reset()
            pendingFirstAudio = nil
            await dependencies.speech.observeFirstAudio { [weak self] uptime in
                Task { @MainActor in await self?.firstAudioStarted(at: uptime) }
            }
            enterListening(reason: .userStartedSession)
            captureTask = Task { [weak self] in
                for await frame in frames {
                    guard let self else { return }
                    await self.process(frame)
                }
                await self?.captureEnded()
            }
            if let sessionEvents = dependencies.sessionEvents {
                let stream = sessionEvents()
                eventsTask = Task { [weak self] in
                    for await event in stream { await self?.handle(sessionEvent: event) }
                }
            }
            if let levels = dependencies.levels {
                let stream = levels()
                levelsTask = Task { [weak self] in
                    for await level in stream { self?.coordinator.updateLevels(input: level.input, output: level.output) }
                }
            }
            return true
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "voice", code: "capture_start_failed"))
            return false
        }
    }

    /// Stops listening and speaking. Pending actions stay pending (the card remains visible).
    public func stop(reason: TransitionReason = .userStoppedSession) async {
        guard isActive else { return }
        isActive = false
        captureTask?.cancel()
        eventsTask?.cancel()
        levelsTask?.cancel()
        captureTask = nil
        eventsTask = nil
        levelsTask = nil
        continuingBargeInUtterance = false
        queuedUtterance = nil
        await dependencies.speech.stop()
        await dependencies.capture.stopCapture()
        coordinator.setSessionActive(false)
        coordinator.updatePartialTranscript(nil)
        coordinator.updateLevels(input: 0, output: 0)
        if [.listening, .endpointing, .interrupted].contains(coordinator.state) {
            coordinator.settle(reason: reason)
        }
    }

    /// Typed input from the keyboard (committed text; never a partial).
    public func submitTyped(_ text: String) {
        startTurn(.typed(text))
    }

    private func captureEnded() async {
        guard isActive else { return }
        // The engine gave up restarting (e.g. repeated configuration changes): don't stay deaf.
        captureFailed = true
        PrivacySafeLogger.shared.log(.error(domain: "voice", code: "capture_stream_ended"))
        await stop(reason: .audioInterruption)
    }

    private func handle(sessionEvent event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan, .mediaServicesWereLost, .mediaServicesWereReset:
            await stop(reason: .audioInterruption)
        case .interruptionEnded:
            break // Apple guidance: the user restarts the session.
        case let .routeChanged(_, _, current):
            bargeIn.setEchoRisk(current.echoRisk)
            PrivacySafeLogger.shared.log(.audioRoute(kind: SafeLabel(current.echoRisk)))
        }
    }

    // MARK: - Frame processing

    func process(_ frame: AudioFrame) async {
        guard isActive else { return }
        latestCaptureTime = frame.timestamp + Double(frame.samples.count) / AudioFrame.sampleRate
        updateSpeakingState()
        // Re-frame to the VAD's window (512 samples for Silero), keeping accurate timestamps.
        if frameRemainder.isEmpty { remainderStartTime = frame.timestamp }
        frameRemainder.append(contentsOf: frame.samples)
        let window = dependencies.vad.frameSamples
        while frameRemainder.count >= window {
            let samples = Array(frameRemainder.prefix(window))
            frameRemainder.removeFirst(window)
            let vadFrame = AudioFrame(samples: samples, timestamp: remainderStartTime, assistantWasSpeaking: frame.assistantWasSpeaking)
            remainderStartTime += Double(window) / AudioFrame.sampleRate
            let probability = await dependencies.vad.speechProbability(samples)
            await handle(probability: probability, frame: vadFrame)
        }
    }

    private func handle(probability: Float, frame: AudioFrame) async {
        if continuingBargeInUtterance {
            if let event = endpoint.process(probability: probability, frame: frame) { await handle(endpointEvent: event) }
            return
        }
        let state = coordinator.state
        if state.assistantIsSpeaking || bargeIn.isArmed {
            if let event = bargeIn.process(probability: probability, frame: frame) {
                await handleBargeIn(event)
            }
            if state.assistantIsSpeaking || continuingBargeInUtterance { return }
        }
        guard Self.listensForUtterances(in: state), turnTask == nil else { return }
        if let event = endpoint.process(probability: probability, frame: frame) { await handle(endpointEvent: event) }
    }

    private func handle(endpointEvent event: EndpointEvent) async {
        switch event {
        case .speechStarted:
            transcripts.reset()
            if coordinator.state != .listening, turnTask == nil { coordinator.transition(to: .listening, reason: .speechDetected) }
            if turnTask == nil { coordinator.primeLanguageModel() }
        case let .speechContinuing(progress):
            if turnTask == nil {
                if progress.trailingSilence > 0.15, coordinator.state == .listening {
                    coordinator.transition(to: .endpointing, reason: .silenceDetected)
                } else if progress.trailingSilence == 0, coordinator.state == .endpointing {
                    coordinator.transition(to: .listening, reason: .speechResumed)
                }
            }
            if progress.isPartialDue, !partialInFlight {
                runPartial(progress.audio, revision: progress.partialRevision, utteranceStart: progress.startTime)
            }
        case let .speechEnded(utterance), let .maxDurationReached(utterance):
            continuingBargeInUtterance = false
            if turnTask != nil {
                queuedUtterance = utterance // finalize once the interrupted turn has unwound
            } else {
                finalize(utterance)
            }
        case .noSpeechTimeout:
            if coordinator.state == .listening, coordinator.restingState == .idle, turnTask == nil {
                await stop(reason: .timeout)
            }
        }
    }

    static func listensForUtterances(in state: AgentState) -> Bool {
        switch state {
        case .idle, .listening, .endpointing, .waitingForConfirmation, .waitingForClarification, .interrupted: true
        default: false
        }
    }

    // MARK: - ASR

    private func runPartial(_ audio: [Float], revision: Int, utteranceStart: TimeInterval) {
        partialInFlight = true
        let recognizer = dependencies.recognizer
        Task { [weak self] in
            let partial = try? await recognizer.partial(audio, revision: revision)
            guard let self else { return }
            self.partialInFlight = false
            // Ignore late results that belong to an earlier utterance.
            guard let partial, self.isActive, self.endpoint.currentUtteranceStartTime == utteranceStart else { return }
            self.transcripts.append(partial)
            // UI only (PRD §6.2).
            self.coordinator.updatePartialTranscript(partial)
            self.endpoint.markTranscriptStable(self.transcripts.isStable, coveringSampleCount: audio.count)
        }
    }

    private func finalize(_ utterance: Utterance) {
        // The user stopped talking `trailingSilence` ago (the endpoint waited for that silence).
        let now = ProcessInfo.processInfo.systemUptime
        let trailingSilence = min(max(0, latestCaptureTime - utterance.speechEndTime), 5)
        pendingFirstAudio = (endOfSpeech: now - trailingSilence, endpoint: now)
        if coordinator.state == .listening { coordinator.transition(to: .endpointing, reason: .silenceDetected) }
        if coordinator.state == .interrupted { coordinator.transition(to: .listening, reason: .speechDetected) }
        if coordinator.state == .listening { coordinator.transition(to: .endpointing, reason: .silenceDetected) }
        coordinator.transition(to: .transcribing, reason: .silenceDetected)
        let recognizer = dependencies.recognizer
        let bias = ASRContext(biasPhrases: biasNames)
        let metrics = dependencies.metrics
        turnTask = Task { [weak self] in
            let watch = Stopwatch()
            let final = try? await recognizer.final(utterance.samples, context: bias)
            await metrics?.record(.endpointToFinalTranscript, milliseconds: watch.elapsedMilliseconds)
            guard let self else { return }
            guard let final, !final.text.isEmpty else {
                self.turnTask = nil
                self.coordinator.updatePartialTranscript(nil)
                self.coordinator.settle(reason: .emptyTranscript)
                self.enterListening(reason: .emptyTranscript)
                return
            }
            await self.runTurn(.speech(final))
        }
    }

    /// First audio of a reply: records end-of-speech → first-audio latency for spoken turns.
    func firstAudioStarted(at uptime: TimeInterval) async {
        guard let pending = pendingFirstAudio else { return }
        pendingFirstAudio = nil
        await dependencies.metrics?.record(.endOfSpeechToFirstAudio, milliseconds: (uptime - pending.endOfSpeech) * 1000)
        await dependencies.metrics?.record(.endpointToFirstAudio, milliseconds: (uptime - pending.endpoint) * 1000)
    }

    private func startTurn(_ utterance: UserUtterance) {
        guard turnTask == nil else { return }
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.speech.stop()
            self.pendingFirstAudio = nil // typed: no speech to measure from
            await self.runTurn(utterance)
        }
    }

    private func runTurn(_ utterance: UserUtterance) async {
        if !continuingBargeInUtterance { endpoint.cancelUtterance() }
        let report = await coordinator.handle(utterance)
        bargeInCounters = bargeIn.counters
        turnTask = nil
        if report.interrupted {
            // Keep the adopted barge-in utterance; it continues (or already ended and is queued).
            if let queued = queuedUtterance {
                queuedUtterance = nil
                finalize(queued)
            } else if isActive, !continuingBargeInUtterance {
                enterListening(reason: .bargeIn)
            }
            return
        }
        transcripts.reset()
        if isActive {
            if coordinator.state == .idle, !continueListeningAfterResponse {
                await stop(reason: .speechFinished)
            } else {
                enterListening(reason: .speechFinished)
            }
        }
    }

    // MARK: - Barge-in

    private func updateSpeakingState() {
        let speaking = dependencies.speech.spokenText.isSpeaking
        if speaking, !assistantWasSpeaking {
            bargeIn.assistantDidStartSpeaking(text: dependencies.speech.spokenText.audibleText() ?? "")
        } else if !speaking, assistantWasSpeaking {
            bargeIn.assistantDidStopSpeaking()
        }
        assistantWasSpeaking = speaking
    }

    private func handleBargeIn(_ event: BargeInEvent) async {
        switch event {
        case let .candidate(candidate):
            await dependencies.speech.setDucked(true)
            guard !candidateInFlight else { return }
            candidateInFlight = true
            let recognizer = dependencies.recognizer
            Task { [weak self] in
                let partial = try? await recognizer.partial(candidate.audio, revision: 0)
                guard let self else { return }
                self.candidateInFlight = false
                // Compare with what is audible *now* (back-to-back replies change the text).
                let assistantText = self.dependencies.speech.spokenText.audibleText() ?? self.bargeIn.assistantText
                let verdict = self.bargeIn.evaluate(candidateTranscript: partial?.text ?? "", assistantText: assistantText)
                await self.handleBargeIn(verdict)
            }
        case let .confirmedBargeIn(confirmation):
            let watch = Stopwatch()
            await dependencies.speech.interrupt()
            await dependencies.metrics?.record(.bargeInToSilence, milliseconds: watch.elapsedMilliseconds)
            // Continue the user's utterance from the audio captured since the onset; frames go
            // straight to the endpoint detector until that utterance ends.
            endpoint.adoptUtterance(samples: confirmation.audio, startTime: confirmation.utteranceStartTime,
                                    speechStartTime: confirmation.speechStartTime)
            continuingBargeInUtterance = true
            transcripts.reset()
            coordinator.updatePartialTranscript(nil)
        case let .rejectedEcho(rejection):
            // A stale verdict (no candidate pending) has nothing to undo.
            if rejection.reason != .noCandidate {
                await dependencies.speech.setDucked(false)
            }
        }
        bargeInCounters = bargeIn.counters
    }

    // MARK: - Helpers

    private func enterListening(reason: TransitionReason) {
        guard isActive else { return }
        switch coordinator.state {
        case .idle, .interrupted, .transcribing, .endpointing:
            coordinator.transition(to: .listening, reason: reason)
        default:
            break // waiting states keep their meaning; they already capture audio
        }
    }
}
