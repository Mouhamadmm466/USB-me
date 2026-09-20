import Agent
import AgentEval
import Core
import Foundation
import Intelligence
import IntelligenceEval
import LLM

// agent-eval — evaluation CLI for the on-device agent (real Nemotron via llama.cpp).
//
//   agent-eval run   --cases DIR --fixtures DIR --model GGUF [--state-cache DIR] [--output DIR]
//                    [--limit N] [--category NAME] [--tag TAG] [--resume RUN_DIR] [--threads N]
//       Runs cases through the real agent (validator, resolver, confirmation, executor, fake stores)
//       and appends one CaseObservation per line to RUN_DIR/observations.jsonl (resumable).
//   agent-eval score --run RUN_DIR --cases DIR --fixtures DIR
//       Scores a run and writes RUN_DIR/report.md + report.json (and Results/latest.md).
//   agent-eval smoke [--model GGUF] [--state-cache DIR] "utterance" ...
//       Prints raw model output, validation and timing for ad-hoc utterances.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func positional() -> [String] {
    var result: [String] = []
    var skip = false
    for (index, argument) in arguments.enumerated() where index > 0 {
        if skip { skip = false; continue }
        if argument.hasPrefix("--") { skip = true; continue }
        result.append(argument)
    }
    return result
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaultModel = cwd.appendingPathComponent("ModelCache/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf").path

func makeRuntime() -> NemotronRuntime {
    var config = LLMConfig()
    if let threads = value("--threads").flatMap(Int.init) { config.threads = threads }
    if let drafts = value("--draft-tokens").flatMap(Int.init) { config.speculativeDraftTokens = drafts }
    let cache = value("--state-cache").map { URL(fileURLWithPath: $0) }
    return NemotronRuntime(modelURL: URL(fileURLWithPath: value("--model") ?? defaultModel), config: config, stateCacheDirectory: cache)
}

