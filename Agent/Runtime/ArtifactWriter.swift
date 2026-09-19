import Core
import Foundation
import Intelligence
import LLM
import Telemetry

/// Writes the artifacts a job produces: Markdown, in a fixed skeleton, from what the job found.
///
/// Swift owns the structure — the title, the headings, the order, the sources — and the model
/// writes only the prose inside each section, one constrained pass for the whole document. That
/// way an artifact always has the shape of the thing it claims to be, and the model cannot invent
/// a section, a source or a heading that promises something the job never did.
public struct LanguageModelArtifactWriter: ArtifactWriting {
    public let model: any LanguageModel
    public let store: IntelligenceStore
    /// Characters the model may write per section.
    public var sectionLimit: Int
    private let calendar: Calendar
    private let logger: PrivacySafeLogger?

    public init(
        model: any LanguageModel,
        store: IntelligenceStore,
        sectionLimit: Int = 600,
        calendar: Calendar = .current,
        logger: PrivacySafeLogger? = nil
    ) {
        self.model = model
        self.store = store
        self.sectionLimit = sectionLimit
        self.calendar = calendar
        self.logger = logger
    }

    public func write(
        title: String,
        kind: ArtifactKind,
        about: String,
        request: String,
        findings: [String],
        planID: UUID?,
        subjectID: UUID?,
        now: Date
    ) async throws -> Artifact {
        let sections = kind.sections
        let llmRequest = LLMRequest(
            cacheablePrefix: Self.prefix(),
            suffix: Self.suffix(
                title: title, kind: kind, about: about, request: request,
                findings: findings, sections: sections, limit: sectionLimit
            ),
            grammar: Self.grammar(sections: sections.count, limit: sectionLimit),
            maxOutputTokens: min(900, sections.count * 220),
            draftSources: findings + [about, request]
        )

        var output = ""
        let watch = Stopwatch()
        for try await event in model.generate(llmRequest) {
            if case let .text(delta) = event { output += delta }
        }
        logger?.log(.stageLatency(stage: .llmTotal, milliseconds: Int(watch.elapsedMilliseconds)))

        let bodies = Self.decode(output, expecting: sections.count)
        let sourceIDs = try await sources(in: findings)
        let markdown = Self.assemble(
            title: title, kind: kind, sections: sections, bodies: bodies,
            sources: try await sourceTitles(sourceIDs), now: now, calendar: calendar
        )

        let artifact = Artifact(
            title: title, kind: kind, markdown: markdown, planID: planID,
            subjectID: subjectID, sourceIDs: sourceIDs, createdAt: now, updatedAt: now
        )
        let saved = try await store.save(artifact)
        try? await store.record(ActivityEntry(
            kind: .acted, headline: saved.summaryLine, detail: kind.displayName,
            entityID: saved.id, undo: .forget(saved.id), createdAt: now
        ))
        return saved
    }

    // MARK: Sources

    /// Documents whose citation appears in what the job found, so "where did this come from?"
    /// is answered from what was actually read — not from what the model says it read.
    private func sources(in findings: [String]) async throws -> [UUID] {
        let documents = try await store.documents(limit: 100)
        var found: [UUID] = []
        for document in documents where findings.contains(where: { $0.contains(document.title) }) {
            found.append(document.id)
        }
        return found
    }

    private func sourceTitles(_ ids: [UUID]) async throws -> [String] {
        try await store.entities(ids).map(\.title)
    }

    // MARK: Prompt and grammar

    /// Exactly `sections` strings, nothing else. The model cannot add a section or leave one out.
    static func grammar(sections: Int, limit: Int) -> String {
        var rule = #"root ::= "{\"sections\":[" "#
        rule += (0..<max(1, sections)).map { _ in "body" }.joined(separator: #" "," "#)
        rule += #" "]}""#
        return [
            rule,
            #"body ::= "\"" chr{1,\#(limit)} "\"""#,
            #"chr ::= [^"\\\x7F\x00-\x1F] | "\\" ["\\/n]"#,
        ].joined(separator: "\n") + "\n"
    }

    static func prefix() -> String {
        let instructions = """
        You write short documents for a private assistant that runs on the user's iPhone. You are \
        given a title, the kind of document, what it should cover, and everything the assistant \
        found. Reply with exactly one JSON object: the text of each section, in order.

        Rules:
        1. Use only what the assistant found. If something is not there, say it is not known — never fill it in.
        2. Plain sentences. No headings, no bullets longer than a line, no markdown beyond "- " lists.
        3. Write to the user, about their own work. No preamble, no "here is", no sign-off.
        4. Keep each section to what is worth reading: a few sentences, or a short list.
        5. Dates and names exactly as they appear in what was found.
        6. Reply with the JSON object only.
        """
        return "<|im_start|>system\n" + instructions + "<|im_end|>\n"
    }

    static func suffix(
        title: String, kind: ArtifactKind, about: String, request: String,
        findings: [String], sections: [String], limit: Int
    ) -> String {
        var lines = [
            "Document: \(title) (\(kind.rawValue))",
            "It should cover: \(about)",
            "The user asked: \(request)",
            "Sections, in order: " + sections.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; "),
        ]
        if findings.isEmpty {
            lines.append("Found: nothing — say so plainly in every section.")
        } else {
            lines.append("Found:")
            for finding in findings.prefix(8) {
                lines.append("- " + finding.replacingOccurrences(of: "\n", with: " ").prefix(400))
            }
        }
        return "<|im_start|>user\n" + lines.joined(separator: "\n") + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    struct Sections: Decodable {
        var sections: [String]
    }

    static func decode(_ output: String, expecting count: Int) -> [String] {
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Sections.self, from: data) else {
            return Array(repeating: "", count: count)
        }
        var bodies = decoded.sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while bodies.count < count { bodies.append("") }
        return Array(bodies.prefix(count))
    }

    /// The document itself. Every part of this is Swift's: the title, the headings, the order, the
    /// note about where it came from, and the date.
    static func assemble(
        title: String, kind: ArtifactKind, sections: [String], bodies: [String],
        sources: [String], now: Date, calendar: Calendar
    ) -> String {
        var markdown = "# \(title)\n"
        for (heading, body) in zip(sections, bodies) {
            let text = body.isEmpty ? "_Nothing found for this._" : body
            markdown += "\n## \(heading)\n\n\(text)\n"
        }
        if !sources.isEmpty, kind != .draft {
            markdown += "\n## Sources\n\n" + sources.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        markdown += "\n---\n\nWritten on this iPhone, \(formatter.string(from: now)).\n"
        return markdown
    }
}
