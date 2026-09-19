import Core
import Foundation
import LLM

// agent-eval — developer CLI for the on-device agent.
//
//   agent-eval smoke --model <gguf> [--state-cache <dir>] "utterance" ["utterance" ...]
//       Runs utterances through PromptBuilder + NemotronRuntime + OutputValidator and prints
//       raw output, validation result and timing.

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

let defaultModel = FileManager.default.currentDirectoryPath + "/ModelCache/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"

switch arguments.first {
case "smoke":
    let modelPath = value("--model") ?? defaultModel
    let cache = value("--state-cache").map { URL(fileURLWithPath: $0) }
    var config = LLMConfig()
    if let threads = value("--threads").flatMap(Int.init) { config.threads = threads }
    let runtime = NemotronRuntime(modelURL: URL(fileURLWithPath: modelPath), config: config, stateCacheDirectory: cache)
    let builder = PromptBuilder()
    let clock = AgentClock.fixed(
        ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!,
        timeZone: TimeZone(identifier: "America/New_York")!
    )
    let session = SessionState()
    let prepareWatch = Date()
    try await runtime.prepare(cacheablePrefix: builder.cacheablePrefix)
    print("prepared in \(Int(Date().timeIntervalSince(prepareWatch) * 1000)) ms")
    for utterance in positional() {
        let request = builder.request(session: session, utterance: utterance, clock: clock, maxOutputTokens: config.maxOutputTokens)
        let (text, stats) = try await runtime.complete(request)
        print("\n> \(utterance)\n\(text)")
        print("  validation: \(OutputValidator().validate(text))")
        print("  prompt \(stats.promptTokens) tok in \(Int(stats.promptEvalMilliseconds)) ms; sampled \(stats.sampledTokens) + forced \(stats.forcedTokens); total \(Int(stats.totalMilliseconds)) ms; stop=\(stats.stoppedReason)")
    }
default:
    print("usage: agent-eval smoke --model <gguf> [--state-cache <dir>] \"utterance\" ...")
}
