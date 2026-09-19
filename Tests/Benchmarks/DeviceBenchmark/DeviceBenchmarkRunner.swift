import ASR
import Core
import Foundation
import LLM
import Telemetry
import TTS
#if canImport(UIKit)
import UIKit
#endif

/// Inputs for the physical-device feasibility benchmark (PRD Phase 1): the exact pinned models,
/// a recorded utterance, and representative LLM/TTS workloads.
public struct BenchmarkConfiguration: Sendable {
    public var whisperModel: URL
    public var vadModel: URL?
    public var nemotronModel: URL
    /// Kokoro (device builds). nil skips the TTS stages and records why.
    public var synthesizer: (any SpeechSynthesizer)?
    public var synthesizerLoader: (@Sendable () async throws -> Double)?
    /// 16 kHz mono utterance and its reference transcript (for WER).
    public var utteranceAudio: [Float]
    public var utteranceReference: String
    public var llmUtterances: [String]
    public var ttsSentences: [String]
    public var iterations: Int
    public var llmConfig: LLMConfig
    public var stateCacheDirectory: URL?
    /// Also run the LLM stage with speculative drafting off (recorded as `llm_nospec`) so the
    /// report carries an A/B on the same device, thermal state and prompt cache.
    public var compareWithoutSpeculation = true
    /// Times single decode calls of 1…48 tokens (the cost curve that decides how to batch).
    public var profileBatchSizes = true

    public init(
        whisperModel: URL, vadModel: URL?, nemotronModel: URL,
        synthesizer: (any SpeechSynthesizer)?, synthesizerLoader: (@Sendable () async throws -> Double)?,
        utteranceAudio: [Float], utteranceReference: String,
        llmUtterances: [String] = BenchmarkConfiguration.defaultUtterances,
        ttsSentences: [String] = BenchmarkConfiguration.defaultSentences,
        iterations: Int = 5, llmConfig: LLMConfig = LLMConfig(), stateCacheDirectory: URL? = nil
    ) {
        self.whisperModel = whisperModel
        self.vadModel = vadModel
        self.nemotronModel = nemotronModel
        self.synthesizer = synthesizer
        self.synthesizerLoader = synthesizerLoader
        self.utteranceAudio = utteranceAudio
        self.utteranceReference = utteranceReference
        self.llmUtterances = llmUtterances
        self.ttsSentences = ttsSentences
        self.iterations = iterations
        self.llmConfig = llmConfig
        self.stateCacheDirectory = stateCacheDirectory
    }

    public static let defaultUtterances = [
        "Text Alex that I will be 20 minutes late",
        "what's on my calendar tomorrow",
        "remind me to call the dentist tomorrow at 10",
        "move my team sync to 4 pm",
        "call mom",
        "what's 15 percent of 80",
    ]

    public static let defaultSentences = [
        "Okay.",
        "Text Alex Kim: I'll be 20 minutes late. Should I send it?",
        "You have three events tomorrow. The first is Team sync at 10 AM, then lunch with Priya at noon, and the dentist at 3 PM.",
    ]
}

public struct BenchmarkMetric: Codable, Sendable, Equatable {
    public let stage: String
    public let name: String
    public let unit: String
    public let samples: [Double]
    public let p50: Double
    public let p95: Double

    public init(stage: String, name: String, unit: String, samples: [Double]) {
        self.stage = stage
        self.name = name
        self.unit = unit
        self.samples = samples
        let summary = StageSummary(values: samples)
        p50 = summary.p50
        p95 = summary.p95
    }
}

public struct BenchmarkEnvironment: Codable, Sendable, Equatable {
    public let deviceModel: String
    public let systemVersion: String
    public let physicalMemoryGB: Double
    public let processorCount: Int
    public let isSimulator: Bool
    public let appVersion: String

