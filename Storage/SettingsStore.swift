import Foundation
import SwiftData

/// Persisted user settings (one row).
@Model
public final class AppSettingsRecord {
    public var hasCompletedOnboarding: Bool
    /// Keep conversation history on device. Off = turns are not persisted at all.
    public var retainHistory: Bool
    public var historyRetentionDays: Int
    /// Re-open the microphone after the assistant answers.
    public var continueListening: Bool
    public var hapticsEnabled: Bool

    public init(
        hasCompletedOnboarding: Bool = false,
        retainHistory: Bool = true,
        historyRetentionDays: Int = 30,
        continueListening: Bool = true,
        hapticsEnabled: Bool = true
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.retainHistory = retainHistory
        self.historyRetentionDays = historyRetentionDays
        self.continueListening = continueListening
        self.hapticsEnabled = hapticsEnabled
    }
}

/// Value snapshot of settings for use across isolation domains.
public struct AppSettings: Sendable, Equatable, Codable {
    public var hasCompletedOnboarding = false
    public var retainHistory = true
    public var historyRetentionDays = 30
    public var continueListening = true
    public var hapticsEnabled = true

    public init() {}
}

@ModelActor
public actor SettingsStore {
    public func load() throws -> AppSettings {
        let record = try fetchOrCreate()
        var settings = AppSettings()
        settings.hasCompletedOnboarding = record.hasCompletedOnboarding
        settings.retainHistory = record.retainHistory
        settings.historyRetentionDays = record.historyRetentionDays
        settings.continueListening = record.continueListening
        settings.hapticsEnabled = record.hapticsEnabled
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let record = try fetchOrCreate()
        record.hasCompletedOnboarding = settings.hasCompletedOnboarding
        record.retainHistory = settings.retainHistory
        record.historyRetentionDays = max(1, min(365, settings.historyRetentionDays))
        record.continueListening = settings.continueListening
        record.hapticsEnabled = settings.hapticsEnabled
        try modelContext.save()
    }

    private func fetchOrCreate() throws -> AppSettingsRecord {
        if let existing = try modelContext.fetch(FetchDescriptor<AppSettingsRecord>()).first {
            return existing
        }
        let record = AppSettingsRecord()
        modelContext.insert(record)
        try modelContext.save()
        return record
    }
}
