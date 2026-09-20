import Foundation
import Telemetry

/// What happened to a request that wanted to leave the device.
public enum NetworkOutcome: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    case sent
    case refused
    case declined
    case failed

    public var displayName: String {
        switch self {
        case .sent: "Sent"
        case .refused: "Refused"
        case .declined: "You said no"
        case .failed: "Didn't go through"
        }
    }
}

/// One line in "what left this iPhone".
///
/// Written for every request, including the ones that never went — a log that only records
/// successes cannot be used to check that a refusal actually refused.
public struct NetworkLogEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var at: Date
    public var capability: String
    public var provider: String
    public var host: String
    public var categories: [DataCategory]
    public var reason: String
    /// Exactly what was sent, kept verbatim so the user can check it later rather than trust a summary.
    public var payload: String
    public var outcome: NetworkOutcome
    public var refusal: NetworkRefusal?
    public var bytesSent: Int
    public var bytesReceived: Int
    public var planID: UUID?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        capability: String,
        provider: String,
        host: String,
        categories: [DataCategory],
        reason: String,
        payload: String,
        outcome: NetworkOutcome,
        refusal: NetworkRefusal? = nil,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        planID: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.capability = capability
        self.provider = provider
        self.host = host
        self.categories = categories
        self.reason = reason
        self.payload = payload
        self.outcome = outcome
        self.refusal = refusal
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.planID = planID
    }

    public init(descriptor: NetworkRequestDescriptor, outcome: NetworkOutcome, refusal: NetworkRefusal? = nil,
                bytesSent: Int = 0, bytesReceived: Int = 0, planID: UUID? = nil, at: Date = Date()) {
        self.init(
            at: at, capability: descriptor.capability, provider: descriptor.provider, host: descriptor.host,
            categories: descriptor.categories, reason: descriptor.reason, payload: descriptor.payload,
            outcome: outcome, refusal: refusal, bytesSent: bytesSent, bytesReceived: bytesReceived, planID: planID
        )
    }

    /// The line the user reads: "Wikipedia · search terms · “eigenvalues” · sent".
    public var summaryLine: String {
        "\(provider) · \(categories.map(\.displayName).joined(separator: ", ")) · “\(payload)”"
    }
}

/// The record of everything that tried to leave.
extension IntelligenceStore {
    @discardableResult
    public func record(_ entry: NetworkLogEntry) throws -> NetworkLogEntry {
        try db.run(
            """
            INSERT INTO network_log (id, at, capability, provider, host, categories, reason, payload,
                outcome, refusal, bytes_sent, bytes_received, plan_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
            """,
            [
                .text(entry.id.uuidString), .init(entry.at), .text(entry.capability), .text(entry.provider),
                .text(entry.host), .text(Self.encodeJSON(entry.categories.map(\.rawValue))),
                .text(entry.reason), .text(entry.payload), .text(entry.outcome.rawValue),
                .init(entry.refusal?.rawValue), .init(entry.bytesSent), .init(entry.bytesReceived),
                .init(entry.planID?.uuidString),
            ]
        )
        return entry
    }

    /// Newest first.
    public func networkLog(limit: Int = 100, since: Date? = nil) throws -> [NetworkLogEntry] {
        var bindings: [SQLValue] = []
        var filter = ""
        if let since {
            bindings.append(.init(since))
            filter = "WHERE at >= ?1"
        }
        return try db.query(
            """
            SELECT \(IntelligenceSchema.networkColumns) FROM network_log \(filter)
            ORDER BY at DESC LIMIT \(max(1, limit));
            """,
            bindings
        ).map(Self.networkEntry(from:))
    }

    /// How much has left, for the one-line answer to "has anything left this phone?".
    public func networkSummary(since: Date? = nil) throws -> (sent: Int, refused: Int, bytes: Int) {
        let entries = try networkLog(limit: 1_000, since: since)
        return (
            entries.count { $0.outcome == .sent },
            entries.count { $0.outcome == .refused || $0.outcome == .declined },
            entries.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }
        )
    }

    public func clearNetworkLog() throws {
        try db.run("DELETE FROM network_log;")
    }

    static func networkEntry(from row: SQLRow) -> NetworkLogEntry {
        NetworkLogEntry(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            at: row.date(1) ?? Date(),
            capability: row.string(2) ?? "",
            provider: row.string(3) ?? "",
            host: row.string(4) ?? "",
            categories: (decodeJSON([String].self, row.string(5)) ?? []).compactMap(DataCategory.init(rawValue:)),
            reason: row.string(6) ?? "",
            payload: row.string(7) ?? "",
            outcome: NetworkOutcome(rawValue: row.string(8) ?? "") ?? .failed,
            refusal: row.string(9).flatMap(NetworkRefusal.init(rawValue:)),
            bytesSent: Int(row.int(10) ?? 0),
            bytesReceived: Int(row.int(11) ?? 0),
            planID: row.string(12).flatMap(UUID.init(uuidString:))
        )
    }
}
