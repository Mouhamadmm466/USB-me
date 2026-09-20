import CryptoKit
import Foundation

/// The knowledge half of the store: documents the user brought in, their passages, and the search
/// over them.
///
/// A document is also an entity, so it can be talked about ("the syllabus"), linked to a project,
/// and forgotten the same way as everything else. Retrieval is BM25 over FTS5 with a recency and
/// project nudge — no embedding model until the numbers say one is needed (PRD §43).
extension IntelligenceStore {
    // MARK: Importing

    /// Stores a parsed document and its passages. Re-importing the same content updates the
    /// existing document instead of making a second copy of it.
    @discardableResult
    public func importDocument(
        _ parsed: ParsedDocument,
        chunks: [DocumentChunk],
        title: String,
        origin: DocumentOrigin,
        sourceID: String? = nil,
        mediaType: String? = nil,
        bytes: Int64 = 0,
        projectID: UUID? = nil,
        now: Date = Date()
    ) throws -> KnowledgeDocument {
        let hash = Self.contentHash(parsed)
        if let existing = try document(withHash: hash) {
            return existing
        }

        let entity = IntelligenceEntity(kind: .document, title: title, createdAt: now, updatedAt: now)
        var document = KnowledgeDocument(
            id: entity.id, title: title, origin: origin, sourceID: sourceID, mediaType: mediaType,
            bytes: bytes, pageCount: parsed.pageCount, chunkCount: chunks.count,
            contentHash: hash, importedAt: now
        )

        try db.transaction {
            try insertEntity(entity)
            try db.run(
                """
                INSERT INTO documents (id, title, origin, source_id, media_type, bytes, page_count,
                    content_hash, imported_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                """,
                [
                    .text(document.id.uuidString), .text(document.title), .text(origin.rawValue),
                    .init(sourceID), .init(mediaType), .init(bytes), .init(parsed.pageCount.map(Double.init)),
                    .text(hash), .init(now),
                ]
            )
            for chunk in chunks {
                try db.run(
                    """
                    INSERT INTO chunks (id, document_id, ordinal, heading, page, text, characters)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
                    """,
                    [
                        .text(chunk.id.uuidString), .text(document.id.uuidString), .init(chunk.ordinal),
                        .init(chunk.heading), .init(chunk.page.map(Double.init)), .text(chunk.text),
                        .init(chunk.text.count),
                    ]
                )
            }
        }
        document.chunkCount = chunks.count

        // A document that belongs to a project is findable from it, and vice versa.
        if let projectID {
            _ = try? record(Assertion(
                subjectID: document.id, predicate: .about, objectID: projectID, type: .observed,
                authority: .observation, provenance: Provenance(sourceType: origin.sourceType, sourceID: sourceID),
                validFrom: now, createdAt: now, updatedAt: now
            ))
        }
        return document
    }

    public func document(_ id: UUID) throws -> KnowledgeDocument? {
        try db.query(
            "SELECT \(IntelligenceSchema.documentColumns) FROM documents WHERE id = ?1;", [.text(id.uuidString)]
        ).first.map(Self.document(from:))
    }

    public func document(withHash hash: String) throws -> KnowledgeDocument? {
        try db.query(
            "SELECT \(IntelligenceSchema.documentColumns) FROM documents WHERE content_hash = ?1;", [.text(hash)]
        ).first.map(Self.document(from:))
    }

    public func documents(limit: Int = 100) throws -> [KnowledgeDocument] {
        try db.query(
            """
            SELECT \(IntelligenceSchema.documentColumns) FROM documents
            ORDER BY imported_at DESC LIMIT \(max(1, limit));
            """
        ).map(Self.document(from:))
    }

    /// Passages in order, for reading a document or expanding around a hit.
    public func chunks(of documentID: UUID, around ordinal: Int? = nil, radius: Int = 1) throws -> [DocumentChunk] {
        var clause = "document_id = ?1"
        var bindings: [SQLValue] = [.text(documentID.uuidString)]
        if let ordinal {
            bindings.append(.init(ordinal - radius))
            bindings.append(.init(ordinal + radius))
            clause += " AND ordinal BETWEEN ?2 AND ?3"
        }
        return try db.query(
            "SELECT \(IntelligenceSchema.chunkColumns) FROM chunks WHERE \(clause) ORDER BY ordinal;", bindings
        ).map(Self.chunk(from:))
    }

    /// Removes a document, its passages and the entity that represented it.
    public func forgetDocument(_ id: UUID) throws {
        try db.transaction {
            try db.run("DELETE FROM chunks WHERE document_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM documents WHERE id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM assertions WHERE subject_id = ?1 OR object_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM entities WHERE id = ?1;", [.text(id.uuidString)])
        }
    }

    // MARK: Searching

