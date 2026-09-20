import Foundation
import Security

/// Where a connector's tokens live.
///
/// The Keychain and nowhere else. Not the intelligence database (which the user can export), not
/// `UserDefaults`, not a settings snapshot, not a log line — a token is the one piece of state in
/// this app that would let someone else read the user's mail, so it is the one piece that never
/// appears in anything the app can print, show or hand over.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the app can refresh in the background after
/// the phone has been unlocked once, and the token does not travel in a backup to another device.
public protocol ConnectorTokenStoring: Sendable {
    func authorization(for connectorID: String) throws -> ConnectorAuthorization?
    func save(_ authorization: ConnectorAuthorization, for connectorID: String) throws
    func remove(_ connectorID: String) throws
}

public struct KeychainTokenStore: ConnectorTokenStoring {
    private let service: String

    public init(service: String = "com.mouhamadmamane.voiceagent.connectors") {
        self.service = service
    }

    private struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    public func authorization(for connectorID: String) throws -> ConnectorAuthorization? {
        var query = baseQuery(connectorID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return ConnectorAuthorization(
            accessToken: stored.accessToken, refreshToken: stored.refreshToken, expiresAt: stored.expiresAt
        )
    }

    public func save(_ authorization: ConnectorAuthorization, for connectorID: String) throws {
        let data = try JSONEncoder().encode(Stored(
            accessToken: authorization.accessToken,
            refreshToken: authorization.refreshToken,
            expiresAt: authorization.expiresAt
        ))
        // Replace rather than update-or-insert: one round trip fewer, and no state where a failed
        // update leaves the old token behind under a new account.
        SecItemDelete(baseQuery(connectorID) as CFDictionary)
        var query = baseQuery(connectorID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(_ connectorID: String) throws {
        let status = SecItemDelete(baseQuery(connectorID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ connectorID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectorID,
        ]
    }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "The keychain refused (\(status))." }
}

/// An in-memory store for tests and previews. Never used by the app: it is not a keychain, and a
/// type that pretends to be one in production is how tokens end up in a crash report.
public final class EphemeralTokenStore: ConnectorTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: ConnectorAuthorization] = [:]

    public init() {}

    public func authorization(for connectorID: String) throws -> ConnectorAuthorization? {
        lock.withLock { tokens[connectorID] }
    }

    public func save(_ authorization: ConnectorAuthorization, for connectorID: String) throws {
        lock.withLock { tokens[connectorID] = authorization }
    }

    public func remove(_ connectorID: String) throws {
        lock.withLock { _ = tokens.removeValue(forKey: connectorID) }
    }
}
