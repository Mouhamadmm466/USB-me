import Core
import Foundation
import Intelligence
import Telemetry

/// What kind of thing a capability touches. Used for scoping and for what the user is told.
public enum CapabilityDomain: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// The phone itself: contacts, calendar, reminders, messages, calls, files, apps.
    case device
    /// What the system knows about the user's world.
    case intelligence
    /// Documents the user brought in.
    case knowledge
    /// Things written for the user.
    case artifact
    /// Anything that leaves the device.
    case network
    /// Talking to the user.
    case conversation
}

/// Why a capability cannot be used right now. A closed vocabulary, so it can be logged and shown.
public enum CapabilityUnavailability: String, Sendable, Equatable, CaseIterable, SafeLabelConvertible {
    case permissionNeeded
    case deviceCannot
    case networkOff
    case offline
    case notConnected
    case outOfScope
    case unknownCapability
}

public struct CapabilitySpec: Sendable, Equatable {
    public let id: CapabilityID
    public let domain: CapabilityDomain
    /// The line the planner reads: what it does, in the user's terms.
    public let summary: String
    /// Ordered; the constrained decoder emits arguments in exactly this order.
    public let arguments: [ToolArgumentSpec]
    public let risk: RiskLevel
    public let requiredPermissions: [PermissionKind]
    /// True when running it sends anything off the device.
    public let requiresNetwork: Bool
    /// The connector it needs, if any ("gmail", "github").
    public let connector: String?
    public let atLeastOneOf: [[String]]

    public init(
        id: CapabilityID,
        domain: CapabilityDomain,
        summary: String,
        arguments: [ToolArgumentSpec] = [],
        risk: RiskLevel = .readOnly,
        requiredPermissions: [PermissionKind] = [],
        requiresNetwork: Bool = false,
        connector: String? = nil,
        atLeastOneOf: [[String]] = []
    ) {
        self.id = id
        self.domain = domain
        self.summary = summary
        self.arguments = arguments
        self.risk = risk
        self.requiredPermissions = requiredPermissions
        self.requiresNetwork = requiresNetwork
        self.connector = connector
        self.atLeastOneOf = atLeastOneOf
    }

    public func argument(named name: String) -> ToolArgumentSpec? { arguments.first { $0.name == name } }

    /// Built from a V1 tool, unchanged: same arguments, same risk, same permissions.
    init(tool: ToolSpec) {
        id = CapabilityID(tool.id)
        domain = .device
        summary = tool.promptDescription
        arguments = tool.arguments
        risk = tool.riskLevel
        requiredPermissions = tool.requiredPermissions
        requiresNetwork = false
        connector = nil
        atLeastOneOf = tool.atLeastOneOf
    }
}

/// The single source of truth for what the agent can do, and what it may do right now.
///
/// Descriptions are static and live in the cached prompt prefix. *Availability* is not: it is
/// decided here, per job, from permissions, the network mode, connectivity and the job's own scope
/// — and it is enforced in the grammar, so a capability that is unavailable cannot even be
/// generated (PRD §4).
public struct CapabilityRegistry: Sendable {
    public let specs: [CapabilitySpec]

    public init(specs: [CapabilitySpec]) {
        self.specs = specs
    }

    /// Every capability: V1's tools plus V2's own.
    public static let all = CapabilityRegistry(
        specs: ToolCatalog.all.map(CapabilitySpec.init(tool:)) + CapabilityRegistry.intelligenceCapabilities
    )

