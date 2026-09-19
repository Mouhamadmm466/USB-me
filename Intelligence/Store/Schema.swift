import Foundation

/// The on-disk shape of the personal intelligence.
///
/// Migrations are append-only: each element of `migrations` is one version, applied in a
/// transaction, tracked by SQLite's `user_version`. Never edit a shipped migration — add another.
/// Full-text tables are created separately (`installFullText`) because a SQLite build without FTS5
/// must still open the database and fall back to prefix matching.
enum IntelligenceSchema {
    /// Index 0 is schema version 1.
    static let migrations: [String] = [v1, v2, v3, v4, v5]

    static var currentVersion: Int32 { Int32(migrations.count) }

    // MARK: - v1: entities, aliases, assertions

    private static let v1 = """
    CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE entities (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        title_folded TEXT NOT NULL,
        subtitle TEXT,
        status TEXT NOT NULL,
        project_id TEXT REFERENCES entities(id) ON DELETE SET NULL,
        starts_at REAL,
        ends_at REAL,
        due_at REAL,
        importance REAL NOT NULL DEFAULT 0.5,
        attributes TEXT NOT NULL DEFAULT '{}',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        archived_at REAL
    );

    CREATE INDEX entities_kind_status ON entities(kind, status, archived_at);
    CREATE INDEX entities_project ON entities(project_id);
    CREATE INDEX entities_due ON entities(due_at) WHERE due_at IS NOT NULL;
    CREATE INDEX entities_starts ON entities(starts_at) WHERE starts_at IS NOT NULL;
    CREATE INDEX entities_title_folded ON entities(title_folded);

    -- Other names an entity answers to. Kept as rows (not JSON) so resolution is one indexed lookup.
    CREATE TABLE entity_aliases (
        entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        alias TEXT NOT NULL,
        alias_folded TEXT NOT NULL,
        PRIMARY KEY (entity_id, alias_folded)
    ) WITHOUT ROWID;

    CREATE INDEX entity_aliases_folded ON entity_aliases(alias_folded);

    -- Every statement the system holds. Entity columns above are a materialized view of the
    -- currently winning rows here; this table is the truth, with provenance and history.
    CREATE TABLE assertions (
        id TEXT PRIMARY KEY,
        subject_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        predicate TEXT NOT NULL,
        object_id TEXT REFERENCES entities(id) ON DELETE CASCADE,
        value TEXT,
        value_text TEXT,
        value_number REAL,
        value_date REAL,
        kind TEXT NOT NULL,
        type TEXT NOT NULL,
        authority INTEGER NOT NULL,
        confidence REAL NOT NULL,
        importance REAL NOT NULL,
        user_confirmed INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        superseded_by TEXT,
        source_type TEXT NOT NULL,
        source_id TEXT,
        source_excerpt TEXT,
        valid_from REAL NOT NULL,
        valid_to REAL,
        expires_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        last_accessed_at REAL
    );

    CREATE INDEX assertions_subject ON assertions(subject_id, state, predicate);
    CREATE INDEX assertions_object ON assertions(object_id, state) WHERE object_id IS NOT NULL;
    CREATE INDEX assertions_predicate ON assertions(predicate, state);
    CREATE INDEX assertions_pending ON assertions(state, created_at);
    CREATE INDEX assertions_expiry ON assertions(expires_at) WHERE expires_at IS NOT NULL;
    """

    // MARK: - v2: the activity log

    private static let v2 = """
    CREATE TABLE activity (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        headline TEXT NOT NULL,
        detail TEXT,
        entity_id TEXT,
        assertion_id TEXT,
        undo TEXT,
        created_at REAL NOT NULL,
        undone_at REAL
    );

    CREATE INDEX activity_created ON activity(created_at);
    CREATE INDEX activity_entity ON activity(entity_id) WHERE entity_id IS NOT NULL;
    CREATE INDEX activity_assertion ON activity(assertion_id) WHERE assertion_id IS NOT NULL;
    """

    /// Columns of `activity`, in the order every read selects them.
    static let activityColumns = """
    id, kind, headline, detail, entity_id, assertion_id, undo, created_at, undone_at
    """

