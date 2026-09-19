#if DEVELOPER_MODES
import AgentEval
import Core
import DeviceBenchmark
import Foundation
import LLM
import Models
import SwiftUI
import Telemetry

/// Runs the agent evaluation suite on the phone (`-RunEval`, see `Scripts/eval_device.sh`) against
/// the same Metal-backed Nemotron runtime and prompt the app uses, with the harness's fake native
/// stores (no real contacts, calendars or messages are touched).
///
/// Cases and fixtures are copied into Documents/Eval/ by the script. Observations are appended to
/// Documents/Eval/Runs/<run>/observations.jsonl as each case finishes (resumable: a relaunch skips
/// finished cases) and scored on the Mac with `agent-eval score`. Launch arguments:
/// `-EvalRun <name>` (default "device"), `-EvalLimit <n>` (stratified subset), `-EvalCategory <c>`.
@MainActor
@Observable
final class DeviceEvalController {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case coolingDown
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var alreadyDone = 0
    private(set) var secondsPerCase: Double = 0
    private(set) var lastCase = ""

    static var evalRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Eval", isDirectory: true)
    }

    private let arguments = ProcessInfo.processInfo.arguments

    private func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let runDirectory = Self.evalRoot.appendingPathComponent("Runs/\(value("-EvalRun") ?? "device")", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            phase = .preparing("Loading cases")
            let dataset = try EvalCaseLoader.loadDataset(
                casesDirectory: Self.evalRoot.appendingPathComponent("Cases", isDirectory: true),
                fixturesDirectory: Self.evalRoot.appendingPathComponent("Fixtures", isDirectory: true)
            )
            var cases = dataset.cases
            var filters: [String] = []
            if let category = value("-EvalCategory") {
                cases = cases.filter { $0.category == category }
                filters.append("category=\(category)")
            }
            if let limit = value("-EvalLimit").flatMap(Int.init) {
                cases = EvalSelection.stratified(cases, limit: limit)
                filters.append("limit=\(limit)")
            }

            let observationsURL = runDirectory.appendingPathComponent("observations.jsonl")
            var finished = Set<String>()
            if let existing = try? String(contentsOf: observationsURL, encoding: .utf8) {
                for line in existing.split(separator: "\n") {
                    if let record = try? JSONDecoder().decode(CaseObservation.self, from: Data(line.utf8)) { finished.insert(record.id) }
                }
            }
            let pending = cases.filter { !finished.contains($0.id) }
            total = cases.count
            alreadyDone = cases.count - pending.count
            completed = alreadyDone

            phase = .preparing("Verifying the language model")
            let manager = ModelManager()
            _ = await manager.reconcileOnLaunch(resumeInterruptedDownloads: false)
            _ = await manager.importPendingFiles()
            guard let modelURL = try await manager.verifiedFileURLs(for: .llm)[ModelFileName.nemotronNano4B] else {
                throw BenchmarkModeError.missing(ModelFileName.nemotronNano4B)
            }
            phase = .preparing("Loading Nemotron")
            let runtime = NemotronRuntime(modelURL: modelURL, stateCacheDirectory: BenchmarkController.llmStateDirectory)
            try await runtime.prepare(cacheablePrefix: PromptBuilder().cacheablePrefix)

            let manifestURL = runDirectory.appendingPathComponent("run.json")
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = RunManifest(
                    startedAt: Date(), modelIdentifier: runtime.modelIdentifier,
                    modelSHA256: "be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2",
                    promptVersion: PromptBuilder.promptVersion,
                    runtime: "llama.cpp b11046 Metal on \(BenchmarkEnvironment.current().deviceModel), iOS \(UIDevice.current.systemVersion)",
                    gitCommit: Bundle.main.object(forInfoDictionaryKey: "VoiceAgentGitCommit") as? String,
                    host: BenchmarkEnvironment.current().deviceModel, threads: nil, caseCount: cases.count, filters: filters
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: manifestURL)
            }
            if !FileManager.default.fileExists(atPath: observationsURL.path) {
                FileManager.default.createFile(atPath: observationsURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: observationsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let lineEncoder = JSONEncoder()
            lineEncoder.outputFormatting = [.sortedKeys]
            lineEncoder.dateEncodingStrategy = .iso8601

            phase = .running
            let started = Date()
            var ranThisLaunch = 0
            for evalCase in pending {
                await coolDownIfNeeded()
                guard let fixture = dataset.fixtures[evalCase.fixture] else { continue }
                lastCase = evalCase.id
                let observation = await CaseRunner.run(evalCase, fixture: fixture, languageModel: runtime)
                try handle.write(contentsOf: lineEncoder.encode(observation) + Data("\n".utf8))
                completed += 1
                ranThisLaunch += 1
                secondsPerCase = Date().timeIntervalSince(started) / Double(ranThisLaunch)
                writeProgress(to: runDirectory, finished: false)
            }
            phase = .finished
            writeProgress(to: runDirectory, finished: true)
        } catch {
            phase = .failed(String(describing: error))
            try? String(describing: error).write(to: runDirectory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Sustained inference heats the phone: pause at `.critical` until it is back to `.serious`
    /// or better, so the run never pushes the device into shutdown territory.
    private func coolDownIfNeeded() async {
        guard ProcessInfo.processInfo.thermalState == .critical else { return }
        phase = .coolingDown
        while ProcessInfo.processInfo.thermalState == .critical {
            try? await Task.sleep(for: .seconds(30))
        }
        phase = .running
    }

    private func writeProgress(to directory: URL, finished: Bool) {
        let progress: [String: Any] = [
            "completed": completed, "total": total, "finished": finished,
            "secondsPerCase": secondsPerCase, "lastCase": lastCase,
            "thermalState": ThermalProbe.current.rawValue,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("progress.json"), options: .atomic)
        }
    }
}

struct DeviceEvalView: View {
    @State private var controller = DeviceEvalController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent evaluation")
                .font(.largeTitle.weight(.semibold))
            switch controller.phase {
            case .idle:
                Text("Starting…")
            case let .preparing(step):
                ProgressView(step)
            case .running, .coolingDown, .finished:
                ProgressView(value: Double(controller.completed), total: Double(max(controller.total, 1)))
                Text("\(controller.completed) of \(controller.total) cases")
                    .font(.title3.monospacedDigit())
                if controller.secondsPerCase > 0 {
                    let remaining = Double(controller.total - controller.completed) * controller.secondsPerCase
                    Text(String(format: "%.1f s per case · about %.0f min left", controller.secondsPerCase, remaining / 60))
                        .foregroundStyle(.secondary)
                }
                if controller.phase == .coolingDown {
                    Text("Paused while the iPhone cools down.")
                        .foregroundStyle(.orange)
                }
                if controller.phase == .finished {
                    Text("Finished. Copy the run back with Scripts/eval_device.sh.")
                        .foregroundStyle(.green)
                }
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("Uses the pinned Nemotron model on this iPhone and the evaluation's fake contacts, calendars and messages. Keep the app open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .task { await controller.run() }
    }
}
#endif
