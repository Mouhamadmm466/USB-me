import Connectors
import Core
import Foundation

/// How a connected service's capabilities become capabilities of the agent.
///
/// The translation is the whole integration. Everything downstream — the planner's prompt, the
/// grammar, the validator, the scope rules, the runtime — already works in `CapabilitySpec`, so a
/// service that can describe itself in those terms is a service the agent can use without anything
/// being taught about it.
public enum ConnectorCapabilities {
    /// Specs for what is available right now: connected, and not switched off by the user.
    public static func specs(
        for available: [(connector: any Connector, capability: ConnectorCapability)]
    ) -> [CapabilitySpec] {
        available.map { connector, capability in
            CapabilitySpec(
                id: capability.id,
                domain: .network,
                // The service's name belongs in the summary: the model is choosing between "search
                // the user's email" and "search the web", and the difference is the whole point.
                summary: "\(capability.summary) (\(connector.name), the user's own account.)",
                arguments: capability.arguments,
                risk: capability.risk,
                requiresNetwork: true,
                connector: connector.id
            )
        }
    }

    /// The registry the planner and validator should use: the built-in capabilities plus whatever
    /// is connected. Built per job, because what is connected can change between them.
    public static func registry(adding connectorSpecs: [CapabilitySpec]) -> CapabilityRegistry {
        connectorSpecs.isEmpty
            ? CapabilityRegistry.all
            : CapabilityRegistry(specs: CapabilityRegistry.all.specs + connectorSpecs)
    }

    /// Which connector capabilities a job may use.
    ///
    /// Reading is what the user connected a service for, so a job that gathers may read from it.
    /// Writing as the user — sending an email, opening an issue — is a different thing, and follows
    /// the same rule as the phone's own consequential tools: it is in scope only when the request
    /// asked for it in words. The words come from the adapter itself, because it is the adapter
    /// that named the action in the user's language ("Send email", "Create an issue").
    public static func scope(
        for request: String,
        available: [(connector: any Connector, capability: ConnectorCapability)],
        gathers: Bool,
        excluding names: [String] = []
    ) -> [String] {
        var stripped = request.lowercased()
        for name in names.map({ $0.lowercased() }).sorted(by: { $0.count > $1.count }) where name.count > 2 {
            stripped = stripped.replacingOccurrences(of: name, with: " ")
        }
        let text = " " + stripped + " "

        return available.compactMap { connector, capability in
            if !capability.isWrite, gathers { return capability.id.rawValue }
            let asked = triggers(for: capability, connector: connector).contains { text.contains($0) }
            return asked ? capability.id.rawValue : nil
        }
    }

    /// The words that put one capability in scope: the service's name, and the significant words of
    /// the action as the adapter wrote it.
    static func triggers(for capability: ConnectorCapability, connector: any Connector) -> [String] {
        let fromTitle = capability.title.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 && !ignored.contains($0) }
        return ([connector.name.lowercased()] + fromTitle).map { " \($0)" }
    }

    /// Words that appear in a title without saying what the action is.
    private static let ignored: Set<String> = ["the", "and", "for", "from", "with", "your", "into"]
}
