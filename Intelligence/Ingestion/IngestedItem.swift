import CryptoKit
import Foundation
import Telemetry

/// One thing from a source the user authorized, in terms the store understands.
///
/// Deliberately source-agnostic: the calendar, reminders, a connected service later — each one
/// only has to describe what it found, and the rules about authority, identity and what may be
/// created live in one place (`IngestionService`).
public struct IngestedItem: Sendable, Equatable {
    public var sourceType: SourceType
    /// Stable identifier inside that source. The same id ingested twice updates rather than
    /// duplicates, which is what makes syncing safe to run on every launch.
    public var sourceID: String
    public var kind: EntityKind
    public var title: String
    public var startsAt: Date?
    public var endsAt: Date?
    public var dueAt: Date?
    public var status: EntityStatus?
    public var location: String?
    /// Names the source mentions (attendees, a list name). Linked to people who already exist;
    /// never used to invent one.
    public var mentions: [String]

    public init(
        sourceType: SourceType,
        sourceID: String,
        kind: EntityKind,
        title: String,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        dueAt: Date? = nil,
        status: EntityStatus? = nil,
        location: String? = nil,
        mentions: [String] = []
    ) {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.dueAt = dueAt
        self.status = status
        self.location = location
        self.mentions = mentions
    }

    /// Everything that would change the stored entity. Lets a sync skip what has not moved without
    /// reading the assertions back.
    public var digest: String {
        let parts: [String] = [
            title,
            startsAt.map(Self.stamp) ?? "",
            endsAt.map(Self.stamp) ?? "",
            dueAt.map(Self.stamp) ?? "",
            status?.rawValue ?? "",
            location ?? "",
            mentions.sorted().joined(separator: ","),
        ]
        let hash = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func stamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}

/// What one sync did. Shown to the user as a single line rather than one entry per item, because
/// "14 events from your calendar" is the sentence a person wants and fourteen rows is noise.
public struct IngestionReport: Sendable, Equatable {
    public var created = 0
    public var updated = 0
    /// Things the user already had that this source turned out to be describing.
    public var adopted = 0
    public var unchanged = 0
    public var linked = 0
    public var removed = 0

    public var changed: Int { created + updated + adopted + removed }
    public var isEmpty: Bool { created == 0 && updated == 0 && adopted == 0 && removed == 0 }

    public static func + (lhs: IngestionReport, rhs: IngestionReport) -> IngestionReport {
        IngestionReport(
            created: lhs.created + rhs.created,
            updated: lhs.updated + rhs.updated,
            adopted: lhs.adopted + rhs.adopted,
            unchanged: lhs.unchanged + rhs.unchanged,
            linked: lhs.linked + rhs.linked,
            removed: lhs.removed + rhs.removed
        )
    }

    /// "12 events from your calendar", "3 reminders updated".
    public func line(for source: SourceType) -> String? {
        guard !isEmpty else { return nil }
        let noun = source == .calendar ? "event" : "reminder"
        var parts: [String] = []
        if created > 0 { parts.append("\(created) new \(noun)\(created == 1 ? "" : "s")") }
        if updated > 0 { parts.append("\(updated) updated") }
        if adopted > 0 { parts.append("\(adopted) you already had") }
        if removed > 0 { parts.append("\(removed) gone") }
        return parts.joined(separator: ", ")
    }
}

/// Which sources the user has let in. Off until they say otherwise: permission to read the
/// calendar for one command is not permission to keep a copy of their week.
public struct IngestionPolicy: Sendable, Equatable, Codable {
    public var calendar: Bool
    public var reminders: Bool
    /// How far back and forward a sync looks.
    public var daysBack: Int
    public var daysForward: Int

    public init(calendar: Bool = false, reminders: Bool = false, daysBack: Int = 7, daysForward: Int = 30) {
        self.calendar = calendar
        self.reminders = reminders
        self.daysBack = daysBack
        self.daysForward = daysForward
    }

    public static let off = IngestionPolicy()
    public var isOn: Bool { calendar || reminders }
}
