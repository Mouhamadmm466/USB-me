import Foundation
import Telemetry

public enum IntelligenceStoreError: Error, CustomStringConvertible, Equatable {
    case invalidStatement(String)
    case unknownEntity(UUID)
    case unknownAssertion(UUID)
    case storage(String)

    public var description: String {
        switch self {
        case let .invalidStatement(reason): "invalid statement: \(reason)"
        case let .unknownEntity(id): "no entity \(id)"
        case let .unknownAssertion(id): "no assertion \(id)"
        case let .storage(message): message
        }
    }
}

/// What happened when a statement was written.
public enum AssertionOutcome: Sendable, Equatable {
    /// Written and active. `superseded` lists the statements it replaced.
    case recorded(Assertion, superseded: [Assertion])
    /// The same thing was already known; confidence and provenance were strengthened instead.
    case reinforced(Assertion)
    /// It contradicts something the user said with more authority, so it is stored as `proposed`
    /// and surfaced for a decision rather than silently applied (PRD §12).
    case conflicted(Assertion, existing: Assertion)

    public var assertion: Assertion {
        switch self {
        case let .recorded(assertion, _), let .reinforced(assertion), let .conflicted(assertion, _): assertion
        }
    }

    public var isActive: Bool {
        if case .conflicted = self { return false }
        return true
    }
}

/// How full-text search behaved, so callers can degrade honestly.
public enum SearchMode: String, Sendable, SafeLabelConvertible {
    case fullText
    case prefix
}

public struct IntelligenceCounts: Sendable, Equatable {
    public var entities: [EntityKind: Int]
    public var activeAssertions: Int
    public var proposedAssertions: Int
    public var inferredAssertions: Int
    public var sizeBytes: Int64

    public var totalEntities: Int { entities.values.reduce(0, +) }
}

