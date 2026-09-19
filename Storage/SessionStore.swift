import Core
import Foundation
import SwiftData
import Telemetry

/// A persisted conversation turn. Stays on device (Data Protection); cleared by the user's
/// "Clear history" control; never sent anywhere.
@Model
public final class StoredTurn {
    @Attribute(.unique) public var id: UUID
    public var conversationID: UUID
    public var role: String
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), conversationID: UUID, role: String, text: String, createdAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// Local model metadata mirrored for the Settings screen (the download manager's on-disk
/// activation records remain the source of truth).
@Model
public final class ModelMetadataRecord {
    @Attribute(.unique) public var packID: String
    public var revision: String
    public var bytes: Int64
    public var installedAt: Date
    public var lastVerifiedAt: Date?

    public init(packID: String, revision: String, bytes: Int64, installedAt: Date, lastVerifiedAt: Date?) {
        self.packID = packID
        self.revision = revision
        self.bytes = bytes
        self.installedAt = installedAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public enum PersistenceSchema {
    public static let models: [any PersistentModel.Type] = [StoredTurn.self, ModelMetadataRecord.self, AppSettingsRecord.self]

    /// On-device store in Application Support with complete-until-first-unlock protection,
    /// excluded from backups.
    public static func makeContainer(inMemory: Bool = false, directory: URL? = nil) throws -> ModelContainer {
        let schema = Schema(models)
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("VoiceAgentStore", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(values)
        let configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("store.sqlite"))
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

/// Conversation history persistence (SwiftData, background model actor).
@ModelActor
public actor SessionStore {
    public func append(_ turn: ConversationTurn, conversationID: UUID) throws {
        modelContext.insert(StoredTurn(conversationID: conversationID, role: turn.role.rawValue, text: turn.text, createdAt: turn.timestamp))
        try modelContext.save()
    }

    public func recentTurns(limit: Int = 50) throws -> [ConversationTurn] {
        var descriptor = FetchDescriptor<StoredTurn>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).reversed().compactMap { stored in
            guard let role = ConversationTurn.Role(rawValue: stored.role) else { return nil }
            return ConversationTurn(role: role, text: stored.text, timestamp: stored.createdAt)
        }
    }

    public func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<StoredTurn>())
    }

    /// The user's "Clear history" control.
    public func clearHistory() throws {
        try modelContext.delete(model: StoredTurn.self)
        try modelContext.save()
        PrivacySafeLogger.shared.log(.counter(name: "history_cleared", value: 1))
    }

    /// Retention policy: removes turns older than `date`.
    public func prune(olderThan date: Date) throws {
        try modelContext.delete(model: StoredTurn.self, where: #Predicate { $0.createdAt < date })
        try modelContext.save()
    }

    public func upsertModelMetadata(packID: String, revision: String, bytes: Int64, installedAt: Date, lastVerifiedAt: Date?) throws {
        let descriptor = FetchDescriptor<ModelMetadataRecord>(predicate: #Predicate { $0.packID == packID })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.revision = revision
            existing.bytes = bytes
            existing.installedAt = installedAt
            existing.lastVerifiedAt = lastVerifiedAt
        } else {
            modelContext.insert(ModelMetadataRecord(packID: packID, revision: revision, bytes: bytes, installedAt: installedAt, lastVerifiedAt: lastVerifiedAt))
        }
        try modelContext.save()
    }

    public func removeModelMetadata(packID: String) throws {
        try modelContext.delete(model: ModelMetadataRecord.self, where: #Predicate { $0.packID == packID })
        try modelContext.save()
    }

    public func modelMetadata() throws -> [ModelMetadataSnapshot] {
        try modelContext.fetch(FetchDescriptor<ModelMetadataRecord>(sortBy: [SortDescriptor(\.packID)])).map {
            ModelMetadataSnapshot(packID: $0.packID, revision: $0.revision, bytes: $0.bytes, installedAt: $0.installedAt, lastVerifiedAt: $0.lastVerifiedAt)
        }
    }
}

public struct ModelMetadataSnapshot: Sendable, Equatable {
    public let packID: String
    public let revision: String
    public let bytes: Int64
    public let installedAt: Date
    public let lastVerifiedAt: Date?
}
