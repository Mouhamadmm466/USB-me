#if KOKORO_TTS && DEVELOPER_MODES
import Agent
import ASR
import Audio
import Core
import DeviceBenchmark
import Foundation
import KokoroTTS
import LLM
import Models
import Permissions
import SwiftUI
import Telemetry
import Tools
import TTS
import VoiceLoop

/// End-to-end spoken-loop self-test on the phone (`-VoiceSelfTest`, `Scripts/voice_selftest_device.sh`).
///
/// Everything is the production pipeline — VAD endpointing, streaming Whisper, primed Nemotron,
/// validation, resolution, confirmation, Kokoro speech through the speaker, barge-in — except two
/// things: the "microphone" plays scripted user utterances (spoken by Kokoro, fed in real time,
/// 32 ms frames) and the tools are the evaluation fakes (no real message, call or event). The
/// script: ask to text Alex → hear the confirmation → say "yes" → the message is composed; ask
/// for the calendar → interrupt the answer with "stop, call Priya instead" → decline with "no".
/// The report (steps, what was heard and said, latencies, barge-in counters) goes to
/// Documents/SelfTest/latest.json.
@MainActor
@Observable
final class VoiceSelfTestController {
    struct Step: Codable, Sendable {
        let name: String
        var passed: Bool
        var detail: String
        var heard: String?
        var assistant: String?
    }

    struct Report: Codable, Sendable {
        var startedAt = Date()
        var finishedAt: Date?
        // Not ProcessInfo.hostName: it resolves DNS synchronously and stalled launch past the
        // scene-create watchdog (0x8BADF00D) on device.
        var device = BenchmarkEnvironment.current().deviceModel
        var steps: [Step] = []
        var latencies: [String: StageSummary] = [:]
        var bargeIns: BargeInCounters?
        var consequentialEffects: [String] = []
        var error: String?
        var passed: Bool { error == nil && !steps.isEmpty && steps.allSatisfy(\.passed) }
    }

