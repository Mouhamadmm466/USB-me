import Foundation

/// Generates the llama.cpp GBNF grammar for memory extraction straight from `PredicateCatalog`,
/// the same way `GrammarBuilder` generates the action grammar from `ToolCatalog`.
///
/// The point is that an illegal statement is not merely rejected afterwards — it cannot be
/// generated. A person has no deadline, a task is never "achieved", `works_on` always points at a
/// project: the grammar encodes the subject kind, so each branch only offers predicates that kind
/// can carry, and only the value shape that predicate takes.
///
/// Shape (compact JSON, fixed key order):
///   {"memories":[{"op":"add","subject":{"kind":"person","name":"Abdou"},
///                 "predicate":"works_on","object":{"kind":"project","name":"Offline App"}}]}
///   {"memories":[{"op":"add","subject":{"kind":"goal","name":"Ship the beta"},
///                 "predicate":"deadline","when":"next Friday"}]}
///   {"memories":[]}
public enum MemoryGrammar {
    /// Kinds the model may name, in a stable order.
    public static var subjectKinds: [EntityKind] {
        EntityKind.allCases.filter { EntityKind.learnable.contains($0) }
    }

    public static func grammar(maximumMemories: Int = 4) -> String {
        var rules: [String] = []
        rules.append(#"root ::= "{\"memories\":[" (memory ("," memory){0,\#(max(0, maximumMemories - 1))})? "]}""#)
        rules.append("memory ::= " + subjectKinds.map { "mem-\(rule($0))" }.joined(separator: " | "))

        for kind in subjectKinds {
            let name = rule(kind)
            let predicates = PredicateCatalog.learnable(forSubject: kind)
            guard !predicates.isEmpty else { continue }
            rules.append(#"mem-\#(name) ::= "{\"op\":" op ",\"subject\":{\"kind\":\"\#(kind.rawValue)\",\"name\":" name "}," stmt-\#(name) "}""#)
            rules.append("stmt-\(name) ::= " + predicates.map { "p-\(name)-\(rule($0.predicate))" }.joined(separator: " | "))
            for spec in predicates {
                rules.append(#"p-\#(name)-\#(rule(spec.predicate)) ::= "\"predicate\":\"\#(spec.predicate.rawValue)\"" \#(tail(spec))"#)
            }
        }

        rules.append(#"op ::= "\"add\"" | "\"end\"""#)
        rules.append(#"name ::= "\"" nchr{1,60} "\"""#)
        rules.append(#"phrase ::= "\"" nchr{1,40} "\"""#)
        rules.append(#"value ::= "\"" nchr{1,200} "\"""#)
        rules.append(#"nchr ::= [^"\\\x7F\x00-\x1F]"#)
        return rules.joined(separator: "\n") + "\n"
    }

    /// What follows the predicate: an object entity, a date phrase, or a text value.
    private static func tail(_ spec: PredicateSpec) -> String {
        switch spec.kind {
        case .relationship:
            let kinds = spec.objectKinds.sorted { $0.rawValue < $1.rawValue }
            let object = kinds
                .map { #"",\"object\":{\"kind\":\"\#($0.rawValue)\",\"name\":" name "}""# }
                .joined(separator: " | ")
            // A role is optional and only where one makes sense ("works on the app — design").
            let role = spec.acceptsValue ? #" (",\"text\":" value)?"# : ""
            return "(\(object))\(role)"
        case .attribute:
            switch spec.valueKind {
            case .date: return #"",\"when\":" phrase"#
            case .text, .number, .flag: return #"",\"text\":" value"#
            case .none: return #""""#
            }
        }
    }

    private static func rule(_ kind: EntityKind) -> String { kind.rawValue.replacingOccurrences(of: "_", with: "-") }
    private static func rule(_ predicate: Predicate) -> String { predicate.rawValue.replacingOccurrences(of: "_", with: "-") }

    /// The instruction block that goes in the cached prefix, generated from the same catalog so the
    /// prompt cannot drift from the grammar.
    public static func promptSection() -> String {
        var lines = ["What can be remembered (subject kind → what can be said about it):"]
        for kind in subjectKinds {
            let specs = PredicateCatalog.learnable(forSubject: kind)
            guard !specs.isEmpty else { continue }
            let described = specs.map { spec -> String in
                switch spec.kind {
                case .relationship:
                    let kinds = spec.objectKinds.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: "/")
                    return "\(spec.predicate.rawValue) → \(kinds)"
                case .attribute:
                    switch spec.valueKind {
                    case .date: return "\(spec.predicate.rawValue) → when (the user's own words)"
                    default: return "\(spec.predicate.rawValue) → text"
                    }
                }
            }
            lines.append("- \(kind.rawValue): \(described.joined(separator: ", "))")
        }
        lines.append("Only record what the user actually said. Use their words for names and dates.")
        lines.append("Nothing worth keeping: {\"memories\":[]}")
        return lines.joined(separator: "\n")
    }
}
