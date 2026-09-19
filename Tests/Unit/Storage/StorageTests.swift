import Core
import Foundation
import SwiftData
import Testing
@testable import Storage

@Suite struct StorageTests {
    @Test func appendsAndReadsTurnsInOrder() async throws {
        let container = try PersistenceSchema.makeContainer(inMemory: true)
        let store = SessionStore(modelContainer: container)
        let conversation = UUID()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.append(ConversationTurn(role: .user, text: "text alex", timestamp: base), conversationID: conversation)
        try await store.append(ConversationTurn(role: .assistant, text: "Should I send it?", timestamp: base.addingTimeInterval(1)), conversationID: conversation)
        let turns = try await store.recentTurns(limit: 10)
        #expect(turns.map(\.text) == ["text alex", "Should I send it?"])
        #expect(turns.map(\.role) == [.user, .assistant])
    }

    @Test func clearHistoryRemovesEverything() async throws {
        let store = SessionStore(modelContainer: try PersistenceSchema.makeContainer(inMemory: true))
        try await store.append(ConversationTurn(role: .user, text: "hi", timestamp: Date()), conversationID: UUID())
        try await store.clearHistory()
        #expect(try await store.count() == 0)
    }

    @Test func pruneRemovesOnlyOldTurns() async throws {
        let store = SessionStore(modelContainer: try PersistenceSchema.makeContainer(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.append(ConversationTurn(role: .user, text: "old", timestamp: now.addingTimeInterval(-40 * 86_400)), conversationID: UUID())
        try await store.append(ConversationTurn(role: .user, text: "new", timestamp: now), conversationID: UUID())
        try await store.prune(olderThan: now.addingTimeInterval(-30 * 86_400))
        #expect(try await store.recentTurns().map(\.text) == ["new"])
    }

    @Test func settingsRoundTripWithDefaults() async throws {
        let store = SettingsStore(modelContainer: try PersistenceSchema.makeContainer(inMemory: true))
        var settings = try await store.load()
        #expect(settings == AppSettings())
        settings.hasCompletedOnboarding = true
        settings.retainHistory = false
        settings.historyRetentionDays = 900
        try await store.save(settings)
        let reloaded = try await store.load()
        #expect(reloaded.hasCompletedOnboarding)
        #expect(!reloaded.retainHistory)
        #expect(reloaded.historyRetentionDays == 365)
    }

    @Test func modelMetadataUpsert() async throws {
        let store = SessionStore(modelContainer: try PersistenceSchema.makeContainer(inMemory: true))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.upsertModelMetadata(packID: "whisper-base.en", revision: "a", bytes: 1, installedAt: date, lastVerifiedAt: nil)
        try await store.upsertModelMetadata(packID: "whisper-base.en", revision: "b", bytes: 2, installedAt: date, lastVerifiedAt: date)
        let metadata = try await store.modelMetadata()
        #expect(metadata.count == 1)
        #expect(metadata[0].revision == "b")
        try await store.removeModelMetadata(packID: "whisper-base.en")
        #expect(try await store.modelMetadata().isEmpty)
    }

    @Test func onDiskStoreIsCreatedInsideTheGivenDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try PersistenceSchema.makeContainer(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VoiceAgentStore").path))
    }
}
