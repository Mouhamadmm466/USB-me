import Foundation

/// The activity log: what the system did, in the user's words, with a way to take it back.
///
/// Every change to the intelligence that the user did not make by hand leaves an entry here. That
/// is the difference between a system that learns and one that quietly changes underneath you —
/// and undo is stored with the entry, so it survives a restart.
extension IntelligenceStore {
    @discardableResult
    public func record(_ entry: ActivityEntry) throws -> ActivityEntry {
        try db.run(
            """
            INSERT INTO activity (id, kind, headline, detail, entity_id, assertion_id, undo, created_at, undone_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
            """,
            [
                .text(entry.id.uuidString), .text(entry.kind.rawValue), .text(entry.headline),
                .init(entry.detail), .init(entry.entityID?.uuidString), .init(entry.assertionID?.uuidString),
                .init(Self.encodeUndo(entry.undo)), .init(entry.createdAt), .init(entry.undoneAt),
            ]
        )
        return entry
    }

    @discardableResult
    public func record(_ entries: [ActivityEntry]) throws -> [ActivityEntry] {
        guard !entries.isEmpty else { return [] }
        try db.transaction { for entry in entries { try record(entry) } }
        return entries
    }

    /// Newest first. `kinds` narrows the feed to one section of it.
    public func activity(limit: Int = 50, kinds: [ActivityKind] = [], since: Date? = nil) throws -> [ActivityEntry] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        if !kinds.isEmpty {
            let placeholders = kinds.map { kind -> String in
                bindings.append(.text(kind.rawValue))
                return "?\(bindings.count)"
            }
            conditions.append("kind IN (\(placeholders.joined(separator: ", ")))")
        }
        if let since {
            bindings.append(.init(since))
            conditions.append("created_at >= ?\(bindings.count)")
        }
        let filter = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        return try db.query(
            """
            SELECT \(IntelligenceSchema.activityColumns) FROM activity \(filter)
            ORDER BY created_at DESC LIMIT \(max(1, limit));
            """,
            bindings
        ).map(Self.activityEntry(from:))
    }

    public func activityEntry(_ id: UUID) throws -> ActivityEntry? {
        try db.query(
            "SELECT \(IntelligenceSchema.activityColumns) FROM activity WHERE id = ?1;", [.text(id.uuidString)]
        ).first.map(Self.activityEntry(from:))
    }

    /// Everything that happened to one entity, for its detail screen.
    public func activity(about entityID: UUID, limit: Int = 30) throws -> [ActivityEntry] {
        try db.query(
            """
            SELECT \(IntelligenceSchema.activityColumns) FROM activity
            WHERE entity_id = ?1 ORDER BY created_at DESC LIMIT \(max(1, limit));
            """,
            [.text(entityID.uuidString)]
        ).map(Self.activityEntry(from:))
    }

    /// Takes back what an entry describes, using the instructions stored with it.
    @discardableResult
    public func undo(_ id: UUID, at date: Date = Date()) throws -> ActivityEntry? {
        guard var entry = try activityEntry(id), entry.canUndo else { return nil }
        switch entry.undo {
        case let .reject(assertionID, invented):
            try reject(assertionID, at: date)
            for id in invented { try forgetIfUnused(id) }
        case let .restore(assertionID):
            guard let assertion = try assertion(assertionID) else { break }
            // Only bring it back if nothing has taken its place since.
            let current = try activeAssertions(subjectID: assertion.subjectID, predicate: assertion.predicate)
            guard current.isEmpty || !isFunctional(assertion.predicate) else { break }
            try db.run(
                """
                UPDATE assertions SET state = 'active', valid_to = NULL, superseded_by = NULL, updated_at = ?2
                WHERE id = ?1;
                """,
                [.text(assertionID.uuidString), .init(date)]
            )
            try rematerialize(subjectID: assertion.subjectID, predicate: assertion.predicate)
        case let .forget(entityID):
            try forgetIfUnused(entityID)
        case .none:
            return nil
        }
        entry.undoneAt = date
        try db.run("UPDATE activity SET undone_at = ?2 WHERE id = ?1;", [.text(id.uuidString), .init(date)])
        return entry
    }

    private func isFunctional(_ predicate: Predicate) -> Bool {
        PredicateCatalog.spec(for: predicate)?.isFunctional ?? false
    }

    static func activityEntry(from row: SQLRow) -> ActivityEntry {
        ActivityEntry(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            kind: ActivityKind(rawValue: row.string(1) ?? "") ?? .learned,
            headline: row.string(2) ?? "",
            detail: row.string(3),
            entityID: row.string(4).flatMap(UUID.init(uuidString:)),
            assertionID: row.string(5).flatMap(UUID.init(uuidString:)),
            undo: row.string(6).flatMap(decodeUndo) ?? .none,
            createdAt: row.date(7) ?? Date(),
            undoneAt: row.date(8)
        )
    }

    private static func encodeUndo(_ undo: UndoAction) -> String? {
        guard undo != .none else { return nil }
        return (try? JSONEncoder().encode(undo)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeUndo(_ json: String) -> UndoAction? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(UndoAction.self, from: $0) }
    }
}
