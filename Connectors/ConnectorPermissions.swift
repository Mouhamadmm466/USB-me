import Core
import Telemetry
import Foundation

/// What the user has allowed one service to do, capability by capability.
///
/// Not one switch per service. "Read my email" and "send email as me" are different decisions and
/// the second one is not implied by the first — so the model is only ever told about the
/// capabilities that are currently on, and a capability set to `off` does not exist as far as it is
/// concerned. It cannot ask for what it cannot see.
public enum ConnectorGrant: String, Codable, Sendable, CaseIterable, SafeLabelConvertible {
    /// Never, and not offered to the model.
    case off
    /// Offered, but every use stops and shows the user exactly what it would do.
    case ask
    /// Offered and runs.
    case on

    public var safeLabelText: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask every time"
        case .on: "On"
        }
    }
}

/// One service's grants.
public struct ConnectorPermissions: Codable, Sendable, Equatable {
    public var connectorID: String
    /// Capability id → grant. Missing means the capability's own default.
    public var grants: [String: ConnectorGrant]

    public init(connectorID: String, grants: [String: ConnectorGrant] = [:]) {
        self.connectorID = connectorID
        self.grants = grants
    }

    public func grant(for capability: CapabilityID, in connector: any Connector) -> ConnectorGrant {
        grants[capability.rawValue] ?? connector.capability(capability)?.defaultGrant ?? .off
    }

    public mutating func set(_ grant: ConnectorGrant, for capability: CapabilityID) {
        grants[capability.rawValue] = grant
    }

    /// What the service starts with when it is first connected: reading on, writing asking,
    /// anything destructive off. The user can widen it; nothing widens itself.
    public static func defaults(for connector: any Connector) -> ConnectorPermissions {
        var permissions = ConnectorPermissions(connectorID: connector.id)
        for capability in connector.capabilities {
            permissions.grants[capability.id.rawValue] = capability.defaultGrant
        }
        return permissions
    }
}

/// An account the user connected, without its token. The token lives in the Keychain and is never
/// part of any state a screen, a log or a model can see.
public struct ConnectorAccount: Codable, Sendable, Equatable, Identifiable {
    public var connectorID: String
    /// Who it is: an address, a username. Shown to the user so they know which account this is.
    public var label: String
    public var connectedAt: Date
    public var permissions: ConnectorPermissions

    public var id: String { connectorID }

    public init(connectorID: String, label: String, connectedAt: Date, permissions: ConnectorPermissions) {
        self.connectorID = connectorID
        self.label = label
        self.connectedAt = connectedAt
        self.permissions = permissions
    }
}

/// A live authorization: the token and when it stops working.
///
/// Deliberately not `Codable` and deliberately without a description: it exists for the length of
/// one call, and the only place it is written down is the Keychain.
public struct ConnectorAuthorization: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True a minute before it actually expires, so a call that takes a moment does not start with
    /// a token that dies halfway.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(60) >= expiresAt
    }
}
