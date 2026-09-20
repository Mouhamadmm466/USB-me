import Foundation

/// Loads the V2 evaluation cases from the JSONL files next to the harness.
public enum IntelligenceEvalCases {
    public static let suites = ["memory", "recall", "retrieval", "planning", "safety", "attention"]

    /// The case directory, found from the test bundle or from the repository when run by the CLI.
    public static func directory(bundle: Bundle? = nil) -> URL? {
        if let bundle, let url = bundle.url(forResource: "Cases", withExtension: nil) { return url }
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Harness
            .deletingLastPathComponent()  // IntelligenceEval
            .appendingPathComponent("Cases", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { return directory }
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/IntelligenceEval/Cases", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    public static func load(suites: [String] = suites, bundle: Bundle? = nil) throws -> [IntelligenceEvalCase] {
        guard let directory = directory(bundle: bundle) else { return [] }
        let decoder = JSONDecoder()
        var cases: [IntelligenceEvalCase] = []
        for suite in suites {
            let url = directory.appendingPathComponent("\(suite).jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                cases.append(try decoder.decode(IntelligenceEvalCase.self, from: Data(line.utf8)))
            }
        }
        return cases
    }
}