    public static func current() -> BenchmarkEnvironment {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return BenchmarkEnvironment(
            deviceModel: machine,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            isSimulator: simulator,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }
}

public struct BenchmarkReport: Codable, Sendable {
    public var environment: BenchmarkEnvironment
    public var startedAt: Date
    public var finishedAt: Date?
    public var metrics: [BenchmarkMetric] = []
    public var notes: [String] = []
    public var errors: [String] = []
    public var peakFootprintMB: Double = 0
    public var availableMemoryAtStartMB: Double?
    public var thermalStates: [String] = []
    public var batteryStart: Float?
    public var batteryEnd: Float?
    /// Raw model outputs are recorded only for the fixed benchmark utterances (no user data).
    public var llmOutputs: [String: String] = [:]
    public var asrTranscript: String?
    public var asrWordErrorRate: Double?

    public func metric(_ stage: String, _ name: String) -> BenchmarkMetric? {
        metrics.first { $0.stage == stage && $0.name == name }
    }

    public var jsonData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
}

public enum BenchmarkProgress: Sendable, Equatable {
    case stage(String, fraction: Double)
    case finished
}

/// Runs the Phase 1 feasibility benchmark: each exact model alone (cold load + warm latency),
/// then all three resident together with an end-to-end simulated turn, tracking memory
/// footprint, thermal state and battery.
public actor DeviceBenchmarkRunner {
    private let configuration: BenchmarkConfiguration
    private var report: BenchmarkReport
    private var peakFootprint: UInt64 = 0
    private var baselineOutputs: [String: String] = [:]

    public init(configuration: BenchmarkConfiguration) {
        self.configuration = configuration
        report = BenchmarkReport(environment: .current(), startedAt: Date())
    }

    public func run(progress: @escaping @Sendable (BenchmarkProgress) -> Void = { _ in }) async -> BenchmarkReport {
        report.availableMemoryAtStartMB = MemoryProbe.availableBytes().map { Double($0) / 1_048_576 }
        report.batteryStart = await BatteryProbe.level()
        sampleSystem()

        progress(.stage("Speech recognition", fraction: 0.05))
        let whisper = await benchmarkWhisper()
        progress(.stage("Language model", fraction: 0.3))
        if configuration.compareWithoutSpeculation, configuration.llmConfig.speculativeDraftTokens > 0 {
            var baseline = configuration.llmConfig
            baseline.speculativeDraftTokens = 0
            if let runtime = await benchmarkNemotron(stage: "llm_nospec", config: baseline) { await runtime.unload() }
        }
        let nemotron = await benchmarkNemotron(stage: "llm", config: configuration.llmConfig)
        progress(.stage("Text to speech", fraction: 0.6))
        await benchmarkTTS()
        progress(.stage("All models together", fraction: 0.8))
        await benchmarkEndToEnd(whisper: whisper, nemotron: nemotron)

        report.batteryEnd = await BatteryProbe.level()
        sampleSystem()
        report.peakFootprintMB = Double(peakFootprint) / 1_048_576
        report.finishedAt = Date()
        progress(.finished)
        return report
    }

    // MARK: - Stages

    private func benchmarkWhisper() async -> WhisperRuntime? {
        var asrConfig = ASRConfig()
        #if targetEnvironment(simulator)
        asrConfig.useGPU = false
        #endif
        let runtime = WhisperRuntime(modelURL: configuration.whisperModel, config: asrConfig)
        do {
            let load = Stopwatch()
            try await runtime.load()
            record("asr", "cold_load", "ms", [load.elapsedMilliseconds])
            sampleSystem()
            let seconds = Double(configuration.utteranceAudio.count) / AudioFrame.sampleRate
            var finals: [Double] = []
            var partials: [Double] = []
            var transcript = ""
            for _ in 0..<configuration.iterations {
                let watch = Stopwatch()
                let final = try await runtime.final(configuration.utteranceAudio, context: ASRContext(biasPhrases: ["Alex Kim", "Priya Patel"]))
                finals.append(watch.elapsedMilliseconds)
                transcript = final.text
                let partialWatch = Stopwatch()
                _ = try await runtime.partial(Array(configuration.utteranceAudio.prefix(Int(AudioFrame.sampleRate * 1.5))), revision: 1)
                partials.append(partialWatch.elapsedMilliseconds)
                sampleSystem()
            }
            record("asr", "final_transcript", "ms", finals)
            record("asr", "partial_1_5s", "ms", partials)
            record("asr", "real_time_factor", "x", finals.map { seconds * 1000 / max($0, 1) })
            report.asrTranscript = transcript
            report.asrWordErrorRate = WordErrorRate.compute(reference: configuration.utteranceReference, hypothesis: transcript)
            if let vadModel = configuration.vadModel {
                let vad = try SileroVAD(modelURL: vadModel)
                var frameTimes: [Double] = []
                var index = 0
                while index + 512 <= configuration.utteranceAudio.count {
                    let watch = Stopwatch()
                    _ = vad.probability(Array(configuration.utteranceAudio[index..<(index + 512)]))
                    frameTimes.append(watch.elapsedMilliseconds)
                    index += 512
                }
                record("vad", "silero_frame", "ms", frameTimes)
            }
            return runtime
        } catch {
            report.errors.append("asr: \(error)")
            return nil
        }
    }

    private func benchmarkNemotron(stage: String, config: LLMConfig) async -> NemotronRuntime? {
        let runtime = NemotronRuntime(modelURL: configuration.nemotronModel, config: config,
                                      stateCacheDirectory: configuration.stateCacheDirectory)
        let builder = PromptBuilder()
        do {
            let load = Stopwatch()
            try await runtime.load()
            record(stage, "cold_load", "ms", [load.elapsedMilliseconds])
            sampleSystem()
            let cacheExisted = configuration.stateCacheDirectory.map { directory in
                ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains { $0.hasSuffix(".llamastate") }
            } ?? false
            let prefix = Stopwatch()
            try await runtime.prepare(cacheablePrefix: builder.cacheablePrefix)
            record(stage, cacheExisted ? "prefix_state_load" : "prefix_eval_cold", "ms", [prefix.elapsedMilliseconds])
            sampleSystem()
            let clock = AgentClock.fixed(Date(timeIntervalSince1970: 1_789_826_400), timeZone: TimeZone(identifier: "America/New_York")!)
            var promptMs: [Double] = [], ttft: [Double] = [], totals: [Double] = [], perToken: [Double] = [], sampled: [Double] = [], forced: [Double] = []
            var decodePerCall: [Double] = [], samplingTotal: [Double] = [], fallbacks: [Double] = []
            var decodeCalls: [Double] = [], drafted: [Double] = [], acceptedDrafts: [Double] = []
            var callsBySize: [String: [Double]] = [:]
            var unprimedTotals: [Double] = [], unprimedPrompt: [Double] = [], primedTokens: [Double] = []
            var validCount = 0
            for utterance in configuration.llmUtterances {
                let request = builder.request(session: SessionState(), utterance: utterance, clock: clock, maxOutputTokens: config.maxOutputTokens)
                // Without priming: the whole turn suffix is evaluated after the endpoint.
                let (unprimedText, unprimed) = try await runtime.complete(request)
                unprimedTotals.append(unprimed.totalMilliseconds)
                unprimedPrompt.append(unprimed.promptEvalMilliseconds)
                // As in the app: the turn context is evaluated at speech onset (not timed here),
                // only the utterance and the reply are on the critical path.
                await runtime.prime(cacheablePrefix: builder.cacheablePrefix,
                                    suffixHead: builder.suffixHead(session: SessionState(), clock: clock))
                let (text, stats) = try await runtime.complete(request)
                primedTokens.append(Double(stats.primedTokens))
                if text != unprimedText {
                    report.notes.append("\(stage): primed output differs (near-tie) for: \(utterance)")
                }
                if stage == "llm" {
                    report.llmOutputs[utterance] = text
                    // Verification keeps only the model's own greedy choices; a difference can
                    // only come from batched vs. single-token float rounding on a near-tie.
                    if let baseline = baselineOutputs[utterance], baseline != text {
                        report.notes.append("llm output differs from llm_nospec (near-tie) for: \(utterance)")
                    }
                } else {
                    baselineOutputs[utterance] = text
                }
                if case .success = OutputValidator().validate(text) { validCount += 1 }
                promptMs.append(stats.promptEvalMilliseconds)
                ttft.append(stats.timeToFirstTokenMilliseconds)
                totals.append(stats.totalMilliseconds)
                sampled.append(Double(stats.sampledTokens))
                forced.append(Double(stats.forcedTokens))
                let generation = stats.totalMilliseconds - stats.promptEvalMilliseconds
                if stats.sampledTokens > 0 { perToken.append(generation / Double(stats.sampledTokens)) }
                if stats.decodeCalls > 0 { decodePerCall.append(stats.decodeMilliseconds / Double(stats.decodeCalls)) }
                samplingTotal.append(stats.samplingMilliseconds)
                fallbacks.append(Double(stats.grammarFallbacks))
                decodeCalls.append(Double(stats.decodeCalls))
                // Skip the first call (the prompt suffix) when profiling generation batch sizes.
                for (tokens, ms) in zip(stats.decodeCallTokens, stats.decodeCallMilliseconds).dropFirst() {
                    let bucket = tokens == 1 ? "1" : tokens <= 3 ? "2_3" : tokens <= 8 ? "4_8" : "9plus"
                    callsBySize[bucket, default: []].append(ms)
                }
                drafted.append(Double(stats.draftTokens))
                acceptedDrafts.append(Double(stats.acceptedDraftTokens))
                sampleSystem()
            }
            record(stage, "suffix_prompt_eval", "ms", promptMs)
            record(stage, "time_to_first_token", "ms", ttft)
            record(stage, "structured_result_total", "ms", totals)
            record(stage, "ms_per_sampled_token", "ms", perToken)
            record(stage, "sampled_tokens", "count", sampled)
            record(stage, "forced_tokens", "count", forced)
            record(stage, "decode_ms_per_call", "ms", decodePerCall)
            record(stage, "sampling_ms_per_request", "ms", samplingTotal)
            record(stage, "grammar_fallbacks", "count", fallbacks)
            record(stage, "decode_calls", "count", decodeCalls)
            record(stage, "unprimed_structured_result_total", "ms", unprimedTotals)
            record(stage, "unprimed_suffix_prompt_eval", "ms", unprimedPrompt)
            record(stage, "primed_tokens", "count", primedTokens)
            if configuration.profileBatchSizes {
                let sizes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 32, 48]
                for (size, ms) in try await runtime.profileBatchSizes(sizes, allLogits: false, cacheablePrefix: builder.cacheablePrefix).sorted(by: { $0.key < $1.key }) {
                    record(stage, "batch_profile_\(size)", "ms", [ms])
                }
                for (size, ms) in try await runtime.profileBatchSizes([2, 4, 6, 8, 9, 12], allLogits: true, cacheablePrefix: builder.cacheablePrefix).sorted(by: { $0.key < $1.key }) {
                    record(stage, "batch_profile_all_logits_\(size)", "ms", [ms])
                }
            }
            for (bucket, values) in callsBySize.sorted(by: { $0.key < $1.key }) {
                record(stage, "decode_ms_batch_\(bucket)", "ms", values)
            }
            record(stage, "draft_tokens", "count", drafted)
            record(stage, "accepted_draft_tokens", "count", acceptedDrafts)
            report.notes.append("\(stage) valid outputs: \(validCount)/\(configuration.llmUtterances.count)")
            return runtime
        } catch {
            report.errors.append("\(stage): \(error)")
            return nil
        }
    }

