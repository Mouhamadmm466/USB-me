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
        public var metrics: PerformanceMetrics?

        public init(capture: any AudioCapturing, recognizer: any SpeechRecognizer, vad: any VoiceActivityDetecting,
                    speech: SpeechQueue, permissions: any PermissionProviding,
                    biasNames: @escaping @Sendable () async -> [String] = { [] }, metrics: PerformanceMetrics? = nil) {
            self.capture = capture
            self.recognizer = recognizer
            self.vad = vad
            self.speech = speech
            self.permissions = permissions
            self.biasNames = biasNames
            self.metrics = metrics
        }
    }

    public private(set) var isActive = false
    public private(set) var bargeInCounters = BargeInCounters()

    private let coordinator: AgentCoordinator
    private let dependencies: Dependencies
    private let configuration: AgentConfiguration
    private var endpoint: EndpointDetector
    private var bargeIn: EchoBargeInController
    private var transcripts = TranscriptBuffer()
    private var captureTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var partialInFlight = false
    private var candidateInFlight = false
    private var assistantWasSpeaking = false
    private var biasNames: [String] = []
    private var frameRemainder: [Float] = []

    public init(coordinator: AgentCoordinator, dependencies: Dependencies, configuration: AgentConfiguration = .default) {
        self.coordinator = coordinator
        self.dependencies = dependencies
        self.configuration = configuration
        endpoint = EndpointDetector(config: configuration.endpointing)
        bargeIn = EchoBargeInController(config: configuration.endpointing)
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
            coordinator.setSessionActive(true)
            biasNames = await dependencies.biasNames()
            resetDetectors()
            enterListening(reason: .userStartedSession)
            captureTask = Task { [weak self] in
                for await frame in frames {
                    guard let self else { return }
                    await self.process(frame)
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
        captureTask = nil
        await dependencies.speech.stop()
        await dependencies.capture.stopCapture()
        coordinator.setSessionActive(false)
        coordinator.updatePartialTranscript(nil)
        if [.listening, .endpointing, .interrupted].contains(coordinator.state) {
            coordinator.settle(reason: reason)
        }
    }

    /// Typed input from the keyboard (committed text; never a partial).
    public func submitTyped(_ text: String) {
        startTurn(.typed(text))
    }

    // MARK: - Frame processing

    func process(_ frame: AudioFrame) async {
        guard isActive else { return }
        updateSpeakingState()
        // Re-frame to the VAD's window (512 samples for Silero).
        frameRemainder.append(contentsOf: frame.samples)
        let window = dependencies.vad.frameSamples
        while frameRemainder.count >= window {
            let samples = Array(frameRemainder.prefix(window))
            frameRemainder.removeFirst(window)
            let vadFrame = AudioFrame(samples: samples, timestamp: frame.timestamp, assistantWasSpeaking: frame.assistantWasSpeaking)
            let probability = await dependencies.vad.speechProbability(samples)
            await handle(probability: probability, frame: vadFrame)
        }
    }

    private func handle(probability: Float, frame: AudioFrame) async {
        let state = coordinator.state
        if state.assistantIsSpeaking || bargeIn.isArmed {
            if let event = bargeIn.process(probability: probability, frame: frame) {
                await handleBargeIn(event)
            }
            if state.assistantIsSpeaking { return }
        }
        guard Self.listensForUtterances(in: state), turnTask == nil else { return }
        guard let event = endpoint.process(probability: probability, frame: frame) else { return }
        switch event {
        case .speechStarted:
            transcripts.reset()
            if state != .listening { coordinator.transition(to: .listening, reason: .speechDetected) }
        case let .speechContinuing(progress):
            if progress.trailingSilence > 0.15, coordinator.state == .listening {
                coordinator.transition(to: .endpointing, reason: .silenceDetected)
            } else if progress.trailingSilence == 0, coordinator.state == .endpointing {
                coordinator.transition(to: .listening, reason: .speechResumed)
            }
            if progress.isPartialDue, !partialInFlight {
                runPartial(progress.audio, revision: progress.partialRevision)
            }
        case let .speechEnded(utterance), let .maxDurationReached(utterance):
            finalize(utterance)
        case .noSpeechTimeout:
            if coordinator.state == .listening, coordinator.restingState == .idle {
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

    private func runPartial(_ audio: [Float], revision: Int) {
        partialInFlight = true
        let recognizer = dependencies.recognizer
        Task { [weak self] in
            let partial = try? await recognizer.partial(audio, revision: revision)
            guard let self else { return }
            self.partialInFlight = false
            guard let partial, self.isActive, Self.listensForUtterances(in: self.coordinator.state) else { return }
            self.transcripts.append(partial)
            // UI only (PRD §6.2).
            self.coordinator.updatePartialTranscript(partial)
            self.endpoint.markTranscriptStable(self.transcripts.isStable, coveringSampleCount: audio.count)
        }
    }

    private func finalize(_ utterance: Utterance) {
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
                self.enterListening(reason: .emptyTranscript)
                return
            }
            await self.runTurn(.speech(final), endOfSpeech: watch)
        }
    }

    private func startTurn(_ utterance: UserUtterance) {
        guard turnTask == nil else { return }
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.speech.stop()
            await self.runTurn(utterance, endOfSpeech: Stopwatch())
        }
    }

    private func runTurn(_ utterance: UserUtterance, endOfSpeech: Stopwatch) async {
        endpoint.cancelUtterance()
        let report = await coordinator.handle(utterance)
        await dependencies.metrics?.record(.endOfSpeechToFirstAudio, milliseconds: endOfSpeech.elapsedMilliseconds)
        if report.interrupted {
            bargeInCounters = bargeIn.counters
        }
        turnTask = nil
        resetDetectors(keepBargeIn: report.interrupted)
        if isActive, !report.interrupted {
            if coordinator.state == .idle, !configuration.continueListeningAfterResponse {
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
            let assistantText = bargeIn.assistantText
            Task { [weak self] in
                let partial = try? await recognizer.partial(candidate.audio, revision: 0)
                guard let self else { return }
                self.candidateInFlight = false
                let verdict = self.bargeIn.evaluate(candidateTranscript: partial?.text ?? "", assistantText: assistantText)
                await self.handleBargeIn(verdict)
            }
        case let .confirmedBargeIn(confirmation):
            let watch = Stopwatch()
            await dependencies.speech.interrupt()
            await dependencies.metrics?.record(.bargeInToSilence, milliseconds: watch.elapsedMilliseconds)
            PrivacySafeLogger.shared.log(.safety(check: "barge_in", outcome: SafeLabel(confirmation.reason)))
            // Continue the user's utterance from the audio captured since the onset.
            endpoint.adoptUtterance(samples: confirmation.audio, startTime: confirmation.utteranceStartTime, speechStartTime: confirmation.speechStartTime)
            coordinator.updatePartialTranscript(nil)
        case let .rejectedEcho(rejection):
            await dependencies.speech.setDucked(false)
            PrivacySafeLogger.shared.log(.safety(check: "barge_in", outcome: SafeLabel(rejection.reason)))
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

    private func resetDetectors(keepBargeIn: Bool = false) {
        endpoint.reset()
        transcripts.reset()
        frameRemainder.removeAll()
        if !keepBargeIn { bargeIn.reset() }
        let vad = dependencies.vad
        Task { await vad.reset() }
    }
}
