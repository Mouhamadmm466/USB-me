import Foundation
import Telemetry

/// Brings in what the user's own phone already knows — their calendar, their reminders — under
/// rules that keep it from becoming surveillance.
///
/// Four of them, and they are the whole difference:
///
/// 1. **Observation authority.** Nothing ingested outranks what the user said. A calendar entry
///    that disagrees with them loses, and stays visible as the thing that disagreed.
/// 2. **It links, it never invents people.** An attendee is attached to someone the user already
///    knows, or ignored. A world model that invents a person for every email address in a meeting
///    invite is noise wearing a trench coat. The same goes for the item itself: a reminder the
///    assistant created is already in here, and the sync attaches to it rather than making a twin.
/// 3. **It cannot put the user on the hook.** Commitments and decisions come from their own voice
///    only; an event called "send Sarah the deck" becomes an event, not a promise.
/// 4. **It is idempotent and reversible.** The same item ingested twice updates one entity, and
///    every sync leaves one activity entry the user can undo.
extension IntelligenceStore {
    /// Brings a batch in. `prune` removes entities from this source that the batch no longer
    /// contains — a deleted event should not haunt the user's week.
    @discardableResult
    public func ingest(
        _ items: [IngestedItem],
        source: SourceType,
        prune: Bool = false,
        now: Date = Date()
    ) throws -> IngestionReport {
        var report = IngestionReport()
        var seen = Set<String>()

        for item in items {
            seen.insert(item.sourceID)
            // Only the user's own words can create a promise or settle a decision.
            guard item.kind != .commitment, item.kind != .decision else { continue }

            let existing = try link(sourceType: item.sourceType, sourceID: item.sourceID)
            if let existing, existing.digest == item.digest, try entity(existing.entityID) != nil {
                report.unchanged += 1
                continue
            }

            let written = try apply(item, existingID: existing?.entityID, now: now)
            try saveLink(sourceType: item.sourceType, sourceID: item.sourceID, entityID: written.id,
                         digest: item.digest, adopted: written.adopted || existing?.adopted == true, at: now)
            report.linked += try connect(item, entityID: written.id, now: now)
            switch (existing, written.adopted) {
            case (nil, true): report.adopted += 1
            case (nil, false): report.created += 1
            default: report.updated += 1
            }
        }

        if prune {
            for link in try links(of: source) where !seen.contains(link.sourceID) {
                if try retract(link, source: source) { report.removed += 1 }
            }
        }

        if !report.isEmpty {
            logger?.log(.counter(name: "intelligence.ingested", value: report.changed))
        }
        return report
    }

    /// Takes back one thing a source brought in.
    ///
    /// Its own statements go first, then the entity — but only if this source is what made it and
    /// nothing else has come to depend on it. An event the user has since talked about, attached to
    /// a project, or made a promise about is theirs now; the calendar forgetting it is not a reason
    /// to lose that. Neither is a source dropping something it only ever recognised.
    @discardableResult
    private func retract(_ link: ExternalLink, source: SourceType) throws -> Bool {
        try removeLink(sourceType: source, sourceID: link.sourceID)
        // Both directions: this source also wrote "Sarah attends it", where the event is the object.
        // Leaving that behind would keep Sarah pointing at something gone — and would count as a
        // reference, so the event could never be let go of at all.
        try db.run(
            "DELETE FROM assertions WHERE (subject_id = ?1 OR object_id = ?1) AND source_type = ?2;",
            [.text(link.entityID.uuidString), .text(source.rawValue)]
        )
        guard !link.adopted else { return false }
        return try forgetIfUnused(link.entityID)
    }

    // MARK: Writing one item

    /// Where an item ended up, and whether that was somewhere the user already had.
    private struct Written {
        var id: UUID
        var adopted: Bool
    }

    private func apply(_ item: IngestedItem, existingID: UUID?, now: Date) throws -> Written {
        let provenance = Provenance(sourceType: item.sourceType, sourceID: item.sourceID)
        let entityID: UUID
        var adopted = false

        if let existingID, var entity = try entity(existingID) {
            entity.title = item.title
            try update(entity, at: now)
            entityID = existingID
        } else if let existing = try alreadyHere(item) {
            // The user already has this one — very often because the assistant put it in their
            // reminders itself. One thing stays one thing.
            entityID = existing.id
            adopted = true
        } else {
            let created = try create(kind: item.kind, title: item.title, importance: 0.45)
            entityID = created.id
        }

        // Dates and status are written as statements, not as columns, so they carry provenance and
        // the user can see — and override — where each one came from.
        if let startsAt = item.startsAt {
            try? record(dated(.starts, startsAt, subject: entityID, provenance: provenance, now: now))
        }
        if let endsAt = item.endsAt {
            try? record(dated(.ends, endsAt, subject: entityID, provenance: provenance, now: now))
        }
        if let dueAt = item.dueAt {
            try? record(dated(.deadline, dueAt, subject: entityID, provenance: provenance, now: now))
        }
        if let status = item.status {
            try? record(Assertion(
                subjectID: entityID, predicate: .status, value: .text(status.rawValue),
                type: .observed, authority: .observation, provenance: provenance,
                validFrom: now, createdAt: now, updatedAt: now
            ))
        }
        if let location = item.location, !location.isEmpty {
            try? record(Assertion(
                subjectID: entityID, predicate: .location, value: .text(location),
                type: .observed, authority: .observation, provenance: provenance,
                validFrom: now, createdAt: now, updatedAt: now
            ))
        }
        return Written(id: entityID, adopted: adopted)
    }