    private(set) var lines: [String] = []
    private(set) var report = Report()
    private(set) var isFinished = false

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SelfTest", isDirectory: true)
    }

    private func log(_ line: String) {
        lines.append(line)
        // Progress is also written as it happens, so a stalled run can be diagnosed remotely.
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let stamped = lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        try? stamped.write(to: Self.directory.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }

    func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            try await runScript()
        } catch {
            report.error = String(describing: error)
            log("Failed: \(error)")
        }
        report.finishedAt = Date()
        isFinished = true
        log(report.passed ? "PASS" : "FAIL")
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            try? data.write(to: Self.directory.appendingPathComponent("latest.json"), options: .atomic)
        }
    }

    // MARK: - Script

    private func runScript() async throws {
        log("Verifying models")
        let manager = ModelManager()
        _ = await manager.reconcileOnLaunch(resumeInterruptedDownloads: false)
        _ = await manager.importPendingFiles()
        let asr = try await manager.verifiedFileURLs(for: .asr)
        let llm = try await manager.verifiedFileURLs(for: .llm)
        let tts = try await manager.verifiedFileURLs(for: .tts)
        guard let whisperURL = asr[ModelFileName.whisperBaseEn], let vadURL = asr[ModelFileName.sileroVAD],
              let llmURL = llm[ModelFileName.nemotronNano4B],
              let weights = tts[ModelFileName.kokoroWeights], let voiceURL = tts[ModelFileName.kokoroVoiceAfHeart] else {
            throw BenchmarkModeError.missing("model files")
        }

        log("Loading models")
        let whisper = WhisperRuntime(modelURL: whisperURL, speechGateModelURL: vadURL)
        try await whisper.load()
        let vad = try SileroVAD(modelURL: vadURL)
        log("Loading Nemotron (the first run after a prompt change evaluates the prefix, ~20 s)")
        let nemotron = NemotronRuntime(modelURL: llmURL, stateCacheDirectory: BenchmarkController.llmStateDirectory)
        try await nemotron.prepare(cacheablePrefix: PromptBuilder().cacheablePrefix)
        log("Loading Kokoro")
        let kokoro = KokoroRuntime(modelURL: weights, voiceURL: voiceURL)
        try await kokoro.warmUp()

        log("Recording the user's lines")
        func clip(_ text: String) async throws -> [Float] {
            let audio = try await kokoro.synthesize(text)
            return Self.resample(audio.samples, from: audio.sampleRate, to: AudioFrame.sampleRate)
                + [Float](repeating: 0, count: Int(AudioFrame.sampleRate * 0.2))
        }
        let askText = try await clip("Text Alex that I'll be twenty minutes late.")
        let sayYes = try await clip("Yes, send it.")
        let askCalendar = try await clip("What's on my calendar tomorrow?")
        let interrupt = try await clip("Stop. Call Priya instead.")
        let sayNo = try await clip("No.")

        // The evaluation's fake world: two contacts, three events tomorrow (a long answer to
        // interrupt), every permission granted, nothing real is touched.
        let clock = AgentClock()
        let tomorrow = clock.calendar.date(byAdding: .day, value: 1, to: clock.calendar.startOfDay(for: clock.now()))!
        func at(_ hour: Int, _ minute: Int = 0) -> Date { tomorrow.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        let suite = FakeToolSuite(
            contacts: [
                ContactRecord(identifier: "selftest-alex", givenName: "Alex", familyName: "Kim",
                              phones: [LabeledPhone(label: "mobile", number: "+1 (555) 010-1001")]),
                ContactRecord(identifier: "selftest-priya", givenName: "Priya", familyName: "Patel",
                              phones: [LabeledPhone(label: "mobile", number: "+1 (555) 010-2002")]),
            ],
            events: [
                EventReference(eventIdentifier: "selftest-sync", title: "Team sync", startDate: at(10), endDate: at(10, 30)),
                EventReference(eventIdentifier: "selftest-lunch", title: "Lunch with Priya", startDate: at(12), endDate: at(13)),
                EventReference(eventIdentifier: "selftest-dentist", title: "Dentist", startDate: at(15), endDate: at(16)),
            ],
            clock: clock
        )
        let environment = suite.environment
        let metrics = PerformanceMetrics()
        var engineConfiguration = AudioEngineConfiguration()
        engineConfiguration.voiceProcessing = false // playback only: the input is scripted
        let player = AudioEngine(configuration: engineConfiguration)
        let speech = SpeechQueue(synthesizer: kokoro, player: player, metrics: metrics)
        let coordinator = AgentCoordinator(
            dependencies: AgentDependencies(
                languageModel: nemotron,
                resolver: ActionResolver(environment: environment),
                executor: ToolExecutor(environment: environment),
                permissions: suite.permissions,
                speech: speech,
                capabilities: .allAvailable,
                clock: clock,
                metrics: metrics
            ),
            configuration: .default
        )
        let microphone = ScriptedAudioCapture(isAssistantSpeaking: { speech.spokenText.isSpeaking })
        let voice = VoiceSessionController(
            coordinator: coordinator,
            dependencies: VoiceSessionController.Dependencies(
                capture: microphone,
                recognizer: whisper,
                vad: vad,
                speech: speech,
                permissions: PermissionManager(backend: FakePermissionBackend.allGranted()),
                biasNames: { ["Alex Kim", "Priya Patel"] },
                initialEchoRisk: .low,
                metrics: metrics
            ),
            configuration: .default
        )
        coordinator.transition(to: .idle, reason: .modelsReady)
        log("Starting the session")
        guard await voice.start() else { throw SelfTestError.sessionDidNotStart }
        log("Session started (state \(coordinator.state.rawValue))")
        try await Task.sleep(for: .seconds(1))

        func settled() -> Bool {
            !speech.spokenText.isSpeaking && microphone.isIdle
                && [.idle, .listening, .waitingForConfirmation, .waitingForClarification].contains(coordinator.state)
        }
        func waitUntil(_ timeout: Double, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return await condition()
        }
        func step(_ name: String, passed: Bool, _ detail: String) {
            report.steps.append(Step(name: name, passed: passed, detail: detail,
                                     heard: coordinator.presentation.lastUserUtterance,
                                     assistant: coordinator.presentation.assistantText))
            log("\(passed ? "✓" : "✗") \(name): \(detail)")
        }

        // 1. A consequential request is read back and waits for a yes.
        log("Saying: text Alex…")
        microphone.enqueue(askText)
        var ok = await waitUntil(45) { coordinator.state == .waitingForConfirmation && settled() }
        let card = coordinator.presentation.actionCard
        step("confirmation_requested", passed: ok && card?.tool == .composeMessage,
             "state \(coordinator.state.rawValue), card \(card?.tool.rawValue ?? "none")")

        // 2. A spoken yes executes it exactly once.
        log("Saying: yes, send it")
        microphone.enqueue(sayYes)
        ok = await waitUntil(45) { await suite.recorder.consequentialEffects.count >= 1 && settled() && coordinator.state != .waitingForConfirmation }
        var effects = await suite.recorder.consequentialEffects
        let composed = effects.contains {
            if case .messageComposed = $0 { return true }
            return false
        }
        step("executed_after_yes", passed: ok && effects.count == 1 && composed, "\(effects.count) side effect(s): \(effects)")

        // 3. Barge-in: interrupt the calendar answer with a new request.
        log("Saying: what's on my calendar tomorrow")
        microphone.enqueue(askCalendar)
        let started = await waitUntil(45) { speech.spokenText.isSpeaking }
        try await Task.sleep(for: .milliseconds(900))
        log("Interrupting: stop, call Priya instead")
        microphone.enqueue(interrupt)
        ok = await waitUntil(60) { coordinator.state == .waitingForConfirmation && settled() }
        let callCard = coordinator.presentation.actionCard
        step("barge_in", passed: started && ok && voice.bargeInCounters.confirmed >= 1 && callCard?.tool == .initiateCall,
             "answer started \(started), confirmed barge-ins \(voice.bargeInCounters.confirmed), card \(callCard?.tool.rawValue ?? "none")")

        // 4. A spoken no cancels; nothing else executes.
        log("Saying: no")
        microphone.enqueue(sayNo)
        ok = await waitUntil(30) { coordinator.state != .waitingForConfirmation && settled() }
        effects = await suite.recorder.consequentialEffects
        step("declined", passed: ok && effects.count == 1 && coordinator.presentation.actionCard == nil,
             "\(effects.count) side effect(s) in total")

        await voice.stop()
        let summary = await metrics.summary()
        report.latencies = summary.stages
        report.bargeIns = voice.bargeInCounters
        report.consequentialEffects = effects.map { String(describing: $0) }
        for stage in ["endOfSpeechToFirstAudio", "endpointToFirstAudio", "endpointToFinalTranscript", "llmTotal", "ttsTimeToFirstAudio", "bargeInToSilence"] {
            if let value = summary.stages[stage] { log(String(format: "%@ p50 %.0f ms (n=%d)", stage, value.p50, value.count)) }
        }
    }

    /// Linear-interpolation resampler (Kokoro speaks at 24 kHz; the pipeline hears 16 kHz).
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !samples.isEmpty else { return samples }
        let count = Int(Double(samples.count) * target / source)
        return (0..<count).map { index in
            let position = Double(index) * source / target
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }
}

