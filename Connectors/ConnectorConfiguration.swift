import Foundation

/// The per-service configuration the user has to supply themselves.
///
/// Google will not let an app talk to Gmail or Drive without an OAuth client of its own, created in
/// a Google Cloud project by whoever is going to use it. That identifier is not a secret — it is in
/// every authorization URL the app sends — but it is also not something that can be shipped inside
/// the app, because it belongs to an account, not to the software. So it is configuration: the user
/// pastes it once, it lives in a plain file beside the account list, and it is exportable and
/// inspectable like everything else that is not a token.
public actor ConnectorConfigurationStore {
    private let url: URL
    private var cached: [String: String]?

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        try FileConnectorAccountStore.defaultURL()
            .deletingLastPathComponent()
            .appending(path: "configuration.json")
    }

    public func clientID(for connectorID: String) -> String? {
        let value = load()[connectorID]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func set(_ clientID: String, for connectorID: String) {
        var all = load()
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { all.removeValue(forKey: connectorID) } else { all[connectorID] = trimmed }
        cached = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func load() -> [String: String] {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cached = loaded
        return loaded
    }
}
