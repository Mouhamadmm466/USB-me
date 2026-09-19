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
        rules.append(#"proposal ::= "{\"type\":\"proposed_action\"," call ",\"requires_confirmation\":" boolean "}""#)
        rules.append("call ::= " + tools.map { "call-\(ruleName($0.id))" }.joined(separator: " | "))

        for tool in tools {
            let name = ruleName(tool.id)
            rules.append(#"call-\#(name) ::= "\"tool\":\"\#(tool.id.rawValue)\",\"arguments\":{" args-\#(name)-h0 "}""#)
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

    /// Rules that emit an ordered argument list with correct comma placement.
    ///
    /// `hN` = arguments from index N when nothing has been emitted yet;
    /// `tN` = arguments from index N after at least one argument (each prefixed with ",").
    static func argumentRules(for tool: ToolSpec, prefix: String) -> [String] {
        let name = ruleName(tool.id)
        let arguments = tool.arguments
        var rules: [String] = []
        for index in 0...arguments.count {
            if index == arguments.count {
                rules.append("\(prefix)-h\(index) ::= \"\"")
                rules.append("\(prefix)-t\(index) ::= \"\"")
                continue
            }
            let argument = arguments[index]
            let element = "arg-\(name)-\(ruleName(argument.name))"
            if argument.isRequired {
                rules.append("\(prefix)-h\(index) ::= \(element) \(prefix)-t\(index + 1)")
                rules.append("\(prefix)-t\(index) ::= \",\" \(element) \(prefix)-t\(index + 1)")
            } else {
                rules.append("\(prefix)-h\(index) ::= \(element) \(prefix)-t\(index + 1) | \(prefix)-h\(index + 1)")
                rules.append("\(prefix)-t\(index) ::= \",\" \(element) \(prefix)-t\(index + 1) | \(prefix)-t\(index + 1)")
            }
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
