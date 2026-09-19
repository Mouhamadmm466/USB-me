import Foundation

/// Artifacts: what the assistant wrote, kept as documents the user owns.
///
/// Every rewrite keeps the version it replaced, because the user may already have read it — and
/// because "make it shorter" should never be a way to lose the longer one.
extension IntelligenceStore {
    @discardableResult
    public func save(_ artifact: Artifact) throws -> Artifact {
        var artifact = artifact
        artifact.updatedAt = Date()
        let existing = try self.artifact(artifact.id)
        if let existing, existing.markdown != artifact.markdown {
            artifact.version = existing.version + 1
        }

        try db.transaction {
            try db.run(
                """
                INSERT INTO entities (id, kind, title, title_folded, status, project_id, importance,
                    attributes, created_at, updated_at)
                VALUES (?1, 'artifact', ?2, ?3, 'active', ?4, 0.6, '{}', ?5, ?6)
                ON CONFLICT(id) DO UPDATE SET title = ?2, title_folded = ?3, project_id = ?4, updated_at = ?6;
                """,
                [
                    .text(artifact.id.uuidString), .text(artifact.title),
                    .text(artifact.title.intelligenceFolded), .init(artifact.subjectID?.uuidString),
                    .init(artifact.createdAt), .init(artifact.updatedAt),
                ]
            )
            if let existing, existing.markdown != artifact.markdown {
                try db.run(
                    """
                    INSERT OR REPLACE INTO artifact_versions (artifact_id, version, markdown, created_at)
                    VALUES (?1, ?2, ?3, ?4);
                    """,
                    [
                        .text(existing.id.uuidString), .init(existing.version), .text(existing.markdown),
                        .init(existing.updatedAt),
                    ]
                )
            }
            try db.run(
                """
                INSERT INTO artifacts (id, title, kind, markdown, version, plan_id, subject_id, sources,
                    created_at, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                ON CONFLICT(id) DO UPDATE SET title = ?2, kind = ?3, markdown = ?4, version = ?5,
                    plan_id = ?6, subject_id = ?7, sources = ?8, updated_at = ?10;
                """,
                [
                    .text(artifact.id.uuidString), .text(artifact.title), .text(artifact.kind.rawValue),
                    .text(artifact.markdown), .init(artifact.version), .init(artifact.planID?.uuidString),
                    .init(artifact.subjectID?.uuidString),
                    .text(Self.encodeJSON(artifact.sourceIDs.map(\.uuidString))),
                    .init(artifact.createdAt), .init(artifact.updatedAt),
                ]
            )
        }
        return artifact
    }

    public func artifact(_ id: UUID) throws -> Artifact? {
        try db.query(
            "SELECT \(IntelligenceSchema.artifactColumns) FROM artifacts WHERE id = ?1;", [.text(id.uuidString)]
        ).first.map(Self.artifact(from:))
    }

    public func artifacts(limit: Int = 50, subjectID: UUID? = nil) throws -> [Artifact] {
        var bindings: [SQLValue] = []
        var filter = ""
        if let subjectID {
            bindings.append(.text(subjectID.uuidString))
            filter = "WHERE subject_id = ?1"
        }
        return try db.query(
            """
            SELECT \(IntelligenceSchema.artifactColumns) FROM artifacts \(filter)
            ORDER BY updated_at DESC LIMIT \(max(1, limit));
            """,
            bindings
        ).map(Self.artifact(from:))
    }

    /// Earlier versions, newest first.
    public func versions(of artifactID: UUID) throws -> [ArtifactVersion] {
        try db.query(
            """
            SELECT artifact_id, version, markdown, created_at FROM artifact_versions
            WHERE artifact_id = ?1 ORDER BY version DESC;
            """,
            [.text(artifactID.uuidString)]
        ).map { row in
            ArtifactVersion(
                artifactID: UUID(uuidString: row.string(0) ?? "") ?? artifactID,
                version: Int(row.int(1) ?? 1),
                markdown: row.string(2) ?? "",
                createdAt: row.date(3) ?? Date()
            )
        }
    }

    public func forgetArtifact(_ id: UUID) throws {
        try db.transaction {
            try db.run("DELETE FROM artifact_versions WHERE artifact_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM artifacts WHERE id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM assertions WHERE subject_id = ?1 OR object_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM entities WHERE id = ?1;", [.text(id.uuidString)])
        }
    }

    static func artifact(from row: SQLRow) -> Artifact {
        Artifact(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            title: row.string(1) ?? "",
            kind: ArtifactKind(rawValue: row.string(2) ?? "") ?? .notes,
            markdown: row.string(3) ?? "",
            version: Int(row.int(4) ?? 1),
            planID: row.string(5).flatMap(UUID.init(uuidString:)),
            subjectID: row.string(6).flatMap(UUID.init(uuidString:)),
            sourceIDs: (decodeJSON([String].self, row.string(7)) ?? []).compactMap(UUID.init(uuidString:)),
            createdAt: row.date(8) ?? Date(),
            updatedAt: row.date(9) ?? Date()
        )
    }
}