/// The Mac model (e.g. "MacBookPro16,2"), not the host name: reports get committed and shared.
func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func gitCommit() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
func runCommand() async throws {
    let dataset = try EvalCaseLoader.loadDataset(
        casesDirectory: value("--cases").map { URL(fileURLWithPath: $0) } ?? EvalPaths.casesDirectory,
        fixturesDirectory: value("--fixtures").map { URL(fileURLWithPath: $0) } ?? EvalPaths.fixturesDirectory
    )
    var cases = dataset.cases
    let fixtures = dataset.fixtures
    var filters: [String] = []
    if let category = value("--category") { cases = cases.filter { $0.category == category }; filters.append("category=\(category)") }
    if let tag = value("--tag") { cases = cases.filter { $0.tags.contains(tag) }; filters.append("tag=\(tag)") }
    if let limit = value("--limit").flatMap(Int.init) { cases = EvalSelection.stratified(cases, limit: limit); filters.append("limit=\(limit)") }
    if let drafts = value("--draft-tokens") { filters.append("draft-tokens=\(drafts)") }

    let output = URL(fileURLWithPath: value("--output") ?? cwd.appendingPathComponent("Tests/AgentEval/Results").path)
    let runDirectory: URL
    if let resume = value("--resume") {
        runDirectory = URL(fileURLWithPath: resume)
    } else {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        runDirectory = output.appendingPathComponent("run-\(stamp)")
    }
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let observationsURL = runDirectory.appendingPathComponent("observations.jsonl")
    var completed = Set<String>()
    if let existing = try? String(contentsOf: observationsURL, encoding: .utf8) {
        for line in existing.split(separator: "\n") {
            if let record = try? JSONDecoder().decode(CaseObservation.self, from: Data(line.utf8)) { completed.insert(record.id) }
        }
    }
    let pending = cases.filter { !completed.contains($0.id) }
    print("cases: \(cases.count) selected, \(completed.count) already done, \(pending.count) to run → \(runDirectory.path)")

    let runtime = makeRuntime()
    let prepareWatch = Date()
    try await runtime.prepare(cacheablePrefix: PromptBuilder().cacheablePrefix)
    print("model ready in \(Int(Date().timeIntervalSince(prepareWatch) * 1000)) ms")

    let manifest = RunManifest(
        startedAt: Date(), modelIdentifier: runtime.modelIdentifier,
        modelSHA256: "be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2",
        promptVersion: PromptBuilder.promptVersion, runtime: "llama.cpp b11046 (CPU on this host)",
        gitCommit: gitCommit(), host: hardwareModel(), threads: value("--threads").flatMap(Int.init),
        caseCount: cases.count, filters: filters
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if !FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent("run.json").path) {
        try encoder.encode(manifest).write(to: runDirectory.appendingPathComponent("run.json"))
    }
    if !FileManager.default.fileExists(atPath: observationsURL.path) {
        FileManager.default.createFile(atPath: observationsURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: observationsURL)
    try handle.seekToEnd()
    let lineEncoder = JSONEncoder()
    lineEncoder.outputFormatting = [.sortedKeys]
    lineEncoder.dateEncodingStrategy = .iso8601

    let started = Date()
    for (index, evalCase) in pending.enumerated() {
        guard let fixture = fixtures[evalCase.fixture] else {
            fail("case \(evalCase.id): unknown fixture \(evalCase.fixture)")
        }
        let observation = await CaseRunner.run(evalCase, fixture: fixture, languageModel: runtime)
        try handle.write(contentsOf: lineEncoder.encode(observation) + Data("\n".utf8))
        let elapsed = Date().timeIntervalSince(started)
        let perCase = elapsed / Double(index + 1)
        let remaining = perCase * Double(pending.count - index - 1)
        let outcomes = observation.observations.map(\.outcome.rawValue).joined(separator: ",")
        print(String(format: "[%d/%d] %@ %@ %.1fs  eta %.1fh", index + 1, pending.count, evalCase.id, outcomes,
                     observation.durationMilliseconds / 1000, remaining / 3600))
        fflush(stdout)
    }
    try handle.close()
    print("done → \(observationsURL.path)")
}

@MainActor
func smokeCommand() async throws {
    let runtime = makeRuntime()
    let builder = PromptBuilder()
    let clock = AgentClock.fixed(ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!, timeZone: TimeZone(identifier: "America/New_York")!)
    let watch = Date()
    try await runtime.prepare(cacheablePrefix: builder.cacheablePrefix)
    print("prepared in \(Int(Date().timeIntervalSince(watch) * 1000)) ms")
    for utterance in positional() {
        let request = builder.request(session: SessionState(), utterance: utterance, clock: clock, maxOutputTokens: LLMConfig().maxOutputTokens)
        let (text, stats) = try await runtime.complete(request)
        print("\n> \(utterance)\n\(text)")
        print("  validation: \(OutputValidator().validate(text))")
        print("  prompt \(stats.promptTokens) tok in \(Int(stats.promptEvalMilliseconds)) ms; sampled \(stats.sampledTokens) + forced \(stats.forcedTokens); decode calls \(stats.decodeCalls); drafts \(stats.acceptedDraftTokens)/\(stats.draftTokens) accepted; total \(Int(stats.totalMilliseconds)) ms; stop=\(stats.stoppedReason)")
        fflush(stdout)
    }
}

@MainActor
func scoreCommand() async throws {
    guard let runPath = value("--run") else { fail("score needs --run RUN_DIR") }
    let runDirectory = URL(fileURLWithPath: runPath)
    let dataset = try EvalCaseLoader.loadDataset(
        casesDirectory: value("--cases").map { URL(fileURLWithPath: $0) } ?? EvalPaths.casesDirectory,
        fixturesDirectory: value("--fixtures").map { URL(fileURLWithPath: $0) } ?? EvalPaths.fixturesDirectory
    )
    let byID = Dictionary(uniqueKeysWithValues: dataset.cases.map { ($0.id, $0) })
    let text = try String(contentsOf: runDirectory.appendingPathComponent("observations.jsonl"), encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var scores: [CaseScore] = []
    var harnessErrors = 0
    var illegalTransitions = 0
    var recorderMismatches = 0
    let scorer = EvalScorer()
    for line in text.split(separator: "\n") {
        let record = try decoder.decode(CaseObservation.self, from: Data(line.utf8))
        guard let evalCase = byID[record.id] else { continue }
        if record.error != nil { harnessErrors += 1 }
        illegalTransitions += record.illegalTransitions
        let reported = record.observations.reduce(0) { $0 + $1.consequentialExecutions.count }
        if reported != record.recordedSideEffects { recorderMismatches += 1 }
        scores.append(scorer.score(evalCase, observations: record.observations, details: record.details ?? []))
    }
    var notes = [
        "cases scored: \(scores.count) of \(dataset.cases.count) in the dataset",
        "harness errors: \(harnessErrors)",
        "illegal state transitions: \(illegalTransitions)",
        "side-effect cross-check mismatches (coordinator vs fake adapters): \(recorderMismatches)",
    ]
    var model: String?
    if let data = try? Data(contentsOf: runDirectory.appendingPathComponent("run.json")),
       let manifest = try? decoder.decode(RunManifest.self, from: data) {
        model = manifest.modelIdentifier
        notes.append("prompt \(manifest.promptVersion); runtime \(manifest.runtime); commit \(manifest.gitCommit ?? "?"); host \(manifest.host); filters \(manifest.filters.joined(separator: " "))")
    }
    let metadata = EvalReport.Metadata(
        title: "Agent evaluation — \(runDirectory.lastPathComponent)",
        model: model,
        runner: "agent-eval (real agent pipeline, fake native stores)",
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        notes: notes
    )
    let report = EvalReport.build(scores: scores, metadata: metadata)
    try report.jsonData().write(to: runDirectory.appendingPathComponent("report.json"))
    let markdown = report.markdown()
    try markdown.write(to: runDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    try markdown.write(to: EvalPaths.resultsDirectory.appendingPathComponent("latest.md"), atomically: true, encoding: .utf8)
    print(markdown.split(separator: "\n").prefix(60).joined(separator: "\n"))
}

/// Runs the V2 suites (memory, recall, retrieval, planning, safety, attention) against the real
/// model, so what is measured is what the model actually proposes — not a scripted stand-in.
@MainActor
func intelligenceCommand() async throws {
    let suites = value("--suite").map { [$0] } ?? IntelligenceEvalCases.suites
    let cases = try IntelligenceEvalCases.load(suites: suites)
    guard !cases.isEmpty else { fail("no cases found; run from the repository root") }

    var extractor: (any MemoryExtracting)?
    var planner: Planner?
    if !arguments.contains("--deterministic") {
        let runtime = makeRuntime()
        try await runtime.prepare(cacheablePrefix: LanguageModelMemoryExtractor.prefix())
        extractor = LanguageModelMemoryExtractor(model: runtime)
        planner = Planner(model: runtime)
        print("model ready: \(runtime.modelIdentifier)")
    } else {
        print("deterministic run: the cases' own proposals stand in for the model")
    }

    print("\(cases.count) cases across \(suites.joined(separator: ", "))")
    let run = await IntelligenceEvalRunner(extractor: extractor, planner: planner).run(cases)
    print(run.report)
    if run.failed > 0 { exit(1) }
}

switch arguments.first {
case "intelligence":
    try await intelligenceCommand()
case "run":
    try await runCommand()
case "smoke":
    try await smokeCommand()
case "score":
    try await scoreCommand()
default:
    print("usage: agent-eval run|score|smoke|intelligence … (see docs/evaluation/agent_tests.md)")
}
