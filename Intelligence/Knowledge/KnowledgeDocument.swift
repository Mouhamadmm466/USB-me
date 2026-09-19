import Foundation
import Telemetry

/// Where a document came from. Decides what authority anything learned from it can have.
public enum DocumentOrigin: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// Shared into the app from another app.
    case share
    /// Picked from the Files app or a folder the user granted.
    case files
    /// Fetched from the web by a research capability.
    case web
    /// Pulled from a connected service.
    case connector

    public var sourceType: SourceType {
        switch self {
        case .share: .share
        case .files: .document
        case .web: .web
        case .connector: .connector
        }
    }
}

/// A document the user brought in: its identity, where it came from, and enough metadata to show
/// it honestly ("page 4 of the syllabus") without keeping the original file.
public struct KnowledgeDocument: Identifiable, Sendable, Equatable, Codable {
    /// The same identifier as the `document` entity, so a document is a first-class thing in the
    /// user's world rather than a file the system happens to hold.
    public let id: UUID
    public var title: String
    public var origin: DocumentOrigin
    /// Where it came from inside that origin: a URL, a bookmark, a message id.
    public var sourceID: String?
    public var mediaType: String?
    public var bytes: Int64
    public var pageCount: Int?
    public var chunkCount: Int
    /// Hash of the extracted text, so importing the same thing twice updates rather than duplicates.
    public var contentHash: String
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        origin: DocumentOrigin,
        sourceID: String? = nil,
        mediaType: String? = nil,
        bytes: Int64 = 0,
        pageCount: Int? = nil,
        chunkCount: Int = 0,
        contentHash: String = "",
        importedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.origin = origin
        self.sourceID = sourceID
        self.mediaType = mediaType
        self.bytes = bytes
        self.pageCount = pageCount
        self.chunkCount = chunkCount
        self.contentHash = contentHash
        self.importedAt = importedAt
    }
}

/// One retrievable passage of a document.
public struct DocumentChunk: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var documentID: UUID
    /// Position in the document, so neighbouring passages can be read in order.
    public var ordinal: Int
    /// The heading this passage sits under, when the document has any.
    public var heading: String?
    public var page: Int?
    public var text: String

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        ordinal: Int,
        heading: String? = nil,
        page: Int? = nil,
        text: String
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.heading = heading
        self.page = page
        self.text = text
    }

    /// How the passage is cited back to the user: "Syllabus, page 4".
    public func citation(documentTitle: String) -> String {
        var citation = documentTitle
        if let page { citation += ", page \(page)" }
        else if let heading, !heading.isEmpty { citation += " — \(heading)" }
        return citation
    }
}

/// A passage retrieved for a question, with everything needed to show where it came from.
public struct KnowledgePassage: Identifiable, Sendable, Equatable {
    public var id: UUID { chunk.id }
    public var chunk: DocumentChunk
    public var document: KnowledgeDocument
    /// Higher is better. Composed from BM25, recency and any reranking.
    public var score: Double

    public var citation: String { chunk.citation(documentTitle: document.title) }
}

/// Reranks the passages FTS found. Left to a later phase: retrieval is measured first, and a model
/// pass is only added where the numbers say it is needed (PRD §43).
public protocol PassageReranking: Sendable {
    func rerank(_ passages: [KnowledgePassage], question: String) async throws -> [KnowledgePassage]
}

/// Keeps BM25's order. The default, and what the evaluation measures against.
public struct NoReranker: PassageReranking {
    public init() {}
    public func rerank(_ passages: [KnowledgePassage], question: String) async throws -> [KnowledgePassage] {
        passages
    }
}
