import Foundation

/// Locations of the checked-in evaluation dataset.
///
/// Derived from this source file's path at compile time, so the harness, the runner and the test
/// target all find `Tests/AgentEval/{Cases,Fixtures,Results}` without bundling resources.
public enum EvalPaths {
    /// `Tests/AgentEval`.
    public static let agentEvalRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Harness
        .deletingLastPathComponent() // AgentEval

    /// `Tests/AgentEval/Cases` — one `<category>.jsonl` per category plus `MANIFEST.json`.
    public static let casesDirectory = agentEvalRoot.appendingPathComponent("Cases", isDirectory: true)

    /// `Tests/AgentEval/Fixtures` — one `<fixture>.json` per fixture world.
    public static let fixturesDirectory = agentEvalRoot.appendingPathComponent("Fixtures", isDirectory: true)

    /// `Tests/AgentEval/Results` — committed reports (`*.md`, `*.json`); scratch output goes to `Results/tmp`.
    public static let resultsDirectory = agentEvalRoot.appendingPathComponent("Results", isDirectory: true)

    /// Counts and hashes written by `Scripts/generate_agent_eval_cases.py`.
    public static let manifestFile = casesDirectory.appendingPathComponent("MANIFEST.json")
}