    // MARK: - v3: documents and their passages

    private static let v3 = """
    CREATE TABLE documents (
        id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        origin TEXT NOT NULL,
        source_id TEXT,
        media_type TEXT,
        bytes INTEGER NOT NULL DEFAULT 0,
        page_count INTEGER,
        content_hash TEXT NOT NULL,
        imported_at REAL NOT NULL
    );

    CREATE INDEX documents_hash ON documents(content_hash);
    CREATE INDEX documents_imported ON documents(imported_at);

    CREATE TABLE chunks (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        heading TEXT,
        page INTEGER,
        text TEXT NOT NULL,
        characters INTEGER NOT NULL
    );

    CREATE INDEX chunks_document ON chunks(document_id, ordinal);
    """

    /// Columns of `documents`, in the order every read selects them.
    static let documentColumns = """
    id, title, origin, source_id, media_type, bytes, page_count, content_hash, imported_at, \
    (SELECT COUNT(*) FROM chunks WHERE document_id = documents.id)
    """

    static let chunkColumns = "id, document_id, ordinal, heading, page, text"

    // MARK: - v4: plans and their steps

    private static let v4 = """
    CREATE TABLE plans (
        id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
        request TEXT NOT NULL,
        title TEXT NOT NULL,
        subject_id TEXT,
        state TEXT NOT NULL,
        blocker TEXT,
        scope TEXT NOT NULL,
        step_budget INTEGER NOT NULL,
        summary TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        started_at REAL,
        finished_at REAL
    );

    CREATE INDEX plans_state ON plans(state, updated_at);
    CREATE INDEX plans_subject ON plans(subject_id) WHERE subject_id IS NOT NULL;

    CREATE TABLE plan_steps (
        id TEXT PRIMARY KEY,
        plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        capability TEXT NOT NULL,
        summary TEXT NOT NULL,
        arguments TEXT NOT NULL,
        depends_on TEXT NOT NULL,
        requires_network INTEGER NOT NULL,
        risk INTEGER NOT NULL,
        state TEXT NOT NULL,
        blocker TEXT,
        observation TEXT,
        started_at REAL,
        finished_at REAL,
        attempts INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX plan_steps_plan ON plan_steps(plan_id, ordinal);
    """

    static let planColumns = """
    id, request, title, subject_id, state, blocker, scope, step_budget, summary, \
    created_at, updated_at, started_at, finished_at
    """

    static let planStepColumns = """
    id, plan_id, ordinal, capability, summary, arguments, depends_on, requires_network, risk, \
    state, blocker, observation, started_at, finished_at, attempts
    """

    // MARK: - v5: artifacts

    private static let v5 = """
    CREATE TABLE artifacts (
        id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        markdown TEXT NOT NULL,
        version INTEGER NOT NULL,
        plan_id TEXT,
        subject_id TEXT,
        sources TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE INDEX artifacts_updated ON artifacts(updated_at);
    CREATE INDEX artifacts_subject ON artifacts(subject_id) WHERE subject_id IS NOT NULL;

    CREATE TABLE artifact_versions (
        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
        version INTEGER NOT NULL,
        markdown TEXT NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (artifact_id, version)
    ) WITHOUT ROWID;
    """

    static let artifactColumns = """
    id, title, kind, markdown, version, plan_id, subject_id, sources, created_at, updated_at
    """

    // MARK: - Full text

    /// Version of the FTS layer, stored in `meta` so it can be rebuilt independently of migrations.
    static let fullTextVersion = "2"