enum SelfTestError: Error {
    case sessionDidNotStart
}

/// A "microphone" that plays queued utterances in real time and silence (faint noise) otherwise.
final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Float] = []
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private let isAssistantSpeaking: @Sendable () -> Bool

    init(isAssistantSpeaking: @escaping @Sendable () -> Bool) {
        self.isAssistantSpeaking = isAssistantSpeaking
    }

    func enqueue(_ samples: [Float]) {
        lock.withLock { queued.append(contentsOf: samples) }
    }

    var isIdle: Bool { lock.withLock { queued.isEmpty } }

    private func nextFrame(_ count: Int) -> [Float] {
        lock.withLock {
            var frame = Array(queued.prefix(count))
            queued.removeFirst(frame.count)
            while frame.count < count { frame.append(Float.random(in: -0.0005...0.0005)) }
            return frame
        }
    }

    func startCapture() async throws -> AsyncStream<AudioFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioFrame.self)
        self.continuation = continuation
        task = Task.detached { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            var index = 0
            while !Task.isCancelled, let self {
                let frame = AudioFrame(samples: self.nextFrame(512), timestamp: Double(index) * 512 / AudioFrame.sampleRate,
                                       assistantWasSpeaking: self.isAssistantSpeaking())
                continuation.yield(frame)
                index += 1
                deadline = deadline.advanced(by: .milliseconds(32))
                try? await clock.sleep(until: deadline)
            }
        }
        return stream
    }

    func stopCapture() async {
        task?.cancel()
        continuation?.finish()
    }
}

struct VoiceSelfTestView: View {
    @State private var controller = VoiceSelfTestController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice loop self-test").font(.title.weight(.semibold))
                ForEach(Array(controller.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout.monospaced())
                }
                if !controller.isFinished { ProgressView() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await controller.run() }
    }
}
#endif