    private func benchmarkTTS() async {
        guard let synthesizer = configuration.synthesizer else {
            report.notes.append("tts: skipped (no Kokoro engine in this build — Simulator or macOS)")
            return
        }
        do {
            if let loader = configuration.synthesizerLoader {
                let loadMs = try await loader()
                record("tts", "cold_load", "ms", [loadMs])
            }
            sampleSystem()
            var firstChunk: [Double] = []
            var rtf: [Double] = []
            let chunker = SpeechChunker()
            for _ in 0..<configuration.iterations {
                for sentence in configuration.ttsSentences {
                    // What the queue actually synthesizes first: the chunker's first chunk.
                    let first = chunker.chunks(for: sentence).first ?? sentence
                    let watch = Stopwatch()
                    let audio = try await synthesizer.synthesize(first)
                    let ms = watch.elapsedMilliseconds
                    firstChunk.append(ms)
                    rtf.append(audio.durationSeconds * 1000 / max(ms, 1))
                }
                sampleSystem()
            }
            record("tts", "first_chunk_synthesis", "ms", firstChunk)
            record("tts", "real_time_factor", "x", rtf)
        } catch {
            report.errors.append("tts: \(error)")
        }
    }

    private func benchmarkEndToEnd(whisper: WhisperRuntime?, nemotron: NemotronRuntime?) async {
        guard let whisper, let nemotron else {
            report.notes.append("end_to_end: skipped (a runtime failed to load)")
            return
        }
        let builder = PromptBuilder()
        let clock = AgentClock.fixed(Date(timeIntervalSince1970: 1_789_826_400), timeZone: TimeZone(identifier: "America/New_York")!)
        var endToFirstAudio: [Double] = []
        do {
            for _ in 0..<configuration.iterations {
                // The app primes the turn context at speech onset, before the endpoint.
                await nemotron.prime(cacheablePrefix: builder.cacheablePrefix, suffixHead: builder.suffixHead(session: SessionState(), clock: clock))
                let watch = Stopwatch()
                let final = try await whisper.final(configuration.utteranceAudio, context: ASRContext())
                let request = builder.request(session: SessionState(), utterance: final.text.isEmpty ? configuration.utteranceReference : final.text, clock: clock, maxOutputTokens: configuration.llmConfig.maxOutputTokens)
                _ = try await nemotron.complete(request)
                if let synthesizer = configuration.synthesizer {
                    // What the speech queue synthesizes before the first audio: the first chunk
                    // of the Swift-authored confirmation.
                    let confirmation = "Text Alex Kim: \u{201C}I'll be 20 minutes late.\u{201D} Should I send it?"
                    _ = try await synthesizer.synthesize(SpeechChunker().chunks(for: confirmation).first ?? confirmation)
                }
                endToFirstAudio.append(watch.elapsedMilliseconds)
                sampleSystem()
            }
            record("end_to_end", "endpoint_to_first_audio", "ms", endToFirstAudio)
            if configuration.synthesizer == nil {
                report.notes.append("end_to_end excludes TTS (no Kokoro engine in this build)")
            }
        } catch {
            report.errors.append("end_to_end: \(error)")
        }
    }

    // MARK: - Helpers

    private func record(_ stage: String, _ name: String, _ unit: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        report.metrics.append(BenchmarkMetric(stage: stage, name: name, unit: unit, samples: samples))
    }

    private func sampleSystem() {
        if let footprint = MemoryProbe.physicalFootprintBytes() { peakFootprint = max(peakFootprint, footprint) }
        let thermal = ThermalProbe.current.rawValue
        if report.thermalStates.last != thermal { report.thermalStates.append(thermal) }
    }
}

/// Word error rate (Levenshtein over normalized words).
public enum WordErrorRate {
    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
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
        let numbers = ["twenty": "20", "ten": "10", "fifteen": "15", "thirty": "30", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5"]
        return text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map { numbers[String($0)] ?? String($0) }
    }
}