    /// Creates the FTS5 tables and the triggers that keep them in step, then backfills. Safe to call
    /// on every launch: it is a no-op once `meta.fts_version` matches.
    static let fullText = """
    CREATE VIRTUAL TABLE entities_fts USING fts5(
        entity_id UNINDEXED,
        text,
        tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE VIRTUAL TABLE assertions_fts USING fts5(
        assertion_id UNINDEXED,
        subject_id UNINDEXED,
        text,
        tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE VIRTUAL TABLE chunks_fts USING fts5(
        chunk_id UNINDEXED,
        document_id UNINDEXED,
        text,
        tokenize = 'porter unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER chunks_fts_insert AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(chunk_id, document_id, text) VALUES (new.id, new.document_id, new.text);
    END;

    CREATE TRIGGER chunks_fts_delete AFTER DELETE ON chunks BEGIN
        DELETE FROM chunks_fts WHERE chunk_id = old.id;
    END;

    CREATE TRIGGER entities_fts_insert AFTER INSERT ON entities BEGIN
        INSERT INTO entities_fts(entity_id, text)
        VALUES (new.id, new.title || ' ' || COALESCE(new.subtitle, ''));
    END;

    CREATE TRIGGER entities_fts_update AFTER UPDATE OF title, subtitle ON entities BEGIN
        DELETE FROM entities_fts WHERE entity_id = old.id;
        INSERT INTO entities_fts(entity_id, text)
        VALUES (new.id, new.title || ' ' || COALESCE(new.subtitle, ''));
    END;

    CREATE TRIGGER entities_fts_delete AFTER DELETE ON entities BEGIN
        DELETE FROM entities_fts WHERE entity_id = old.id;
        DELETE FROM assertions_fts WHERE subject_id = old.id;
    END;

    CREATE TRIGGER alias_fts_insert AFTER INSERT ON entity_aliases BEGIN
        INSERT INTO entities_fts(entity_id, text) VALUES (new.entity_id, new.alias);
    END;

    CREATE TRIGGER assertions_fts_insert AFTER INSERT ON assertions
    WHEN new.value_text IS NOT NULL BEGIN
        INSERT INTO assertions_fts(assertion_id, subject_id, text)
        VALUES (new.id, new.subject_id, new.value_text);
    END;

    CREATE TRIGGER assertions_fts_delete AFTER DELETE ON assertions BEGIN
        DELETE FROM assertions_fts WHERE assertion_id = old.id;
    END;

    INSERT INTO entities_fts(entity_id, text)
        SELECT id, title || ' ' || COALESCE(subtitle, '') FROM entities;
    INSERT INTO entities_fts(entity_id, text) SELECT entity_id, alias FROM entity_aliases;
    INSERT INTO assertions_fts(assertion_id, subject_id, text)
        SELECT id, subject_id, value_text FROM assertions WHERE value_text IS NOT NULL;
    INSERT INTO chunks_fts(chunk_id, document_id, text) SELECT id, document_id, text FROM chunks;
    """

    static let dropFullText = """
    DROP TRIGGER IF EXISTS entities_fts_insert;
    DROP TRIGGER IF EXISTS entities_fts_update;
    DROP TRIGGER IF EXISTS entities_fts_delete;
    DROP TRIGGER IF EXISTS alias_fts_insert;
    DROP TRIGGER IF EXISTS assertions_fts_insert;
    DROP TRIGGER IF EXISTS assertions_fts_delete;
    DROP TRIGGER IF EXISTS chunks_fts_insert;
    DROP TRIGGER IF EXISTS chunks_fts_delete;
    DROP TABLE IF EXISTS entities_fts;
    DROP TABLE IF EXISTS assertions_fts;
    DROP TABLE IF EXISTS chunks_fts;
    """

    /// Columns of `entities`, in the order every entity read selects them.
    static let entityColumns = """
    id, kind, title, subtitle, status, project_id, starts_at, ends_at, due_at, importance, \
    attributes, created_at, updated_at, archived_at, \
    (SELECT group_concat(alias, char(31)) FROM entity_aliases WHERE entity_id = entities.id)
    """

    /// Columns of `assertions`, in the order every assertion read selects them.
    static let assertionColumns = """
    id, subject_id, predicate, object_id, value, kind, type, authority, confidence, importance, \
    user_confirmed, state, superseded_by, source_type, source_id, source_excerpt, \
    valid_from, valid_to, expires_at, created_at, updated_at, last_accessed_at
    """
}

extension String {
    /// Case- and accent-insensitive form used for matching titles and aliases ("Sarah" ≡ "sarah").
    var intelligenceFolded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