    static let intelligenceCapabilities: [CapabilitySpec] = [
        CapabilitySpec(
            id: .searchKnowledge,
            domain: .knowledge,
            summary: "Search the documents the user has shared with you and read the passages that match.",
            arguments: [
                ToolArgumentSpec("query", .text(maxLength: 160), required: true,
                                 "what to look for, in the user's own words"),
            ]
        ),
        CapabilitySpec(
            id: .readDocument,
            domain: .knowledge,
            summary: "Read a document the user has shared, by name.",
            arguments: [
                ToolArgumentSpec("document", .text(maxLength: 120), required: true, "the document's name"),
                ToolArgumentSpec("about", .text(maxLength: 160), required: false, "the part that matters"),
            ]
        ),
        CapabilitySpec(
            id: .searchIntelligence,
            domain: .intelligence,
            summary: "Look up what is known about the user's projects, people, goals, promises and deadlines.",
            arguments: [
                ToolArgumentSpec("query", .text(maxLength: 120), required: true, "the person, project or goal"),
            ]
        ),
        CapabilitySpec(
            id: .writeArtifact,
            domain: .artifact,
            summary: "Write something for the user to read and keep: a brief, a summary, a plan, a draft.",
            arguments: [
                ToolArgumentSpec("title", .text(maxLength: 80), required: true, "what to call it"),
                ToolArgumentSpec("kind", .choice(["brief", "summary", "plan", "draft", "notes"]), required: true,
                                 "the kind of document"),
                ToolArgumentSpec("about", .text(maxLength: 200), required: true, "what it should cover"),
            ],
            risk: .reversibleLocalWrite
        ),
        CapabilitySpec(
            id: .remember,
            domain: .intelligence,
            summary: "Write down something learned during this job, so it is not lost when the job ends.",
            arguments: [
                ToolArgumentSpec("statement", .text(maxLength: 200), required: true,
                                 "what to remember, in one sentence"),
            ],
            risk: .reversibleLocalWrite
        ),
        CapabilitySpec(
            id: .searchWeb,
            domain: .network,
            summary: "Look something up on Wikipedia. Only the words you are given leave the phone.",
            arguments: [
                ToolArgumentSpec("query", .text(maxLength: 120), required: true,
                                 "what to look up, in the user's own words"),
            ],
            requiresNetwork: true
        ),
        CapabilitySpec(
            id: .readWebPage,
            domain: .network,
            summary: "Read a page that a search returned, or one the user gave by address.",
            arguments: [
                ToolArgumentSpec("url", .text(maxLength: 300), required: true, "the https address to read"),
            ],
            requiresNetwork: true
        ),
        CapabilitySpec(
            id: .askUser,
            domain: .conversation,
            summary: "Ask the user a question when the job genuinely cannot continue without their answer.",
            arguments: [
                ToolArgumentSpec("question", .text(maxLength: 160), required: true, "one short question"),
            ]
        ),
    ]

    public func spec(for id: CapabilityID) -> CapabilitySpec? { specs.first { $0.id == id } }
    public func spec(named name: String) -> CapabilitySpec? { spec(for: CapabilityID(name)) }

    public func specs(in domain: CapabilityDomain) -> [CapabilitySpec] { specs.filter { $0.domain == domain } }

    /// The registry limited to one job's allowlist, in the registry's own order.
    public func scoped(to scope: [String]) -> CapabilityRegistry {
        let allowed = Set(scope)
        return CapabilityRegistry(specs: specs.filter { allowed.contains($0.id.rawValue) })
    }
}

/// What the world allows right now: permissions granted, network mode, connectivity, connectors.
///
/// Kept separate from the registry because it changes minute to minute while the registry does not
/// — which is exactly why descriptions can be cached in the prompt prefix and availability cannot.
public struct CapabilityAvailability: Sendable {
    public var grantedPermissions: Set<PermissionKind>
    /// Snapshots, not closures: availability is read many times while a plan is validated and run,
    /// and it must not change halfway through deciding what a plan may do.
    public var canSendText: Bool
    public var canPlaceCalls: Bool
    /// False in airplane mode, when the user has network capabilities switched off, or with no route.
    public var networkAllowed: Bool
    public var isOnline: Bool
    public var connectedServices: Set<String>

    public init(
        grantedPermissions: Set<PermissionKind> = [],
        canSendText: Bool = true,
        canPlaceCalls: Bool = true,
        networkAllowed: Bool = false,
        isOnline: Bool = false,
        connectedServices: Set<String> = []
    ) {
        self.grantedPermissions = grantedPermissions
        self.canSendText = canSendText
        self.canPlaceCalls = canPlaceCalls
        self.networkAllowed = networkAllowed
        self.isOnline = isOnline
        self.connectedServices = connectedServices
    }

    /// Reads what the device can do right now.
    public static func current(
        device: DeviceCapabilities,
        grantedPermissions: Set<PermissionKind> = [],
        networkAllowed: Bool = false,
        isOnline: Bool = false,
        connectedServices: Set<String> = []
    ) async -> CapabilityAvailability {
        CapabilityAvailability(
            grantedPermissions: grantedPermissions,
            canSendText: await device.canSendText(),
            canPlaceCalls: await device.canPlaceCalls(),
            networkAllowed: networkAllowed,
            isOnline: isOnline,
            connectedServices: connectedServices
        )
    }

    /// Everything local and nothing that leaves the device: the honest default.
    public static let offline = CapabilityAvailability()

    /// Why this capability cannot run, or nil when it can.
    public func unavailability(of spec: CapabilitySpec) -> CapabilityUnavailability? {
        if spec.requiresNetwork {
            guard networkAllowed else { return .networkOff }
            guard isOnline else { return .offline }
        }
        if let connector = spec.connector, !connectedServices.contains(connector) { return .notConnected }
        // A permission that has not been granted is asked for at the moment of use, so a capability
        // is not hidden for it — the device simply being unable to do it is different.
        switch spec.id.tool {
        case .composeMessage where !canSendText: return .deviceCannot
        case .initiateCall where !canPlaceCalls: return .deviceCannot
        default: return nil
        }
    }

    public func isAvailable(_ spec: CapabilitySpec) -> Bool { unavailability(of: spec) == nil }
}