    /// Something the user already has that this item plainly *is*: same kind, the same name exactly,
    /// still in play, and not already spoken for by another outside item.
    ///
    /// Deliberately stricter than `resolve`, which also takes an unambiguous prefix and will find
    /// archived things. Neither belongs here: "Standup" is not "Standup with the platform team", and
    /// a sync should never resurrect something the user put away.
    private func alreadyHere(_ item: IngestedItem) throws -> IntelligenceEntity? {
        let folded = item.title.intelligenceFolded
        guard !folded.isEmpty else { return nil }
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.entityColumns) FROM entities
            WHERE title_folded = ?1 AND kind = ?2 AND archived_at IS NULL
            ORDER BY updated_at DESC LIMIT 4;
            """,
            [.text(folded), .text(item.kind.rawValue)]
        )
        for row in rows {
            let candidate = Self.entity(from: row)
            guard candidate.id != IntelligenceIdentity.userEntityID,
                  try !isLinkedToAnySource(candidate.id) else { continue }
            return candidate
        }
        return nil
    }

    private func isLinkedToAnySource(_ entityID: UUID) throws -> Bool {
        try !db.query(
            "SELECT 1 FROM external_links WHERE entity_id = ?1 LIMIT 1;",
            [.text(entityID.uuidString)]
        ).isEmpty
    }

    private func dated(
        _ predicate: Predicate, _ date: Date, subject: UUID, provenance: Provenance, now: Date
    ) -> Assertion {
        Assertion(
            subjectID: subject, predicate: predicate, value: .date(date, phrase: nil),
            type: .observed, authority: .observation, provenance: provenance,
            validFrom: now, createdAt: now, updatedAt: now
        )
    }

    /// Attaches the item to people the user already knows. Never creates one: a name on an invite
    /// is not evidence that the user knows that person.
    private func connect(_ item: IngestedItem, entityID: UUID, now: Date) throws -> Int {
        var linked = 0
        let provenance = Provenance(sourceType: item.sourceType, sourceID: item.sourceID)
        for mention in item.mentions {
            guard let person = try resolve(title: mention, kind: .person),
                  person.id != IntelligenceIdentity.userEntityID else { continue }
            let predicate: Predicate = item.kind == .event ? .attends : .assignedTo
            let assertion = item.kind == .event
                ? Assertion(subjectID: person.id, predicate: predicate, objectID: entityID,
                            type: .observed, authority: .observation, provenance: provenance,
                            validFrom: now, createdAt: now, updatedAt: now)
                : Assertion(subjectID: entityID, predicate: predicate, objectID: person.id,
                            type: .observed, authority: .observation, provenance: provenance,
                            validFrom: now, createdAt: now, updatedAt: now)
            if (try? record(assertion)) != nil { linked += 1 }
        }
        return linked
    }

    // MARK: External links

    public struct ExternalLink: Sendable, Equatable {
        public var sourceType: SourceType
        public var sourceID: String
        public var entityID: UUID
        public var digest: String
        /// True when the entity was the user's before this source found it. What was theirs stays
        /// theirs when the source goes away.
        public var adopted: Bool
        public var linkedAt: Date
    }

    private static let linkColumns = "source_type, source_id, entity_id, digest, adopted, linked_at"

    public func link(sourceType: SourceType, sourceID: String) throws -> ExternalLink? {
        try db.query(
            "SELECT \(Self.linkColumns) FROM external_links WHERE source_type = ?1 AND source_id = ?2;",
            [.text(sourceType.rawValue), .text(sourceID)]
        ).first.map(Self.externalLink(from:))
    }

    public func links(of sourceType: SourceType) throws -> [ExternalLink] {
        try db.query(
            "SELECT \(Self.linkColumns) FROM external_links WHERE source_type = ?1;",
            [.text(sourceType.rawValue)]
        ).map(Self.externalLink(from:))
    }

    /// The entity an outside thing became, if it became one.
    public func entity(forSource sourceType: SourceType, sourceID: String) throws -> IntelligenceEntity? {
        guard let link = try link(sourceType: sourceType, sourceID: sourceID) else { return nil }
        return try entity(link.entityID)
    }

    func saveLink(
        sourceType: SourceType, sourceID: String, entityID: UUID,
        digest: String, adopted: Bool = false, at date: Date
    ) throws {
        try db.run(
            """
            INSERT INTO external_links (source_type, source_id, entity_id, digest, adopted, linked_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(source_type, source_id)
            DO UPDATE SET entity_id = ?3, digest = ?4, adopted = ?5, linked_at = ?6;
            """,
            [.text(sourceType.rawValue), .text(sourceID), .text(entityID.uuidString),
             .text(digest), .init(adopted), .init(date)]
        )
    }

    func removeLink(sourceType: SourceType, sourceID: String) throws {
        try db.run(
            "DELETE FROM external_links WHERE source_type = ?1 AND source_id = ?2;",
            [.text(sourceType.rawValue), .text(sourceID)]
        )
    }

    /// Everything one source ever brought in, removed together. What the user turns off, they can
    /// also take back.
    @discardableResult
    public func forgetEverything(from sourceType: SourceType) throws -> Int {
        var removed = 0
        for link in try links(of: sourceType) where try retract(link, source: sourceType) {
            removed += 1
        }
        return removed
    }

    static func externalLink(from row: SQLRow) -> ExternalLink {
        ExternalLink(
            sourceType: SourceType(rawValue: row.string(0) ?? "") ?? .system,
            sourceID: row.string(1) ?? "",
            entityID: UUID(uuidString: row.string(2) ?? "") ?? UUID(),
            digest: row.string(3) ?? "",
            adopted: (row.int(4) ?? 0) != 0,
            linkedAt: row.date(5) ?? Date()
        )
    }
}
