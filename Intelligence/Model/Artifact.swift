import Foundation
import Telemetry

/// The kinds of thing the assistant writes for the user.
public enum ArtifactKind: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// One page to read before a room: status, open questions, what to decide.
    case brief
    /// What a longer thing says, shorter.
    case summary
    /// Dated, specific steps.
    case plan
    /// Something the user will edit and send.
    case draft
    /// Everything found, kept in order.
    case notes

    public var displayName: String {
        switch self {
        case .brief: "Brief"
        case .summary: "Summary"
        case .plan: "Plan"
        case .draft: "Draft"
        case .notes: "Notes"
        }
    }

    /// The sections the writer fills. Deterministic structure, model-written content: the shape of
    /// a brief is not something a 4B model should have to invent each time.
    public var sections: [String] {
        switch self {
        case .brief: ["What this is about", "Where things stand", "What needs deciding", "Before the room"]
        case .summary: ["The short version", "Details", "What it means for you"]
        case .plan: ["The goal", "Steps", "Watch out for"]
        case .draft: ["Draft"]
        case .notes: ["Notes", "Sources"]
        }
    }
}

/// Something the assistant wrote, kept as a document the user owns.
///
/// Markdown, versioned, with the sources it was built from — so "where did this come from?" has an
/// answer, and a rewrite never silently destroys the version the user already read.
public struct Artifact: Identifiable, Sendable, Equatable, Codable {
    /// Also an entity, so an artifact can be named, linked to a project and forgotten like anything else.
    public let id: UUID
    public var title: String
    public var kind: ArtifactKind
    public var markdown: String
    public var version: Int
    /// The job that produced it, when it came from one.
    public var planID: UUID?
    /// The project or goal it is about.
    public var subjectID: UUID?
    /// Documents and entities it was built from, in the order they were used.
    public var sourceIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        kind: ArtifactKind,
        markdown: String,
        version: Int = 1,
        planID: UUID? = nil,
        subjectID: UUID? = nil,
        sourceIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.markdown = markdown
        self.version = version
        self.planID = planID
        self.subjectID = subjectID
        self.sourceIDs = sourceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var wordCount: Int {
        markdown.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// A line for the activity feed and for reading aloud: "Beta review brief — 180 words".
    public var summaryLine: String {
        "\(title) — \(wordCount) words"
    }
}

/// One earlier version, kept so a rewrite can be compared or undone.
public struct ArtifactVersion: Sendable, Equatable, Codable {
    public var artifactID: UUID
    public var version: Int
    public var markdown: String
    public var createdAt: Date
}
