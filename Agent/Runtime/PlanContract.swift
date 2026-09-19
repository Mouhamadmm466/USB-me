import Core
import Foundation
import Intelligence
import LLM

/// The `plan` output contract: the grammar the planner decodes under, and the validator that
/// decides whether what came back is a plan at all.
///
/// The grammar is generated from the capabilities this job is actually allowed to use, so a plan
/// cannot name a capability that is out of scope, unavailable, or does not exist — not because it
/// is rejected afterwards, but because those tokens cannot be produced.
public enum PlanContract {
    /// Shape (compact JSON, fixed key order):
    ///   {"title":"…","steps":[{"do":"<capability>","why":"…","arguments":{…}}, …]}
    public static func grammar(for registry: CapabilityRegistry, maximumSteps: Int = 6) -> String {
        let specs = registry.specs
        guard !specs.isEmpty else { return #"root ::= "{\"title\":\"\",\"steps\":[]}""# + "\n" }

        var rules: [String] = []
        rules.append(#"root ::= "{\"title\":" title ",\"steps\":[" step ("," step){0,\#(max(0, maximumSteps - 1))} "]}""#)
        rules.append("step ::= " + specs.map { "step-\(rule($0.id))" }.joined(separator: " | "))

        for spec in specs {
            let name = rule(spec.id)
            if spec.arguments.isEmpty {
                rules.append(#"step-\#(name) ::= "{\"do\":\"\#(spec.id.rawValue)\",\"why\":" why ",\"arguments\":{}}""#)
                continue
            }
            rules.append(
                #"step-\#(name) ::= "{\"do\":\"\#(spec.id.rawValue)\",\"why\":" why ",\"arguments\":{" args-\#(name)-h0 "}}""#
            )
            rules.append(contentsOf: GrammarBuilder.argumentRules(
                arguments: spec.arguments, atLeastOneOf: spec.atLeastOneOf,
                prefix: "args-\(name)", elementPrefix: "arg-\(name)"
            ))
            for argument in spec.arguments {
                rules.append("arg-\(name)-\(GrammarBuilder.ruleName(argument.name)) ::= " + argumentRule(argument))
            }
        }

        rules.append(#"title ::= "\"" chr{1,60} "\"""#)
        rules.append(#"why ::= "\"" chr{1,90} "\"""#)
        rules.append(#"text ::= "\"" chr+ "\"""#)
        rules.append(#"chr ::= [^"\\\x7F\x00-\x1F] | "\\" ["\\/]"#)
        rules.append(#"phone ::= "\"" "+"? [0-9] [0-9 ()\-.]* "\"""#)
        rules.append(#"integer ::= [1-9] [0-9]{0,3}"#)
        return rules.joined(separator: "\n") + "\n"
    }

    private static func argumentRule(_ argument: ToolArgumentSpec) -> String {
        let key = #""\"\#(argument.name)\":""#
        switch argument.kind {
        case .text: return "\(key) text"
        case .phoneNumber: return "\(key) phone"
        case .integer: return "\(key) integer"
        case let .choice(values):
            return "\(key) (" + values.map { #""\"\#($0)\"""# }.joined(separator: " | ") + ")"
        }
    }

    private static func rule(_ id: CapabilityID) -> String { GrammarBuilder.ruleName(id.rawValue) }

    /// The capability list for the prompt, generated from the same registry as the grammar.
    public static func promptSection(for registry: CapabilityRegistry) -> String {
        registry.specs.map { spec in
            let arguments = spec.arguments.map { $0.isRequired ? $0.name : $0.name + "?" }.joined(separator: ", ")
            return "- \(spec.id.rawValue)(\(arguments)): \(spec.summary)"
        }.joined(separator: "\n")
    }
}

// MARK: - Decoding

/// What the planner emitted, before anything has been checked against the world.
struct ProposedPlan: Decodable {
    struct Step: Decodable {
        var capability: String
        var why: String
        var arguments: [String: ToolArgumentValue]

        enum CodingKeys: String, CodingKey {
            case capability = "do", why, arguments
        }
    }

    var title: String
    var steps: [Step]
}

public enum PlanValidationError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case noSteps
    case tooManySteps(Int)
    case unknownCapability(String)
    case outOfScope(String)
    case unavailable(String, CapabilityUnavailability)
    case missingArgument(capability: String, argument: String)
    case badArgument(capability: String, argument: String)
    case emptyTitle

    public var description: String {
        switch self {
        case .notJSON: "the plan wasn't valid JSON"
        case .noSteps: "the plan had no steps"
        case let .tooManySteps(count): "the plan had \(count) steps, which is more than allowed"
        case let .unknownCapability(name): "\(name) isn't something I can do"
        case let .outOfScope(name): "\(name) isn't allowed for this job"
        case let .unavailable(name, reason): "\(name) isn't available right now (\(reason.rawValue))"
        case let .missingArgument(capability, argument): "\(capability) needs \(argument)"
        case let .badArgument(capability, argument): "\(capability) got a bad \(argument)"
        case .emptyTitle: "the plan had no title"
        }
    }
}

/// Turns what the planner wrote into a plan the runtime will act on — or refuses it.
///
/// Every step is checked against the registry (does this capability exist?), the job's scope (is it
/// allowed here?), availability (can it run at all?) and the argument schema. Steps run in the
/// order written: the planner does not get to express a dependency graph, because a 4B model
/// expressing one correctly is far less likely than it ordering three steps sensibly.
public struct PlanValidator: Sendable {
    public let registry: CapabilityRegistry
    public var availability: CapabilityAvailability
    public var maximumSteps: Int

    public init(
        registry: CapabilityRegistry = .all,
        availability: CapabilityAvailability = .offline,
        maximumSteps: Int = 6
    ) {
        self.registry = registry
        self.availability = availability
        self.maximumSteps = maximumSteps
    }

    public func validate(
        _ output: String, request: String, scope: [String], subjectID: UUID? = nil, now: Date = Date()
    ) throws -> Plan {
        guard let data = output.data(using: .utf8),
              let proposed = try? JSONDecoder().decode(ProposedPlan.self, from: data) else {
            throw PlanValidationError.notJSON
        }
        let title = proposed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlanValidationError.emptyTitle }
        guard !proposed.steps.isEmpty else { throw PlanValidationError.noSteps }
        guard proposed.steps.count <= maximumSteps else { throw PlanValidationError.tooManySteps(proposed.steps.count) }

        let allowed = Set(scope)
        let planID = UUID()
        var steps: [PlanStep] = []
        for (index, proposedStep) in proposed.steps.enumerated() {
            guard let spec = registry.spec(named: proposedStep.capability) else {
                throw PlanValidationError.unknownCapability(proposedStep.capability)
            }
            guard allowed.contains(spec.id.rawValue) else {
                throw PlanValidationError.outOfScope(spec.id.rawValue)
            }
            if let reason = availability.unavailability(of: spec) {
                throw PlanValidationError.unavailable(spec.id.rawValue, reason)
            }
            let arguments = try Self.arguments(proposedStep.arguments, for: spec)
            steps.append(PlanStep(
                planID: planID,
                ordinal: index,
                capability: spec.id.rawValue,
                summary: Self.summary(proposedStep.why, spec: spec, arguments: arguments),
                arguments: arguments,
                // Written order is the dependency: each step may use what the previous ones found.
                dependsOn: steps.last.map { [$0.id] } ?? [],
                requiresNetwork: spec.requiresNetwork,
                risk: spec.risk.rawValue,
                state: .proposed
            ))
        }

        return Plan(
            id: planID, request: request, title: title, subjectID: subjectID, state: .proposed,
            scope: scope, steps: steps, stepBudget: max(steps.count, 1),
            createdAt: now, updatedAt: now
        )
    }

    /// Checks each argument against the capability's schema and drops anything not in it.
    static func arguments(_ values: [String: ToolArgumentValue], for spec: CapabilitySpec) throws -> [String: String] {
        var arguments: [String: String] = [:]
        for argument in spec.arguments {
            guard let value = values[argument.name] else {
                if argument.isRequired { throw PlanValidationError.missingArgument(capability: spec.id.rawValue, argument: argument.name) }
                continue
            }
            let text: String
            switch (argument.kind, value) {
            case let (.text(maxLength), .string(string)):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= maxLength else {
                    throw PlanValidationError.badArgument(capability: spec.id.rawValue, argument: argument.name)
                }
                text = trimmed
            case let (.phoneNumber, .string(string)):
                text = string
            case let (.choice(options), .string(string)):
                guard options.contains(string) else {
                    throw PlanValidationError.badArgument(capability: spec.id.rawValue, argument: argument.name)
                }
                text = string
            case let (.integer(range), .integer(number)):
                guard range.contains(number) else {
                    throw PlanValidationError.badArgument(capability: spec.id.rawValue, argument: argument.name)
                }
                text = String(number)
            default:
                throw PlanValidationError.badArgument(capability: spec.id.rawValue, argument: argument.name)
            }
            arguments[argument.name] = text
        }
        for group in spec.atLeastOneOf where group.allSatisfy({ arguments[$0] == nil }) {
            throw PlanValidationError.missingArgument(capability: spec.id.rawValue, argument: group.joined(separator: " or "))
        }
        return arguments
    }

    /// The line the user reads for this step. The model's "why" when it is usable, otherwise one
    /// built from the capability itself — never an empty row in a plan someone has to approve.
    static func summary(_ why: String, spec: CapabilitySpec, arguments: [String: String]) -> String {
        let trimmed = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 3 { return String(trimmed.prefix(90)) }
        let subject = arguments["query"] ?? arguments["title"] ?? arguments["document"] ?? arguments["contact_query"]
        return subject.map { "\(spec.id.rawValue.replacingOccurrences(of: "_", with: " ")): \($0)" }
            ?? spec.id.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
