import Core
import Foundation

/// One outside service the user has connected: Gmail, Drive, GitHub, whatever comes next.
///
/// The point of this protocol is that the intelligence never learns about any of them. A connector
/// declares what it can do and how to do it; the capability registry publishes those to the model
/// alongside the phone's own, and the runtime executes them through the same gate as everything
/// else. Adding a service is adding an adapter — not touching the agent.
///
/// Two rules hold for every implementation:
///
/// 1. **A connector never decides whether it may run.** It is handed an authorization or it is not
///    called. Permission, confirmation, the network policy and the log all happen above it.
/// 2. **A connector returns what it found, not the mailbox.** The user's inbox does not go into a
///    prompt or into the local database; a search returns the few results that matched, as text the
///    model can reason over and the user can be shown.
public protocol Connector: Sendable {
    /// Stable identifier, and the value `CapabilitySpec.connector` matches on.
    var id: String { get }
    /// What the user calls it.
    var name: String { get }
    /// Every host this connector may reach. The network policy allows these and nothing else, so a
    /// result that points somewhere else has nowhere to send the agent.
    var hosts: Set<String> { get }
    /// How the user connects it.
    var auth: ConnectorAuthStyle { get }
    var capabilities: [ConnectorCapability] { get }

    /// Runs one capability with an authorization that is already valid.
    func perform(_ call: ConnectorCall, auth: ConnectorAuthorization) async throws -> ConnectorResult
}

public extension Connector {
    func capability(_ id: CapabilityID) -> ConnectorCapability? { capabilities.first { $0.id == id } }
}

/// Something a connected service can do.
public struct ConnectorCapability: Sendable, Equatable {
    public let id: CapabilityID
    /// One line, written for the model: what it does and when to reach for it.
    public let summary: String
    public let arguments: [ToolArgumentSpec]
    public let risk: RiskLevel
    /// True when running it changes something on the other end. Writes default to asking every
    /// time, and the agent never runs one without the user seeing exactly what it would do.
    public let isWrite: Bool
    /// What the user sees in the permission list ("Search email").
    public let title: String

    public init(
        id: CapabilityID,
        title: String,
        summary: String,
        arguments: [ToolArgumentSpec] = [],
        risk: RiskLevel = .readOnly,
        isWrite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.arguments = arguments
        self.risk = risk
        self.isWrite = isWrite
    }

    /// What this capability should default to when the service is first connected. Reading is what
    /// the user connected it for; anything that writes waits to be asked for by name.
    public var defaultGrant: ConnectorGrant { isWrite ? .ask : .on }
}

public struct ConnectorCall: Sendable, Equatable {
    public let capability: CapabilityID
    public let arguments: [String: String]

    public init(capability: CapabilityID, arguments: [String: String]) {
        self.capability = capability
        self.arguments = arguments
    }

    public func argument(_ name: String) -> String? {
        arguments[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    public func require(_ name: String) throws -> String {
        guard let value = argument(name) else { throw ConnectorError.missingArgument(name) }
        return value
    }
}

/// What came back, in terms the agent already speaks.
public struct ConnectorResult: Sendable, Equatable {
    /// What the model reads. Written as a source, never as an instruction.
    public var observation: String
    /// Anything worth keeping or opening: a message, a file, an issue.
    public var items: [ConnectorItem]
    public var bytesSent: Int
    public var bytesReceived: Int

    public init(observation: String, items: [ConnectorItem] = [], bytesSent: Int = 0, bytesReceived: Int = 0) {
        self.observation = observation
        self.items = items
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
    }
}

/// One thing a connector found. Deliberately thin: enough to show the user, quote in an answer and
/// come back to — not a copy of the service's own record.
public struct ConnectorItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Who it is from or whose it is, when that is a person.
    public var person: String?
    public var date: Date?
    /// A short piece of the content, already plain text.
    public var excerpt: String?
    /// Where the user can open it themselves.
    public var url: URL?

    public init(
        id: String, title: String, person: String? = nil, date: Date? = nil,
        excerpt: String? = nil, url: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.person = person
        self.date = date
        self.excerpt = excerpt
        self.url = url
    }
}

/// How a service is connected.
public enum ConnectorAuthStyle: Sendable, Equatable {
    /// The real thing: a browser sign-in with PKCE, no client secret on the device.
    case oauth(OAuthConfiguration)
    /// A token the user creates themselves and pastes in. Simpler and, for a single-person app,
    /// often safer: no client secret to hide, no redirect to register, and the user chooses the
    /// scopes on the service's own screen.
    case token(ConnectorTokenInstructions)
}

public struct ConnectorTokenInstructions: Sendable, Equatable {
    /// Where the user goes to make one.
    public var url: URL
    /// What to tick while they are there.
    public var guidance: String

    public init(url: URL, guidance: String) {
        self.url = url
        self.guidance = guidance
    }
}

public enum ConnectorError: Error, Equatable, CustomStringConvertible {
    case notConnected(String)
    case missingArgument(String)
    case notAllowed(String)
    case badResponse(Int)
    case unreadable
    case unreachable
    case expired

    public var description: String {
        switch self {
        case let .notConnected(name): "\(name) isn't connected yet."
        case let .missingArgument(name): "I need \(name) for that."
        case let .notAllowed(host): "\(host) isn't somewhere I'm allowed to reach."
        case let .badResponse(code) where code == 401 || code == 403: "That account wouldn't let me in."
        case let .badResponse(code): "That service answered with \(code)."
        case .unreadable: "I couldn't make sense of what came back."
        case .unreachable: "I couldn't reach it."
        case .expired: "That connection needs signing in again."
        }
    }
}
