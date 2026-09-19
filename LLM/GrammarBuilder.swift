import Core
import Foundation

/// Generates the llama.cpp GBNF grammar for the agent output contract directly from `ToolCatalog`,
/// so the prompt, the grammar and the validator can never drift apart.
///
/// Output shapes (compact JSON, fixed key order):
///   {"type":"answer","speech":"…"}
///   {"type":"clarification","speech":"…"}
///   {"type":"unsupported","speech":"…"}
///   {"type":"proposed_action","tool":"<tool>","arguments":{…},"requires_confirmation":true|false}
///
/// Consequential actions carry no model-authored speech: Swift renders the confirmation from the
/// resolved action (see Docs/SECURITY.md).
public enum GrammarBuilder {
    public static func agentOutputGrammar(tools: [ToolSpec] = ToolCatalog.all) -> String {
        var rules: [String] = []
        rules.append(#"root ::= answer | clarification | unsupported | proposal"#)
        rules.append(#"answer ::= "{\"type\":\"answer\",\"speech\":" speech "}""#)
        rules.append(#"clarification ::= "{\"type\":\"clarification\",\"speech\":" speech "}""#)
        rules.append(#"unsupported ::= "{\"type\":\"unsupported\",\"speech\":" speech "}""#)
        rules.append(#"proposal ::= "{\"type\":\"proposed_action\"," call "}""#)
        rules.append("call ::= " + tools.map { "call-\(ruleName($0.id))" }.joined(separator: " | "))

        for tool in tools {
            let name = ruleName(tool.id)
            // requires_confirmation is fixed by the tool's risk level (Swift policy), so it costs no
            // sampling step and can never disagree with the policy.
            let confirmation = tool.riskLevel.requiresConfirmation ? "true" : "false"
            rules.append(#"call-\#(name) ::= "\"tool\":\"\#(tool.id.rawValue)\",\"arguments\":{" args-\#(name)-h0 "},\"requires_confirmation\":\#(confirmation)""#)
            rules.append(contentsOf: argumentRules(for: tool, prefix: "args-\(name)"))
            for argument in tool.arguments {
                rules.append("arg-\(name)-\(ruleName(argument.name)) ::= " + argumentRule(argument))
            }
        }

        rules.append(#"speech ::= "\"" chr+ "\"""#)
        rules.append(#"text ::= "\"" chr+ "\"""#)
        rules.append(#"chr ::= [^"\\\x7F\x00-\x1F] | "\\" ["\\/]"#)
        rules.append(#"phone ::= "\"" "+"? [0-9] [0-9 ()\-.]* "\"""#)
        rules.append(#"integer ::= [1-9] [0-9]{0,3}"#)
        rules.append(#"boolean ::= "true" | "false""#)
        return rules.joined(separator: "\n") + "\n"
    }

    /// Rules that emit an ordered argument list with correct comma placement, requiring every
    /// required argument and at least one member of the tool's `atLeastOneOf` group (so e.g. a call
    /// can never be proposed with empty arguments).
    ///
    /// Rule `<prefix>-<i>-<e>-<s>`: arguments from index i, where e = something already emitted
    /// (next argument needs a comma) and s = the group is already satisfied.
    static func argumentRules(for tool: ToolSpec, prefix: String) -> [String] {
        let name = ruleName(tool.id)
        let plan = ArgumentPlan(tool: tool)
        var rules: [String] = ["\(prefix)-h0 ::= \(prefix)-0-0-\(plan.initiallySatisfied ? 1 : 0)"]
        for state in plan.reachableStates() {
            let alternatives = plan.transitions(from: state).map { transition -> String in
                guard let argument = transition.emitted else { return transition.next.map { "\(prefix)-\($0.key)" } ?? "\"\"" }
                let element = "arg-\(name)-\(ruleName(argument.name))"
                let comma = state.emitted ? "\",\" " : ""
                let rest = transition.next.map { " \(prefix)-\($0.key)" } ?? ""
                return comma + element + rest
            }
            rules.append("\(prefix)-\(state.key) ::= " + alternatives.joined(separator: " | "))
        }
        return rules
    }

    static func argumentRule(_ argument: ToolArgumentSpec) -> String {
        let key = #""\"\#(argument.name)\":""#
        switch argument.kind {
        case .text:
            return "\(key) text"
        case .phoneNumber:
            return "\(key) phone"
        case .integer:
            return "\(key) integer"
        case let .choice(values):
            let options = values.map { #""\"\#($0)\"""# }.joined(separator: " | ")
            return "\(key) (\(options))"
        }
    }

    static func ruleName(_ id: ToolID) -> String { ruleName(id.rawValue) }

    static func ruleName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-")
    }
}

/// Shared by the GBNF grammar and the jump-forward automaton so both describe the same language.
struct ArgumentPlan {
    struct State: Hashable {
        let index: Int
        let emitted: Bool
        let satisfied: Bool

        var key: String { "\(index)-\(emitted ? 1 : 0)-\(satisfied ? 1 : 0)" }
    }

    struct Transition {
        /// The argument emitted by this step (nil = end of the argument list).
        let emitted: ToolArgumentSpec?
        /// Next state (nil = end of the object).
        let next: State?
    }

    let arguments: [ToolArgumentSpec]
    let group: Set<String>

    init(tool: ToolSpec) {
        arguments = tool.arguments
        group = Set(tool.atLeastOneOf.first ?? [])
    }

    var initiallySatisfied: Bool { group.isEmpty }

    func canSatisfy(from index: Int, satisfied: Bool) -> Bool {
        satisfied || arguments[min(index, arguments.count)...].contains { group.contains($0.name) }
    }

    func transitions(from state: State) -> [Transition] {
        guard state.index < arguments.count else {
            return state.satisfied ? [Transition(emitted: nil, next: nil)] : []
        }
        let argument = arguments[state.index]
        var result: [Transition] = []
        let satisfiedAfter = state.satisfied || group.contains(argument.name)
        if canSatisfy(from: state.index + 1, satisfied: satisfiedAfter) {
            let next = State(index: state.index + 1, emitted: true, satisfied: satisfiedAfter)
            result.append(Transition(emitted: argument, next: next.index == arguments.count && next.satisfied ? nil : next))
        }
        if !argument.isRequired, canSatisfy(from: state.index + 1, satisfied: state.satisfied) {
            let next = State(index: state.index + 1, emitted: state.emitted, satisfied: state.satisfied)
            if next.index == arguments.count {
                if next.satisfied { result.append(Transition(emitted: nil, next: nil)) }
            } else {
                result.append(Transition(emitted: nil, next: next))
            }
        }
        return result
    }

    func reachableStates() -> [State] {
        var seen: [State] = []
        var queue = [State(index: 0, emitted: false, satisfied: initiallySatisfied)]
        while let state = queue.first {
            queue.removeFirst()
            guard !seen.contains(state) else { continue }
            seen.append(state)
            for transition in transitions(from: state) {
                if let next = transition.next { queue.append(next) }
            }
        }
        return seen
    }
}
