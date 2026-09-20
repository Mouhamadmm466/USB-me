import Foundation
import Telemetry

/// How much of the world the user has let in. Off is the default and always will be.
public enum NetworkMode: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// Nothing leaves the device, ever. The assistant says what it cannot do.
    case off
    /// Every request is shown — what would be sent, to whom, why — and waits for a yes.
    case ask
    /// Requests inside a job the user already approved may go without asking again. Anything
    /// outside an approved job still asks.
    case approved

    public var displayName: String {
        switch self {
        case .off: "Never"
        case .ask: "Ask every time"
        case .approved: "Inside jobs I approve"
        }
    }

    public var explanation: String {
        switch self {
        case .off: "Nothing you say or store can leave this iPhone. Anything that needs the internet is refused."
        case .ask: "You see exactly what would be sent, and to whom, before it goes."
        case .approved: "When you approve a job, the steps in it that need the internet can run. Everything else still asks."
        }
    }
}

/// What kind of thing a request would send. Deliberately coarse and honest: the user is told the
/// category *and* shown the exact payload, so this is a label rather than a euphemism.
public enum DataCategory: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// Words to look up — taken from the user's own request or from a document they shared.
    case searchTerms
    /// A web address the user named, or one a search returned.
    case webAddress
    /// A file's contents. Nothing in V2 sends this; the case exists so a future capability that
    /// wants to cannot do it without saying so.
    case documentContents

    public var displayName: String {
        switch self {
        case .searchTerms: "search terms"
        case .webAddress: "a web address"
        case .documentContents: "a document's contents"
        }
    }
}

/// Exactly what a capability wants to send, before it is sent.
public struct NetworkRequestDescriptor: Sendable, Equatable {
    public var capability: String
    /// Who it goes to, in the user's terms ("Wikipedia").
    public var provider: String
    public var host: String
    public var categories: [DataCategory]
    /// Why, in the words of the step that wants it.
    public var reason: String
    /// The payload itself — the query, the URL — shown to the user verbatim. Never a summary.
    public var payload: String

    public init(
        capability: String, provider: String, host: String, categories: [DataCategory],
        reason: String, payload: String
    ) {
        self.capability = capability
        self.provider = provider
        self.host = host
        self.categories = categories
        self.reason = reason
        self.payload = payload
    }

    /// The single line the user is asked to approve.
    public var prompt: String {
        "Send \(categories.map(\.displayName).joined(separator: " and ")) to \(provider)? “\(payload)”"
    }
}

/// Why a request was refused. Closed vocabulary, so it can be logged and explained.
public enum NetworkRefusal: String, Sendable, Codable, Equatable, CaseIterable, SafeLabelConvertible {
    case modeOff
    case offline
    case notApproved
    case hostNotAllowed
    case wouldLeakPersonalContext
    case payloadTooLong

    public var explanation: String {
        switch self {
        case .modeOff: "The internet is switched off for this app."
        case .offline: "There's no connection right now."
        case .notApproved: "You haven't approved this one."
        case .hostNotAllowed: "That isn't a source this app is allowed to reach."
        case .wouldLeakPersonalContext: "That would have sent something about you that you didn't ask to send."
        case .payloadTooLong: "That request was too large to send."
        }
    }
}

public enum NetworkDecision: Sendable, Equatable {
    /// May go now.
    case allowed
    /// Must be shown to the user and approved first.
    case needsApproval
    case refused(NetworkRefusal)

    public var isAllowed: Bool { self == .allowed }
}

/// Decides whether one request may leave the device.
///
/// Three rules, in order, and none of them is a heuristic: the mode the user chose, whether this
/// request belongs to a job they already approved, and whether the payload contains anything about
/// their own world that they did not themselves put in the request. The third is the one that makes
/// this different from an app with a network permission — a payload is built from what the user
/// said and what the capability needs, never from what the system knows about them.
public struct NetworkPolicy: Sendable {
    public var mode: NetworkMode
    public var isOnline: Bool
    /// Hosts the app may reach at all. Providers register these; nothing else is reachable, so a
    /// page that names another host cannot redirect the agent somewhere new.
    public var allowedHosts: Set<String>
    public var maximumPayloadCharacters: Int

    public init(
        mode: NetworkMode = .off,
        isOnline: Bool = false,
        allowedHosts: Set<String> = [],
        maximumPayloadCharacters: Int = 400
    ) {
        self.mode = mode
        self.isOnline = isOnline
        self.allowedHosts = allowedHosts
        self.maximumPayloadCharacters = maximumPayloadCharacters
    }

    /// - Parameters:
    ///   - insideApprovedJob: true when this request is a step of a plan the user approved.
    ///   - leaks: anything in the payload that came from the user's own world rather than their
    ///     request. Non-empty means refusal, whatever the mode.
    public func decide(
        _ request: NetworkRequestDescriptor,
        insideApprovedJob: Bool = false,
        leaks: [String] = []
    ) -> NetworkDecision {
        guard mode != .off else { return .refused(.modeOff) }
        guard leaks.isEmpty else { return .refused(.wouldLeakPersonalContext) }
        guard request.payload.count <= maximumPayloadCharacters else { return .refused(.payloadTooLong) }
        guard allowedHosts.contains(request.host) else { return .refused(.hostNotAllowed) }
        guard isOnline else { return .refused(.offline) }
        if mode == .approved, insideApprovedJob { return .allowed }
        return .needsApproval
    }
}

/// Checks that nothing about the user's own world is riding along in a payload.
///
/// The rule: a payload may contain a name the system knows only if the user's own request contained
/// it too. So "look up the rules for the Beta launch" can send "Beta launch" — they said it — while
/// a job that read a document about the beta cannot quietly add it to a search.
///
/// A name only counts when it is distinctive enough to identify something: whole words, at least
/// four characters, and not an ordinary English word that happens to be a title. Without that, a
/// project called "Home" or the user's own entity ("You") would refuse every request that used the
/// word — a check that cries wolf is a check people switch off.
public enum NetworkLeakCheck {
    public static func leaks(in payload: String, knownNames: [String], userRequest: String) -> [String] {
        let payload = words(of: payload)
        let request = words(of: userRequest)
        return knownNames.filter { name in
            let parts = words(of: name)
            guard !parts.isEmpty else { return false }
            // A multi-word name is distinctive by construction; a single word has to earn it.
            if parts.count == 1, let only = parts.first {
                guard only.count >= 4, !ordinaryWords.contains(only) else { return false }
            }
            let inPayload = parts.allSatisfy(payload.contains)
            let inRequest = parts.allSatisfy(request.contains)
            return inPayload && !inRequest
        }
    }

    private static func words(of text: String) -> Set<String> {
        Set(
            text.intelligenceFolded
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    /// Words common enough that seeing one says nothing about the user.
    private static let ordinaryWords: Set<String> = [
        "you", "your", "me", "mine", "home", "work", "today", "tomorrow", "week", "month", "year",
        "thing", "things", "stuff", "note", "notes", "list", "plan", "plans", "task", "tasks",
        "project", "projects", "goal", "goals", "call", "text", "email", "meeting", "review",
        "draft", "report", "summary", "brief", "team", "class", "school", "test", "exam", "paper",
    ]
}