/// The user's personal intelligence: every entity and every statement about them, with provenance.
///
/// An actor over one SQLite file. All mutation goes through `record(_:)`, which validates against
/// `PredicateCatalog`, resolves conflicts by authority, and materializes the winning values onto
/// entity columns — so the rest of the app can read plain rows while history and "why do you know
/// that?" stay intact underneath.
public actor IntelligenceStore {
    /// Not private: the activity log is a separate file for readability, not a separate owner.
    let db: SQLiteDatabase
    private let logger: PrivacySafeLogger?
    public nonisolated let path: String
    public private(set) var searchMode: SearchMode = .prefix

    /// Opens (creating if needed) the store at `url`, or in memory when `url` is nil.
    public init(url: URL? = nil, logger: PrivacySafeLogger? = nil) throws {
        self.logger = logger
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            path = url.path
        } else {
            path = ":memory:"
        }
        db = try SQLiteDatabase(path: path)
        try db.migrate(IntelligenceSchema.migrations)
        searchMode = try Self.installFullText(db)
        try Self.seedUserEntity(db)
    }

    /// The default on-device location: Application Support, protected until first unlock, backed up
    /// (the knowledge index and model files are not).
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = base.appendingPathComponent("Intelligence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path
        )
        #endif
        return folder.appendingPathComponent("intelligence.sqlite")
    }

    /// Builds (or rebuilds) the full-text layer. Static because `init` runs before actor isolation
    /// is established; it only touches the database handle it is given.
    private static func installFullText(_ db: SQLiteDatabase) throws -> SearchMode {
        guard db.hasFTS5 else { return .prefix }
        let installed = try? db.query("SELECT value FROM meta WHERE key = 'fts_version';").first?.string(0)
        if installed != IntelligenceSchema.fullTextVersion {
            try db.execute(IntelligenceSchema.dropFullText)
            try db.transaction { try db.execute(IntelligenceSchema.fullText) }
            try db.run(
                "INSERT INTO meta(key, value) VALUES ('fts_version', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1;",
                [.text(IntelligenceSchema.fullTextVersion)]
            )
        }
        return .fullText
    }

    /// Every statement about "me" hangs off one fixed person entity.
    private static func seedUserEntity(_ db: SQLiteDatabase) throws {
        let id = IntelligenceIdentity.userEntityID.uuidString
        let now = Date()
        try db.run(
            """
            INSERT OR IGNORE INTO entities (id, kind, title, title_folded, status, importance,
                attributes, created_at, updated_at)
            VALUES (?1, 'person', ?2, ?3, 'active', 1.0, '{}', ?4, ?4);
            """,
            [
                .text(id), .text(IntelligenceIdentity.userTitle),
                .text(IntelligenceIdentity.userTitle.intelligenceFolded), .init(now),
            ]
        )
    }

    // MARK: - Entities

    public func entity(_ id: UUID) throws -> IntelligenceEntity? {
        try db.query("SELECT \(IntelligenceSchema.entityColumns) FROM entities WHERE id = ?1;", [.text(id.uuidString)])
            .first.map(Self.entity(from:))
    }

    public func entities(_ ids: [UUID]) throws -> [IntelligenceEntity] {
        guard !ids.isEmpty else { return [] }
        let placeholders = (1...ids.count).map { "?\($0)" }.joined(separator: ", ")
        let rows = try db.query(
            "SELECT \(IntelligenceSchema.entityColumns) FROM entities WHERE id IN (\(placeholders));",
            ids.map { .text($0.uuidString) }
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map(Self.entity(from:)).map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Entities of a kind, newest activity first. `includeArchived` is off by default so lists stay
    /// about what is live.
    public func entities(
        kind: EntityKind? = nil,
        statuses: [EntityStatus]? = nil,
        projectID: UUID? = nil,
        includeArchived: Bool = false,
        limit: Int = 200
    ) throws -> [IntelligenceEntity] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        if let kind {
            bindings.append(.text(kind.rawValue))
            conditions.append("kind = ?\(bindings.count)")
        }
        if let statuses, !statuses.isEmpty {
            let placeholders = statuses.map { status -> String in
                bindings.append(.text(status.rawValue))
                return "?\(bindings.count)"
            }
            conditions.append("status IN (\(placeholders.joined(separator: ", ")))")
        }
        if let projectID {
            bindings.append(.text(projectID.uuidString))
            conditions.append("project_id = ?\(bindings.count)")
        }
        if !includeArchived { conditions.append("archived_at IS NULL") }
        let filter = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities \(filter)
            ORDER BY importance DESC, updated_at DESC LIMIT \(max(1, limit));
            """,
            bindings
        )
        return rows.map(Self.entity(from:))
    }

    /// Work that is outstanding and dated, for the attention engine and Home.
    public func upcoming(through horizon: Date, limit: Int = 50) throws -> [IntelligenceEntity] {
        let statuses = EntityStatus.allCases.filter(\.isOutstanding).map { SQLValue.text($0.rawValue) }
        guard !statuses.isEmpty else { return [] }
        let placeholders = (2...(statuses.count + 1)).map { "?\($0)" }.joined(separator: ", ")
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE archived_at IS NULL AND status IN (\(placeholders))
              AND (due_at IS NOT NULL AND due_at <= ?1 OR starts_at IS NOT NULL AND starts_at <= ?1)
            ORDER BY COALESCE(due_at, starts_at) ASC LIMIT \(max(1, limit));
            """,
            [.init(horizon)] + statuses
        )
        return rows.map(Self.entity(from:))
    }

    /// Entities whose title or alias is exactly one of `names` (folded). One indexed query, used by
    /// the context builder to link what the user just said to what is already known.
    public func entitiesNamed(_ names: [String]) throws -> [IntelligenceEntity] {
        let folded = Set(names.map(\.intelligenceFolded)).filter { !$0.isEmpty }
        guard !folded.isEmpty else { return [] }
        let bindings = folded.map { SQLValue.text($0) }
        let placeholders = (1...bindings.count).map { "?\($0)" }.joined(separator: ", ")
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE archived_at IS NULL AND (
                title_folded IN (\(placeholders))
                OR id IN (SELECT entity_id FROM entity_aliases WHERE alias_folded IN (\(placeholders)))
            )
            ORDER BY importance DESC, updated_at DESC LIMIT 40;
            """,
            bindings  // the numbered placeholders appear twice; SQLite binds each parameter once
        )
        return rows.map(Self.entity(from:))
    }

    /// Outstanding work dated inside a window, for "what's happening Friday".
    public func entities(between start: Date, and end: Date, limit: Int = 20) throws -> [IntelligenceEntity] {
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE archived_at IS NULL
              AND ((due_at BETWEEN ?1 AND ?2) OR (starts_at BETWEEN ?1 AND ?2))
            ORDER BY COALESCE(due_at, starts_at) ASC LIMIT \(max(1, limit));
            """,
            [.init(start), .init(end)]
        )
        return rows.map(Self.entity(from:))
    }

    @discardableResult
    public func create(
        kind: EntityKind,
        title: String,
        subtitle: String? = nil,
        status: EntityStatus? = nil,
        projectID: UUID? = nil,
        dueAt: Date? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        importance: Double = 0.5,
        attributes: [String: String] = [:]
    ) throws -> IntelligenceEntity {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntelligenceStoreError.invalidStatement("an entity needs a name") }
        let entity = IntelligenceEntity(
            kind: kind, title: trimmed, subtitle: subtitle, status: status, projectID: projectID,
            startsAt: startsAt, endsAt: endsAt, dueAt: dueAt, importance: importance, attributes: attributes
        )
        try insertEntity(entity)
        return entity
    }

    /// Finds an entity the user named. Exact title, then alias, then unique prefix — nothing fuzzier,
    /// because silently attaching a statement to the wrong person is the expensive mistake.
    public func resolve(title: String, kind: EntityKind? = nil) throws -> IntelligenceEntity? {
        let folded = title.intelligenceFolded
        guard !folded.isEmpty else { return nil }
        let kindClause = kind.map { _ in "AND kind = ?2" } ?? ""
        var bindings: [SQLValue] = [.text(folded)]
        if let kind { bindings.append(.text(kind.rawValue)) }

        let exact = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE title_folded = ?1 \(kindClause) ORDER BY importance DESC LIMIT 1;
            """,
            bindings
        )
        if let row = exact.first { return Self.entity(from: row) }

        let aliased = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE id IN (SELECT entity_id FROM entity_aliases WHERE alias_folded = ?1) \(kindClause)
            ORDER BY importance DESC LIMIT 1;
            """,
            bindings
        )
        if let row = aliased.first { return Self.entity(from: row) }

        // A prefix only counts when it is unambiguous ("Sarah" → Sarah Chen, but not when there are two).
        let prefix = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE title_folded LIKE ?1 || '%' \(kindClause) AND archived_at IS NULL LIMIT 2;
            """,
            bindings
        )
        return prefix.count == 1 ? prefix.map(Self.entity(from:)).first : nil
    }

    /// Resolves, or creates the entity if the user is clearly talking about something new.
    public func resolveOrCreate(title: String, kind: EntityKind) throws -> IntelligenceEntity {
        if let found = try resolve(title: title, kind: kind) { return found }
        return try create(kind: kind, title: title)
    }

    /// Writes an entity back. `at` is when the change happened: callers that are replaying history
    /// (an import, a migration, a test) pass the real time rather than now.
    public func update(_ entity: IntelligenceEntity, at date: Date = Date()) throws {
        var entity = entity
        entity.updatedAt = max(date, entity.updatedAt)
        try db.run(
            """
            UPDATE entities SET kind = ?2, title = ?3, title_folded = ?4, subtitle = ?5, status = ?6,
                project_id = ?7, starts_at = ?8, ends_at = ?9, due_at = ?10, importance = ?11,
                attributes = ?12, updated_at = ?13, archived_at = ?14
            WHERE id = ?1;
            """,
            [
                .text(entity.id.uuidString), .text(entity.kind.rawValue), .text(entity.title),
                .text(entity.title.intelligenceFolded), .init(entity.subtitle), .text(entity.status.rawValue),
                .init(entity.projectID?.uuidString), .init(entity.startsAt), .init(entity.endsAt),
                .init(entity.dueAt), .init(entity.importance), .text(Self.encode(entity.attributes)),
                .init(entity.updatedAt), .init(entity.archivedAt),
            ]
        )
        try replaceAliases(entity.aliases, for: entity.id)
    }

    public func archive(_ id: UUID, at date: Date = Date()) throws {
        try db.run("UPDATE entities SET archived_at = ?2, updated_at = ?2 WHERE id = ?1;", [.text(id.uuidString), .init(date)])
    }

    /// Removes an entity and everything said about it. Used by "forget this" and by erasure.
    public func forget(_ id: UUID) throws {
        guard id != IntelligenceIdentity.userEntityID else {
            throw IntelligenceStoreError.invalidStatement("the user entity cannot be deleted")
        }
        try db.transaction {
            try db.run("DELETE FROM assertions WHERE subject_id = ?1 OR object_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM entities WHERE id = ?1;", [.text(id.uuidString)])
        }
    }

    // MARK: - Statements

    /// Writes one statement, resolving it against what is already known.
    ///
    /// Validates the shape against `PredicateCatalog`; reinforces an identical statement instead of
    /// duplicating it; supersedes the previous value of a functional predicate when authority allows;
    /// stores a contradiction of something more authoritative as `proposed` for the user to settle.
    @discardableResult
    public func record(_ assertion: Assertion) throws -> AssertionOutcome {
        guard let subject = try entity(assertion.subjectID) else {
            throw IntelligenceStoreError.unknownEntity(assertion.subjectID)
        }
        let object = try assertion.objectID.flatMap { try entity($0) }
        if let objectID = assertion.objectID, object == nil { throw IntelligenceStoreError.unknownEntity(objectID) }
        guard let spec = PredicateCatalog.spec(for: assertion.predicate) else {
            throw IntelligenceStoreError.invalidStatement("unknown predicate \(assertion.predicate)")
        }
        if let violation = PredicateCatalog.violation(
            predicate: assertion.predicate, subjectKind: subject.kind, objectKind: object?.kind, value: assertion.value
        ) {
            throw IntelligenceStoreError.invalidStatement(violation)
        }

        let existing = try activeAssertions(subjectID: assertion.subjectID, predicate: assertion.predicate)

        if let duplicate = existing.first(where: { Self.sameStatement($0, assertion) }) {
            return .reinforced(try reinforce(duplicate, with: assertion))
        }

        // Only functional predicates displace anything; set-valued ones accumulate.
        let challenged = spec.isFunctional ? existing : []
        if let blocker = challenged.first(where: { assertion.authority < $0.authority }) {
            var proposed = assertion
            proposed.state = .proposed
            try db.transaction { try insert(proposed) }
            logger?.log(.counter(name: "intelligence.conflict", value: 1))
            return .conflicted(proposed, existing: blocker)
        }

        var stored = assertion
        stored.state = .active
        var replaced: [Assertion] = []
        try db.transaction {
            try insert(stored)
            for previous in challenged {
                try close(previous, state: .superseded, by: stored.id, at: stored.validFrom)
                replaced.append(previous)
            }
            try materialize(spec: spec, assertion: stored, subject: subject)
        }
        logger?.log(.counter(name: "intelligence.assertion", value: 1))
        return .recorded(stored, superseded: replaced)
    }

    /// Convenience for the common shapes, so callers do not assemble `Assertion` by hand.
    @discardableResult
    public func record(
        subject: UUID,
        _ predicate: Predicate,
        object: UUID? = nil,
        value: AssertionValue? = nil,
        type: MemoryType = .explicit,
        authority: Authority? = nil,
        confidence: Double = 0.9,
        provenance: Provenance,
        expiresAt: Date? = nil,
        at date: Date = Date()
    ) throws -> AssertionOutcome {
        try record(Assertion(
            subjectID: subject, predicate: predicate, objectID: object, value: value, type: type,
            authority: authority, confidence: confidence, provenance: provenance,
            validFrom: date, expiresAt: expiresAt, createdAt: date, updatedAt: date
        ))
    }

    /// Writes a statement the user has not agreed to yet: validated, but inert until `confirm`.
    /// Nothing is materialized and nothing is superseded — a question cannot change the world.
    @discardableResult
    public func propose(_ assertion: Assertion) throws -> Assertion {
        guard let subject = try entity(assertion.subjectID) else {
            throw IntelligenceStoreError.unknownEntity(assertion.subjectID)
        }
        let object = try assertion.objectID.flatMap { try entity($0) }
        if let objectID = assertion.objectID, object == nil { throw IntelligenceStoreError.unknownEntity(objectID) }
        if let violation = PredicateCatalog.violation(
            predicate: assertion.predicate, subjectKind: subject.kind, objectKind: object?.kind, value: assertion.value
        ) {
            throw IntelligenceStoreError.invalidStatement(violation)
        }
        var proposed = assertion
        proposed.state = .proposed
        try insert(proposed)
        return proposed
    }

    /// Deletes an entity nothing refers to. Used when a statement that invented an entity is
    /// rejected, so a declined suggestion does not leave debris in the user's world.
    ///
    /// Rejected statements do not count as references: they are the record of a refusal, and an
    /// entity that exists only inside one is a thing the user said was not there.
    @discardableResult
    public func forgetIfUnused(_ id: UUID) throws -> Bool {
        guard id != IntelligenceIdentity.userEntityID else { return false }
        let referenced = try db.query(
            """
            SELECT
                (SELECT COUNT(*) FROM assertions
                 WHERE (subject_id = ?1 OR object_id = ?1) AND state != 'rejected') +
                (SELECT COUNT(*) FROM entities WHERE project_id = ?1);
            """,
            [.text(id.uuidString)]
        ).first?.int(0) ?? 0
        guard referenced == 0 else { return false }
        return try db.run("DELETE FROM entities WHERE id = ?1;", [.text(id.uuidString)]) > 0
    }

    public func assertion(_ id: UUID) throws -> Assertion? {
        try db.query("SELECT \(IntelligenceSchema.assertionColumns) FROM assertions WHERE id = ?1;", [.text(id.uuidString)])
            .first.map(Self.assertion(from:))
    }

    /// Everything currently held about an entity, as subject and (optionally) as object.
    public func assertions(
        about id: UUID,
        includeIncoming: Bool = true,
        states: [AssertionState] = [.active],
        limit: Int = 200
    ) throws -> [Assertion] {
        var bindings: [SQLValue] = [.text(id.uuidString)]
        let statePlaceholders = states.map { state -> String in
            bindings.append(.text(state.rawValue))
            return "?\(bindings.count)"
        }.joined(separator: ", ")
        let subjectClause = includeIncoming ? "(subject_id = ?1 OR object_id = ?1)" : "subject_id = ?1"
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.assertionColumns) FROM assertions
            WHERE \(subjectClause) AND state IN (\(statePlaceholders))
            ORDER BY authority DESC, valid_from DESC LIMIT \(max(1, limit));
            """,
            bindings
        )
        return rows.map(Self.assertion(from:))
    }

    public func activeAssertions(subjectID: UUID, predicate: Predicate? = nil) throws -> [Assertion] {
        var bindings: [SQLValue] = [.text(subjectID.uuidString)]
        var clause = "subject_id = ?1 AND state = 'active'"
        if let predicate {
            bindings.append(.text(predicate.rawValue))
            clause += " AND predicate = ?2"
        }
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.assertionColumns) FROM assertions WHERE \(clause)
            ORDER BY authority DESC, user_confirmed DESC, valid_from DESC;
            """,
            bindings
        )
        return rows.map(Self.assertion(from:))
    }

    /// Statements waiting on the user: inferences to confirm and conflicts to settle.
    public func pendingAssertions(limit: Int = 50) throws -> [Assertion] {
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.assertionColumns) FROM assertions
            WHERE state = 'proposed' ORDER BY importance DESC, created_at DESC LIMIT \(max(1, limit));
            """
        )
        return rows.map(Self.assertion(from:))
    }

    /// The user says yes: the statement becomes active, gains correction authority, and takes over
    /// from whatever it contradicted.
    @discardableResult
    public func confirm(_ id: UUID, at date: Date = Date()) throws -> Assertion {
        guard var assertion = try assertion(id) else { throw IntelligenceStoreError.unknownAssertion(id) }
        guard let subject = try entity(assertion.subjectID), let spec = PredicateCatalog.spec(for: assertion.predicate) else {
            throw IntelligenceStoreError.unknownEntity(assertion.subjectID)
        }
        assertion.state = .active
        assertion.userConfirmed = true
        assertion.authority = max(assertion.authority, .userCorrection)
        assertion.confidence = 1
        assertion.updatedAt = date
        try db.transaction {
            try save(assertion)
            if spec.isFunctional {
                for previous in try activeAssertions(subjectID: assertion.subjectID, predicate: assertion.predicate)
                where previous.id != assertion.id {
                    try close(previous, state: .superseded, by: assertion.id, at: date)
                }
            }
            try materialize(spec: spec, assertion: assertion, subject: subject)
        }
        return assertion
    }

    /// The user says no. The statement is kept as rejected — so the same inference is not proposed
    /// again — and whatever it displaced is restored.
    public func reject(_ id: UUID, at date: Date = Date()) throws {
        guard let assertion = try assertion(id) else { throw IntelligenceStoreError.unknownAssertion(id) }
        try db.transaction {
            try close(assertion, state: .rejected, by: nil, at: date)
            try restoreSuperseded(by: assertion.id, at: date)
            try rematerialize(subjectID: assertion.subjectID, predicate: assertion.predicate)
        }
    }

    /// "That's not true anymore." The statement stops being current but stays in history with its
    /// validity window, which is what makes "what changed?" answerable.
    public func end(_ id: UUID, at date: Date = Date()) throws {
        guard let assertion = try assertion(id) else { throw IntelligenceStoreError.unknownAssertion(id) }
        try db.transaction {
            try close(assertion, state: .ended, by: nil, at: date)
            try rematerialize(subjectID: assertion.subjectID, predicate: assertion.predicate)
        }
    }

    /// A correction: end the old statement and write the new one with correction authority, keeping
    /// both rows so the change is explainable.
    @discardableResult
    public func correct(_ id: UUID, with replacement: Assertion, at date: Date = Date()) throws -> AssertionOutcome {
        guard let previous = try assertion(id) else { throw IntelligenceStoreError.unknownAssertion(id) }
        var corrected = replacement
        corrected.authority = max(replacement.authority, .userCorrection)
        corrected.type = .explicit
        corrected.validFrom = date
        try close(previous, state: .superseded, by: corrected.id, at: date)
        do {
            return try record(corrected)
        } catch {
            // The replacement was rejected by validation — put the original back rather than
            // leaving the user with nothing.
            _ = try? db.run(
                "UPDATE assertions SET state = 'active', superseded_by = NULL, valid_to = NULL WHERE id = ?1;",
                [.text(previous.id.uuidString)]
            )
            throw error
        }
    }

    /// Marks statements whose time has passed ("until Friday"). Called on launch and after sleep.
    @discardableResult
    public func expire(now: Date = Date()) throws -> Int {
        let expiring = try db.query(
            """
            SELECT \(IntelligenceSchema.assertionColumns) FROM assertions
            WHERE state = 'active' AND expires_at IS NOT NULL AND expires_at <= ?1;
            """,
            [.init(now)]
        ).map(Self.assertion(from:))
        guard !expiring.isEmpty else { return 0 }
        try db.transaction {
            for assertion in expiring {
                try close(assertion, state: .expired, by: nil, at: now)
                try rematerialize(subjectID: assertion.subjectID, predicate: assertion.predicate)
            }
        }
        return expiring.count
    }

    // MARK: - Search

    /// Finds entities by name, alias or the text of what is known about them.
    public func search(_ text: String, kinds: [EntityKind] = [], limit: Int = 20) throws -> [IntelligenceEntity] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var ids: [UUID] = []
        if searchMode == .fullText, let query = Self.ftsQuery(trimmed) {
            let rows = try db.query(
                """
                SELECT entity_id FROM entities_fts WHERE text MATCH ?1 ORDER BY rank LIMIT ?2
                """,
                [.text(query), .init(limit * 2)]
            )
            ids = rows.compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
            let viaAssertions = try db.query(
                "SELECT subject_id FROM assertions_fts WHERE text MATCH ?1 ORDER BY rank LIMIT ?2;",
                [.text(query), .init(limit)]
            )
            ids += viaAssertions.compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
        } else {
            let folded = trimmed.intelligenceFolded
            let rows = try db.query(
                """
                SELECT id FROM entities WHERE title_folded LIKE '%' || ?1 || '%'
                UNION SELECT entity_id FROM entity_aliases WHERE alias_folded LIKE '%' || ?1 || '%'
                LIMIT ?2;
                """,
                [.text(folded), .init(limit * 2)]
            )
            ids = rows.compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
        }
        var seen = Set<UUID>()
        let ordered = ids.filter { seen.insert($0).inserted }
        return try entities(Array(ordered.prefix(limit)))
    }

    /// FTS5 MATCH expression. Every word must match (search-as-you-type semantics, so more typing
    /// narrows rather than widens), the last one as a prefix; each is quoted so punctuation in what
    /// the user typed can never reach the FTS parser as syntax.
    private static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(8)
        guard !words.isEmpty else { return nil }
        return words.enumerated()
            .map { index, word in index == words.count - 1 ? "\"\(word)\"*" : "\"\(word)\"" }
            .joined(separator: " AND ")
    }

    // MARK: - Maintenance, export, erasure

    public func counts() throws -> IntelligenceCounts {
        var byKind: [EntityKind: Int] = [:]
        for row in try db.query("SELECT kind, COUNT(*) FROM entities GROUP BY kind;") {
            if let kind = row.string(0).flatMap(EntityKind.init(rawValue:)) { byKind[kind] = Int(row.int(1) ?? 0) }
        }
        func count(_ clause: String) throws -> Int {
            Int(try db.query("SELECT COUNT(*) FROM assertions WHERE \(clause);").first?.int(0) ?? 0)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64) ?? 0
        return IntelligenceCounts(
            entities: byKind,
            activeAssertions: try count("state = 'active'"),
            proposedAssertions: try count("state = 'proposed'"),
            inferredAssertions: try count("state = 'active' AND type = 'inferred'"),
            sizeBytes: size
        )
    }

    /// Everything, as JSON the user can read and keep. Nothing is omitted — an export the user
    /// cannot verify is not an export.
    public func export() throws -> Data {
        let entities = try allEntities()
        let assertions = try db.query("SELECT \(IntelligenceSchema.assertionColumns) FROM assertions;")
            .map(Self.assertion(from:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(IntelligenceExport(
            exportedAt: Date(), schemaVersion: Int(IntelligenceSchema.currentVersion),
            entities: entities, assertions: assertions
        ))
    }

    /// Erases everything. Used by "Delete all data" and before an import.
    public func deleteEverything() throws {
        try db.transaction {
            try db.run("DELETE FROM assertions;")
            try db.run("DELETE FROM entities;")
        }
        try db.execute("VACUUM;")
        try Self.seedUserEntity(db)
    }

    // MARK: - Private: writing

    func insertEntity(_ entity: IntelligenceEntity) throws {
        try db.run(
            """
            INSERT INTO entities (id, kind, title, title_folded, subtitle, status, project_id,
                starts_at, ends_at, due_at, importance, attributes, created_at, updated_at, archived_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
            """,
            [
                .text(entity.id.uuidString), .text(entity.kind.rawValue), .text(entity.title),
                .text(entity.title.intelligenceFolded), .init(entity.subtitle), .text(entity.status.rawValue),
                .init(entity.projectID?.uuidString), .init(entity.startsAt), .init(entity.endsAt),
                .init(entity.dueAt), .init(entity.importance), .text(Self.encode(entity.attributes)),
                .init(entity.createdAt), .init(entity.updatedAt), .init(entity.archivedAt),
            ]
        )
        try replaceAliases(entity.aliases, for: entity.id)
    }

    private func replaceAliases(_ aliases: [String], for id: UUID) throws {
        try db.run("DELETE FROM entity_aliases WHERE entity_id = ?1;", [.text(id.uuidString)])
        for alias in Set(aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !alias.isEmpty {
            try db.run(
                "INSERT OR IGNORE INTO entity_aliases (entity_id, alias, alias_folded) VALUES (?1, ?2, ?3);",
                [.text(id.uuidString), .text(alias), .text(alias.intelligenceFolded)]
            )
        }
    }

    private func insert(_ assertion: Assertion) throws {
        let kind: AssertionKind = assertion.isRelationship ? .relationship : .attribute
        try db.run(
            """
            INSERT INTO assertions (id, subject_id, predicate, object_id, value, value_text, value_number,
                value_date, kind, type, authority, confidence, importance, user_confirmed, state,
                superseded_by, source_type, source_id, source_excerpt, valid_from, valid_to, expires_at,
                created_at, updated_at, last_accessed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18,
                ?19, ?20, ?21, ?22, ?23, ?24, ?25);
            """,
            bindings(for: assertion, kind: kind)
        )
    }

    private func save(_ assertion: Assertion) throws {
        try db.run(
            """
            UPDATE assertions SET value = ?5, value_text = ?6, value_number = ?7, value_date = ?8,
                type = ?10, authority = ?11, confidence = ?12, importance = ?13, user_confirmed = ?14,
                state = ?15, superseded_by = ?16, valid_from = ?20, valid_to = ?21, expires_at = ?22,
                updated_at = ?24, last_accessed_at = ?25
            WHERE id = ?1;
            """,
            bindings(for: assertion, kind: assertion.isRelationship ? .relationship : .attribute)
        )
    }

    private func bindings(for assertion: Assertion, kind: AssertionKind) -> [SQLValue] {
        [
            .text(assertion.id.uuidString), .text(assertion.subjectID.uuidString),
            .text(assertion.predicate.rawValue), .init(assertion.objectID?.uuidString),
            .init(assertion.value.map(Self.encode)), .init(assertion.value?.textValue),
            .init(assertion.value.flatMap { if case let .number(number) = $0 { number } else { nil } }),
            .init(assertion.value?.dateValue),
            .text(kind.rawValue), .text(assertion.type.rawValue), .init(assertion.authority.rawValue),
            .init(assertion.confidence), .init(assertion.importance), .init(assertion.userConfirmed),
            .text(assertion.state.rawValue), .init(assertion.supersededBy?.uuidString),
            .text(assertion.provenance.sourceType.rawValue), .init(assertion.provenance.sourceID),
            .init(assertion.provenance.excerpt), .init(assertion.validFrom), .init(assertion.validTo),
            .init(assertion.expiresAt), .init(assertion.createdAt), .init(assertion.updatedAt),
            .init(assertion.lastAccessedAt),
        ]
    }

    private func close(_ assertion: Assertion, state: AssertionState, by supersededBy: UUID?, at date: Date) throws {
        try db.run(
            """
            UPDATE assertions SET state = ?2, superseded_by = ?3, valid_to = COALESCE(valid_to, ?4), updated_at = ?4
            WHERE id = ?1;
            """,
            [.text(assertion.id.uuidString), .text(state.rawValue), .init(supersededBy?.uuidString), .init(date)]
        )
    }

    /// Brings back statements a now-rejected one had displaced.
    private func restoreSuperseded(by id: UUID, at date: Date) throws {
        try db.run(
            """
            UPDATE assertions SET state = 'active', superseded_by = NULL, valid_to = NULL, updated_at = ?2
            WHERE superseded_by = ?1 AND state = 'superseded';
            """,
            [.text(id.uuidString), .init(date)]
        )
    }

    private func reinforce(_ existing: Assertion, with incoming: Assertion) throws -> Assertion {
        var merged = existing
        merged.confidence = min(1, max(existing.confidence, incoming.confidence) + 0.05)
        merged.updatedAt = incoming.updatedAt
        merged.lastAccessedAt = incoming.updatedAt
        if incoming.authority > existing.authority {
            merged.authority = incoming.authority
            merged.type = incoming.type
            merged.provenance = incoming.provenance
        }
        merged.userConfirmed = existing.userConfirmed || incoming.userConfirmed
        if let expiry = incoming.expiresAt { merged.expiresAt = expiry }
        try save(merged)
        return merged
    }

    private static func sameStatement(_ lhs: Assertion, _ rhs: Assertion) -> Bool {
        guard lhs.predicate == rhs.predicate, lhs.objectID == rhs.objectID else { return false }
        switch (lhs.value, rhs.value) {
        case (nil, nil): return true
        case let (.date(left, _)?, .date(right, _)?): return abs(left.timeIntervalSince(right)) < 60
        case let (.text(left)?, .text(right)?): return left.intelligenceFolded == right.intelligenceFolded
        case let (left?, right?): return left == right
        default: return false
        }
    }

    // MARK: - Private: materialization

    /// Copies a winning statement onto the entity column it owns, so ordinary queries (due today,
    /// tasks in this project, this person's role) never have to walk the assertion log.
    private func materialize(spec: PredicateSpec, assertion: Assertion, subject: IntelligenceEntity) throws {
        guard let field = spec.materializes else { return }
        var entity = subject
        switch field {
        case .dueAt: entity.dueAt = assertion.value?.dateValue
        case .startsAt: entity.startsAt = assertion.value?.dateValue
        case .endsAt: entity.endsAt = assertion.value?.dateValue
        case .status:
            // Legality was checked by `PredicateCatalog.violation`; a row that predates a vocabulary
            // change is left alone rather than forced into a status its kind no longer has.
            guard let raw = assertion.value?.textValue, let status = EntityStatus(rawValue: raw),
                  entity.kind.statuses.contains(status) else { return }
            entity.status = status
        case .subtitle: entity.subtitle = assertion.value?.textValue
        case .projectID: entity.projectID = assertion.objectID
        case .importance: entity.importance = assertion.value.flatMap { if case let .number(n) = $0 { n } else { nil } } ?? entity.importance
        case .progress:
            if case let .number(progress)? = assertion.value {
                entity.attributes["progress"] = String(format: "%.2f", progress)
            }
        case .aliases:
            if let alias = assertion.value?.textValue, !entity.aliases.contains(alias) { entity.aliases.append(alias) }
        }
        try update(entity)
    }

    /// Recomputes a materialized field after the statement that owned it was ended or rejected:
    /// the next winning statement takes over, or the field resets.
    func rematerialize(subjectID: UUID, predicate: Predicate) throws {
        guard let spec = PredicateCatalog.spec(for: predicate), let field = spec.materializes,
              var entity = try entity(subjectID) else { return }
        let winner = try activeAssertions(subjectID: subjectID, predicate: predicate).first
        if let winner {
            try materialize(spec: spec, assertion: winner, subject: entity)
            return
        }
        switch field {
        case .dueAt: entity.dueAt = nil
        case .startsAt: entity.startsAt = nil
        case .endsAt: entity.endsAt = nil
        case .status: entity.status = entity.kind.statuses.first ?? .active
        case .subtitle: entity.subtitle = nil
        case .projectID: entity.projectID = nil
        case .importance: entity.importance = 0.5
        case .progress: entity.attributes["progress"] = nil
        case .aliases: break  // aliases accumulate; ending one statement does not unname someone
        }
        try update(entity)
    }

    // MARK: - Private: row mapping

    private func allEntities() throws -> [IntelligenceEntity] {
        try db.query("SELECT \(IntelligenceSchema.entityColumns) FROM entities ORDER BY created_at;")
            .map(Self.entity(from:))
    }

    private static func entity(from row: SQLRow) -> IntelligenceEntity {
        IntelligenceEntity(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            kind: EntityKind(rawValue: row.string(1) ?? "") ?? .document,
            title: row.string(2) ?? "",
            subtitle: row.string(3),
            status: EntityStatus(rawValue: row.string(4) ?? "") ?? .active,
            aliases: row.string(14).map { $0.split(separator: "\u{1F}").map(String.init) } ?? [],
            projectID: row.string(5).flatMap(UUID.init(uuidString:)),
            startsAt: row.date(6), endsAt: row.date(7), dueAt: row.date(8),
            importance: row.double(9) ?? 0.5,
            attributes: decodeAttributes(row.string(10)),
            createdAt: row.date(11) ?? Date(), updatedAt: row.date(12) ?? Date(), archivedAt: row.date(13)
        )
    }

    private static func assertion(from row: SQLRow) -> Assertion {
        Assertion(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            subjectID: UUID(uuidString: row.string(1) ?? "") ?? IntelligenceIdentity.userEntityID,
            predicate: Predicate(row.string(2) ?? ""),
            objectID: row.string(3).flatMap(UUID.init(uuidString:)),
            value: row.string(4).flatMap(decodeValue),
            type: MemoryType(rawValue: row.string(6) ?? "") ?? .explicit,
            authority: Authority(rawValue: Int(row.int(7) ?? 4)) ?? .userStatement,
            confidence: row.double(8) ?? 0.9,
            importance: row.double(9) ?? 0.5,
            userConfirmed: row.bool(10),
            state: AssertionState(rawValue: row.string(11) ?? "") ?? .active,
            supersededBy: row.string(12).flatMap(UUID.init(uuidString:)),
            provenance: Provenance(
                sourceType: SourceType(rawValue: row.string(13) ?? "") ?? .system,
                sourceID: row.string(14), excerpt: row.string(15)
            ),
            validFrom: row.date(16) ?? Date(), validTo: row.date(17), expiresAt: row.date(18),
            createdAt: row.date(19) ?? Date(), updatedAt: row.date(20) ?? Date(), lastAccessedAt: row.date(21)
        )
    }

    private static func encode(_ value: AssertionValue) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decodeValue(_ json: String) -> AssertionValue? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(AssertionValue.self, from: $0) }
    }

    private static func encode(_ attributes: [String: String]) -> String {
        (try? JSONEncoder().encode(attributes)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decodeAttributes(_ json: String?) -> [String: String] {
        json?.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}

/// The shape of "export everything", also used by tests as a stable snapshot.
public struct IntelligenceExport: Codable, Sendable {
    public var exportedAt: Date
    public var schemaVersion: Int
    public var entities: [IntelligenceEntity]
    public var assertions: [Assertion]
}
