import Core
import Foundation

/// Every service the app knows how to talk to, and which of them the user has actually connected.
///
/// The registry is the only thing that knows a service exists. The agent asks it what is available
/// right now and gets back capability descriptions in the same shape as the phone's own tools; it
/// never learns that one of them is Gmail. That is what makes adding a service an adapter rather
/// than a change to the intelligence.
public actor ConnectorRegistry {
    private let connectors: [String: any Connector]
    private let accounts: ConnectorAccountStoring
    private let tokens: any ConnectorTokenStoring

    public init(
        connectors: [any Connector],
        accounts: ConnectorAccountStoring,
        tokens: any ConnectorTokenStoring
    ) {
        self.connectors = Dictionary(uniqueKeysWithValues: connectors.map { ($0.id, $0) })
        self.accounts = accounts
        self.tokens = tokens
    }

    public nonisolated func connector(_ id: String) -> (any Connector)? { connectors[id] }

    public nonisolated var all: [any Connector] {
        connectors.values.sorted { $0.name < $1.name }
    }

    /// Which services are connected *and* have at least one capability switched on. A service the
    /// user connected and then turned everything off on is, to the agent, not there.
    public func connected() async -> Set<String> {
        var live: Set<String> = []
        for account in await accounts.accounts() {
            guard let connector = connectors[account.connectorID] else { continue }
            let usable = connector.capabilities.contains {
                account.permissions.grant(for: $0.id, in: connector) != .off
            }
            if usable { live.insert(account.connectorID) }
        }
        return live
    }

    public func account(_ connectorID: String) async -> ConnectorAccount? {
        await accounts.accounts().first { $0.connectorID == connectorID }
    }

    public func accountList() async -> [ConnectorAccount] { await accounts.accounts() }

    /// The capabilities the agent may currently be told about: connected, and not switched off.
    ///
    /// A capability set to `off` is not described, not put in the grammar and not executable — the
    /// model cannot ask for what it has never heard of, which is a stronger guarantee than
    /// refusing it afterwards.
    public func availableCapabilities() async -> [(connector: any Connector, capability: ConnectorCapability)] {
        var available: [(any Connector, ConnectorCapability)] = []
        for account in await accounts.accounts() {
            guard let connector = connectors[account.connectorID] else { continue }
            for capability in connector.capabilities
            where account.permissions.grant(for: capability.id, in: connector) != .off {
                available.append((connector, capability))
            }
        }
        return available.sorted { $0.1.id.rawValue < $1.1.id.rawValue }
    }

    /// What the user decided for one capability, right now.
    public func grant(for capability: CapabilityID) async -> ConnectorGrant {
        guard let (connector, _) = await resolve(capability),
              let account = await account(connector.id) else { return .off }
        return account.permissions.grant(for: capability, in: connector)
    }

    public func resolve(_ capability: CapabilityID) async -> (connector: any Connector, capability: ConnectorCapability)? {
        for connector in connectors.values {
            if let found = connector.capability(capability) { return (connector, found) }
        }
        return nil
    }

    /// Every host any connected service may reach, for the network allowlist.
    public func allowedHosts() async -> Set<String> {
        let live = await connected()
        return connectors.values.filter { live.contains($0.id) }.reduce(into: Set<String>()) {
            $0.formUnion($1.hosts)
        }
    }

    // MARK: Connecting and disconnecting

    public func connect(_ connectorID: String, label: String, authorization: ConnectorAuthorization, now: Date = Date()) async throws {
        guard let connector = connectors[connectorID] else { throw ConnectorError.notConnected(connectorID) }
        try tokens.save(authorization, for: connectorID)
        // Keep the grants the user already chose if they are reconnecting the same service; a
        // re-authentication is not a reason to re-open a capability they turned off.
        let existing = await account(connectorID)?.permissions
        await accounts.save(ConnectorAccount(
            connectorID: connectorID,
            label: label,
            connectedAt: now,
            permissions: existing ?? ConnectorPermissions.defaults(for: connector)
        ))
    }

    /// Disconnecting removes the token first. If anything after it fails, the worst case is an
    /// account row with no way to use it — never a token with no account to show the user.
    public func disconnect(_ connectorID: String) async throws {
        try tokens.remove(connectorID)
        await accounts.remove(connectorID)
    }

    public func set(_ grant: ConnectorGrant, for capability: CapabilityID, in connectorID: String) async {
        guard var account = await account(connectorID) else { return }
        account.permissions.set(grant, for: capability)
        await accounts.save(account)
    }

    // MARK: Using one

    /// A token that is valid now, refreshing it first if it is not.
    ///
    /// Throws `.expired` rather than refreshing when there is nothing to refresh with, so the app
    /// can tell the user to sign in again instead of failing a job with something cryptic.
    public func authorization(
        for connectorID: String, session: any ConnectorSession, now: Date = Date()
    ) async throws -> ConnectorAuthorization {
        guard let connector = connectors[connectorID] else { throw ConnectorError.notConnected(connectorID) }
        guard let current = try tokens.authorization(for: connectorID) else {
            throw ConnectorError.notConnected(connector.name)
        }
        guard current.isExpired(at: now) else { return current }
        guard case let .oauth(configuration) = connector.auth, let refresh = current.refreshToken else {
            throw ConnectorError.expired
        }
        let response = try await session.send(OAuthFlow.refreshRequest(configuration: configuration, refreshToken: refresh))
        let renewed = try OAuthFlow.authorization(from: response, keeping: refresh, now: now)
        try tokens.save(renewed, for: connectorID)
        return renewed
    }
}

/// Where the connected accounts and their grants are written down.
///
/// Not the tokens: those are in the Keychain, and this is a plain file so that "what have I
/// connected, and what may it do" is answerable — and exportable — without ever touching a secret.
public protocol ConnectorAccountStoring: Sendable {
    func accounts() async -> [ConnectorAccount]
    func save(_ account: ConnectorAccount) async
    func remove(_ connectorID: String) async
}

public actor FileConnectorAccountStore: ConnectorAccountStoring {
    private let url: URL
    private var cached: [ConnectorAccount]?

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "Connectors", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "accounts.json")
    }

    public func accounts() -> [ConnectorAccount] {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([ConnectorAccount].self, from: $0) } ?? []
        cached = loaded
        return loaded
    }

    public func save(_ account: ConnectorAccount) {
        var all = accounts().filter { $0.connectorID != account.connectorID }
        all.append(account)
        write(all)
    }

    public func remove(_ connectorID: String) {
        write(accounts().filter { $0.connectorID != connectorID })
    }

    private func write(_ all: [ConnectorAccount]) {
        cached = all
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// For tests and previews.
public actor EphemeralAccountStore: ConnectorAccountStoring {
    private var stored: [ConnectorAccount]

    public init(_ accounts: [ConnectorAccount] = []) { stored = accounts }

    public func accounts() -> [ConnectorAccount] { stored }
    public func save(_ account: ConnectorAccount) {
        stored.removeAll { $0.connectorID == account.connectorID }
        stored.append(account)
    }
    public func remove(_ connectorID: String) { stored.removeAll { $0.connectorID == connectorID } }
}
