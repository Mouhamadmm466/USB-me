import Core
import Foundation

/// Character-level automaton for the agent output language (the same regular language the GBNF
/// grammar in `GrammarBuilder` describes, built from the same `ToolCatalog`).
///
/// Used for jump-forward decoding: after each sampled token it computes the text the grammar
/// *forces* next (JSON keys, punctuation, the rest of an enum value once it is unambiguous), which
/// the runtime then evaluates as a single batch. The llama.cpp grammar sampler still checks every
/// forced token, so a divergence between the two can only disable the optimization, never produce
/// invalid output.
public final class OutputAutomaton: @unchecked Sendable {
    // Immutable after init; safe to share across threads.
    private let nfa: NFA

    public static let agentOutput = OutputAutomaton(pattern: AgentOutputPattern.root(tools: ToolCatalog.all))

    init(pattern: Pattern) {
        nfa = NFA(pattern: pattern)
    }

    /// Creates a cursor for one generation.
    public func makeCursor() -> Cursor { Cursor(nfa: nfa) }

    /// Whether `text` is a complete sentence of the language.
    public func accepts(_ text: String) -> Bool {
        let cursor = makeCursor()
        guard cursor.advance(to: text) else { return false }
        return cursor.isAccepting
    }

    /// Incremental matcher. Not thread-safe; one per generation.
    public final class Cursor {
        private let nfa: NFA
        private var states: Set<Int>
        private var consumed: String = ""
        public private(set) var isDead = false

        init(nfa: NFA) {
            self.nfa = nfa
            states = nfa.closure([nfa.start])
        }

        public var isAccepting: Bool { states.contains(nfa.accept) }

        /// Consumes the characters of `output` not yet seen. Returns false if the text left the language.
        @discardableResult
        public func advance(to output: String) -> Bool {
            guard !isDead else { return false }
            guard output.hasPrefix(consumed) else {
                // Restart from scratch if the caller rewound (not expected during generation).
                states = nfa.closure([nfa.start])
                consumed = ""
                return advance(to: output)
            }
            let newText = output.unicodeScalars.dropFirst(consumed.unicodeScalars.count)
            for scalar in newText {
                states = nfa.step(states, scalar)
                if states.isEmpty {
                    isDead = true
                    return false
                }
            }
            consumed = output
            return true
        }

        /// The text forced from the current position, up to `limit` characters. Empty when the next
        /// character is a free choice (inside a string value, enum branch point, end of output).
        public func forcedContinuation(limit: Int = 96) -> String {
            guard !isDead else { return "" }
            var current = states
            var forced = String.UnicodeScalarView()
            while forced.count < limit {
                if current.contains(nfa.accept) { break }
                guard let next = nfa.uniqueLiteral(from: current) else { break }
                forced.append(next)
                current = nfa.step(current, next)
                if current.isEmpty { break }
            }
            return String(forced)
        }
    }
}

// MARK: - Pattern AST

indirect enum Pattern: Sendable {
    case literal(String)
    case characterClass(CharacterPredicate)
    case sequence([Pattern])
    case alternation([Pattern])
    case optional(Pattern)
    case zeroOrMore(Pattern)
    case oneOrMore(Pattern)
    case repeated(Pattern, min: Int, max: Int)
}

struct CharacterPredicate: Sendable {
    let ranges: [ClosedRange<UInt32>]
    let negated: Bool

    func matches(_ scalar: Unicode.Scalar) -> Bool {
        let contained = ranges.contains { $0.contains(scalar.value) }
        return negated ? !contained : contained
    }

    /// A predicate that matches exactly one character.
    var singleScalar: Unicode.Scalar? {
        guard !negated, ranges.count == 1, ranges[0].lowerBound == ranges[0].upperBound else { return nil }
        return Unicode.Scalar(ranges[0].lowerBound)
    }

    static func scalar(_ scalar: Unicode.Scalar) -> CharacterPredicate {
        CharacterPredicate(ranges: [scalar.value...scalar.value], negated: false)
    }
}