    /// Passages that answer a question, best first.
    ///
    /// BM25 does the work; recency and project membership only nudge the order, because a passage
    /// that actually contains the answer should not lose to a newer one that does not.
    public func passages(
        matching question: String,
        limit: Int = 5,
        projectID: UUID? = nil,
        documentID: UUID? = nil,
        now: Date = Date()
    ) throws -> [KnowledgePassage] {
        guard searchMode == .fullText, let query = Self.matchExpression(question) else {
            return try passagesByPrefix(question, limit: limit, documentID: documentID)
        }
        var bindings: [SQLValue] = [.text(query), .init(limit * 6)]
        var filter = ""
        if let documentID {
            bindings.append(.text(documentID.uuidString))
            filter = "AND chunks_fts.document_id = ?3"
        }
        let rows = try db.query(
            """
            SELECT chunks_fts.chunk_id, chunks_fts.document_id, bm25(chunks_fts, 1.0)
            FROM chunks_fts
            WHERE chunks_fts MATCH ?1 \(filter)
            ORDER BY bm25(chunks_fts, 1.0) LIMIT ?2;
            """,
            bindings
        )
        guard !rows.isEmpty else { return [] }

        // Lower BM25 is better; flip it so every score in the pipeline reads "higher is better".
        var scores: [UUID: Double] = [:]
        for row in rows {
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)) else { continue }
            scores[id] = -(row.double(2) ?? 0)
        }
        let linked = projectID.map { try? documentIDs(linkedTo: $0) } ?? nil

        var passages: [KnowledgePassage] = []
        for (chunk, document) in try chunksWithDocuments(Array(scores.keys)) {
            var score = scores[chunk.id] ?? 0
            // Two weeks of age costs about as much as a modest BM25 difference.
            let age = now.timeIntervalSince(document.importedAt) / (14 * 86_400)
            score -= min(max(age, 0), 4) * 0.15
            if let linked, linked.contains(document.id) { score += 1 }
            passages.append(KnowledgePassage(chunk: chunk, document: document, score: score))
        }
        return Array(passages.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Documents attached to a project, directly or through what they are about.
    public func documentIDs(linkedTo projectID: UUID) throws -> Set<UUID> {
        let rows = try db.query(
            """
            SELECT subject_id FROM assertions
            WHERE object_id = ?1 AND state = 'active' AND predicate IN ('about', 'belongs_to')
            UNION
            SELECT id FROM entities WHERE project_id = ?1 AND kind = 'document';
            """,
            [.text(projectID.uuidString)]
        )
        return Set(rows.compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) })
    }

    /// Fallback when FTS5 is unavailable: substring matching, honest about being worse.
    private func passagesByPrefix(_ question: String, limit: Int, documentID: UUID?) throws -> [KnowledgePassage] {
        let needle = question.trimmingCharacters(in: .whitespacesAndNewlines).intelligenceFolded
        guard needle.count > 2 else { return [] }
        var bindings: [SQLValue] = [.text(needle), .init(limit)]
        var filter = ""
        if let documentID {
            bindings.append(.text(documentID.uuidString))
            filter = "AND document_id = ?3"
        }
        let rows = try db.query(
            """
            SELECT id FROM chunks WHERE lower(text) LIKE '%' || ?1 || '%' \(filter)
            ORDER BY ordinal LIMIT ?2;
            """,
            bindings
        )
        let ids = rows.compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
        return try chunksWithDocuments(ids).map { KnowledgePassage(chunk: $0.0, document: $0.1, score: 0) }
    }

    private func chunksWithDocuments(_ ids: [UUID]) throws -> [(DocumentChunk, KnowledgeDocument)] {
        guard !ids.isEmpty else { return [] }
        let placeholders = (1...ids.count).map { "?\($0)" }.joined(separator: ", ")
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.chunkColumns) FROM chunks WHERE id IN (\(placeholders));
            """,
            ids.map { .text($0.uuidString) }
        ).map(Self.chunk(from:))
        var documents: [UUID: KnowledgeDocument] = [:]
        return rows.compactMap { chunk in
            if let document = documents[chunk.documentID] { return (chunk, document) }
            guard let document = try? document(chunk.documentID) else { return nil }
            documents[chunk.documentID] = document
            return (chunk, document)
        }
    }

    // MARK: Mapping

    /// FTS5 MATCH for a question: content words only, OR-ed, so a passage matching most of the
    /// question still surfaces. Quoted, so the user's punctuation is never query syntax.
    static func matchExpression(_ question: String) -> String? {
        let words = question
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() }
            .filter { $0.count > 2 && !stopWords.contains($0) }
        guard !words.isEmpty else { return nil }
        return Array(Set(words)).sorted().prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "was", "are", "you", "your", "our", "with", "that", "this", "from",
        "what", "when", "where", "who", "how", "why", "did", "does", "can", "could", "would",
        "should", "about", "into", "there", "their", "they", "them", "has", "have", "had", "been",
        "will", "just", "any", "all", "some", "out", "get", "got", "tell", "say", "said",
    ]

    static func document(from row: SQLRow) -> KnowledgeDocument {
        KnowledgeDocument(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            title: row.string(1) ?? "",
            origin: DocumentOrigin(rawValue: row.string(2) ?? "") ?? .files,
            sourceID: row.string(3),
            mediaType: row.string(4),
            bytes: row.int(5) ?? 0,
            pageCount: row.int(6).map(Int.init),
            chunkCount: Int(row.int(9) ?? 0),
            contentHash: row.string(7) ?? "",
            importedAt: row.date(8) ?? Date()
        )
    }

    static func chunk(from row: SQLRow) -> DocumentChunk {
        DocumentChunk(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            documentID: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
            ordinal: Int(row.int(2) ?? 0),
            heading: row.string(3),
            page: row.int(4).map(Int.init),
            text: row.string(5) ?? ""
        )
    }

    /// Identifies a document by what is in it, not by where it came from, so the same syllabus
    /// shared twice from two apps is one document.
    static func contentHash(_ parsed: ParsedDocument) -> String {
        var hasher = SHA256()
        for page in parsed.pages {
            hasher.update(data: Data(page.text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