/// The agent output language, mirroring `GrammarBuilder` exactly.
enum AgentOutputPattern {
    static func root(tools: [ToolSpec]) -> Pattern {
        .alternation([
            .sequence([.literal(#"{"type":"answer","speech":"#), string, .literal("}")]),
            .sequence([.literal(#"{"type":"clarification","speech":"#), string, .literal("}")]),
            .sequence([.literal(#"{"type":"unsupported","speech":"#), string, .literal("}")]),
            .sequence([.literal(#"{"type":"task","outcome":"#), string, .literal("}")]),
            .sequence([
                .literal(#"{"type":"proposed_action","#),
                .alternation(tools.map(call)),
                .literal("}"),
            ]),
        ])
    }

    static let character: Pattern = .alternation([
        .characterClass(CharacterPredicate(ranges: [0x22...0x22, 0x5C...0x5C, 0x00...0x1F, 0x7F...0x7F], negated: true)),
        .sequence([.literal("\\"), .characterClass(CharacterPredicate(ranges: [0x22...0x22, 0x5C...0x5C, 0x2F...0x2F], negated: false))]),
    ])

    static let string: Pattern = .sequence([.literal("\""), .oneOrMore(character), .literal("\"")])

    static let digit = CharacterPredicate(ranges: [0x30...0x39], negated: false)

    static let phone: Pattern = .sequence([
        .literal("\""),
        .optional(.literal("+")),
        .characterClass(digit),
        .zeroOrMore(.characterClass(CharacterPredicate(
            ranges: [0x30...0x39, 0x20...0x20, 0x28...0x29, 0x2D...0x2D, 0x2E...0x2E], negated: false))),
        .literal("\""),
    ])

    static let integer: Pattern = .sequence([
        .characterClass(CharacterPredicate(ranges: [0x31...0x39], negated: false)),
        .repeated(.characterClass(digit), min: 0, max: 3),
    ])

    static func call(_ tool: ToolSpec) -> Pattern {
        let plan = ArgumentPlan(tool: tool)
        return .sequence([
            .literal(#""tool":"\#(tool.id.rawValue)","arguments":{"#),
            arguments(plan, ArgumentPlan.State(index: 0, emitted: false, satisfied: plan.initiallySatisfied)),
            .literal(#"},"requires_confirmation":\#(tool.riskLevel.requiresConfirmation ? "true" : "false")"#),
        ])
    }

    static func argument(_ spec: ToolArgumentSpec) -> Pattern {
        let key = Pattern.literal(#""\#(spec.name)":"#)
        switch spec.kind {
        case .text: return .sequence([key, string])
        case .phoneNumber: return .sequence([key, phone])
        case .integer: return .sequence([key, integer])
        case let .choice(values):
            return .sequence([key, .literal("\""), .alternation(values.map { .literal($0) }), .literal("\"")])
        }
    }

    /// Same recursion as `GrammarBuilder.argumentRules` (via `ArgumentPlan`).
    static func arguments(_ plan: ArgumentPlan, _ state: ArgumentPlan.State) -> Pattern {
        let options = plan.transitions(from: state).map { transition -> Pattern in
            var parts: [Pattern] = []
            if let emitted = transition.emitted {
                if state.emitted { parts.append(.literal(",")) }
                parts.append(argument(emitted))
            }
            if let next = transition.next { parts.append(arguments(plan, next)) }
            return .sequence(parts)
        }
        return options.count == 1 ? options[0] : .alternation(options)
    }
}

// MARK: - Thompson NFA

final class NFA {
    private(set) var epsilon: [[Int]] = []
    private(set) var transitions: [[(CharacterPredicate, Int)]] = []
    private(set) var start = 0
    private(set) var accept = 0

    init(pattern: Pattern) {
        let fragment = build(pattern)
        start = fragment.start
        accept = fragment.end
    }

    private func newState() -> Int {
        epsilon.append([])
        transitions.append([])
        return epsilon.count - 1
    }

    private func build(_ pattern: Pattern) -> (start: Int, end: Int) {
        switch pattern {
        case let .literal(text):
            let first = newState()
            var current = first
            for scalar in text.unicodeScalars {
                let next = newState()
                transitions[current].append((.scalar(scalar), next))
                current = next
            }
            return (first, current)
        case let .characterClass(predicate):
            let first = newState()
            let end = newState()
            transitions[first].append((predicate, end))
            return (first, end)
        case let .sequence(parts):
            let first = newState()
            var current = first
            for part in parts {
                let fragment = build(part)
                epsilon[current].append(fragment.start)
                current = fragment.end
            }
            return (first, current)
        case let .alternation(options):
            let first = newState()
            let end = newState()
            for option in options {
                let fragment = build(option)
                epsilon[first].append(fragment.start)
                epsilon[fragment.end].append(end)
            }
            return (first, end)
        case let .optional(inner):
            let first = newState()
            let end = newState()
            let fragment = build(inner)
            epsilon[first].append(contentsOf: [fragment.start, end])
            epsilon[fragment.end].append(end)
            return (first, end)
        case let .zeroOrMore(inner):
            let first = newState()
            let end = newState()
            let fragment = build(inner)
            epsilon[first].append(contentsOf: [fragment.start, end])
            epsilon[fragment.end].append(contentsOf: [fragment.start, end])
            return (first, end)
        case let .oneOrMore(inner):
            let first = newState()
            let end = newState()
            let fragment = build(inner)
            epsilon[first].append(fragment.start)
            epsilon[fragment.end].append(contentsOf: [fragment.start, end])
            return (first, end)
        case let .repeated(inner, min, max):
            var parts: [Pattern] = Array(repeating: inner, count: min)
            parts.append(contentsOf: Array(repeating: .optional(inner), count: Swift.max(0, max - min)))
            return build(.sequence(parts))
        }
    }

    func closure(_ seeds: Set<Int>) -> Set<Int> {
        var result = seeds
        var stack = Array(seeds)
        while let state = stack.popLast() {
            for next in epsilon[state] where !result.contains(next) {
                result.insert(next)
                stack.append(next)
            }
        }
        return result
    }

    func step(_ states: Set<Int>, _ scalar: Unicode.Scalar) -> Set<Int> {
        var next = Set<Int>()
        for state in states {
            for (predicate, target) in transitions[state] where predicate.matches(scalar) {
                next.insert(target)
            }
        }
        return next.isEmpty ? next : closure(next)
    }

    /// The single literal character every outgoing transition requires, if there is exactly one.
    func uniqueLiteral(from states: Set<Int>) -> Unicode.Scalar? {
        var candidate: Unicode.Scalar?
        for state in states {
            for (predicate, _) in transitions[state] {
                guard let scalar = predicate.singleScalar else { return nil }
                if let existing = candidate, existing != scalar { return nil }
                candidate = scalar
            }
        }
        return candidate
    }
}
