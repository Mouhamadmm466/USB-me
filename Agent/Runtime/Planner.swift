import Core
import Foundation
import Intelligence
import LLM
import Telemetry

/// Turns a request into a plan the user can look at before anything happens.
///
/// The model chooses steps and fills parameters; Swift chooses the scope, decides what is
/// available, validates every step and owns the order. A plan is always a proposal — nothing in it
/// runs until the user says go.
public struct Planner: Sendable {
    public let model: any LanguageModel
    public let registry: CapabilityRegistry
    public var maximumOutputTokens: Int
    private let logger: PrivacySafeLogger?

    public init(
        model: any LanguageModel,
        registry: CapabilityRegistry = .all,
        maximumOutputTokens: Int = 380,
        logger: PrivacySafeLogger? = nil
    ) {
        self.model = model
        self.registry = registry
        self.maximumOutputTokens = maximumOutputTokens
        self.logger = logger
    }

    public func plan(
        for request: String,
        context: String? = nil,
        availability: CapabilityAvailability = .offline,
        subjectID: UUID? = nil,
        /// Names of things the request mentions. A project called "call Bob" must not put calling
        /// in scope just because the user said its name.
        mentionedNames: [String] = [],
        now: Date = Date()
    ) async throws -> Plan {
        let playbook = PlaybookLibrary.match(request)
        let scope = PlaybookLibrary.scope(for: request, playbook: playbook, excluding: mentionedNames)
        // The grammar is built from what this job may use *and* what can run right now, so an
        // unavailable capability cannot be planned and then fail at the last moment.
        let usable = registry.scoped(to: scope).specs.filter(availability.isAvailable)
        guard !usable.isEmpty else { throw PlanValidationError.noSteps }
        let scoped = CapabilityRegistry(specs: usable)

        let llmRequest = LLMRequest(
            cacheablePrefix: Self.prefix(),
            suffix: Self.suffix(
                request: request, context: context, playbook: playbook, registry: scoped
            ),
            grammar: PlanContract.grammar(for: scoped, maximumSteps: playbook.maximumSteps),
            maxOutputTokens: maximumOutputTokens,
            draftSources: [request, context ?? ""]
        )

        var output = ""
        let watch = Stopwatch()
        for try await event in model.generate(llmRequest) {
            if case let .text(delta) = event { output += delta }
        }
        logger?.log(.stageLatency(stage: .llmTotal, milliseconds: Int(watch.elapsedMilliseconds)))

        let validator = PlanValidator(
            registry: scoped, availability: availability, maximumSteps: playbook.maximumSteps
        )
        var plan = try validator.validate(
            output, request: request, scope: usable.map(\.id.rawValue), subjectID: subjectID, now: now
        )
        plan.stepBudget = playbook.maximumSteps
        return plan
    }

    // MARK: Prompt

    /// The static half. Separate from the turn prefix, and cheap to switch to: the runtime keeps
    /// both prefix states in memory (`NemotronRuntime`), so planning never costs the next turn its
    /// warm prefix.
    public static func prefix() -> String {
        let instructions = """
        You plan jobs for a private assistant that runs entirely on the user's iPhone. Read the \
        request and reply with exactly one JSON object: a short title and the steps to take.

        Rules:
        1. Use only the capabilities listed in the request. Nothing else exists.
        2. Steps run in the order you write them; a later step may use what an earlier one found.
        3. Write the fewest steps that actually do the job. Two good steps beat five vague ones.
        4. "why" is one short line the user will read in the plan: what this step is for.
        5. Copy names, dates and phrases from the user's own words. Never invent a person, a file or a date.
        6. Only ask the user something when the job cannot continue without it.
        7. Reply with the JSON object only.
        """
        var text = "<|im_start|>system\n" + instructions + "<|im_end|>\n"
        for example in examples {
            text += "<|im_start|>user\n" + example.user + "<|im_end|>\n"
            text += "<|im_start|>assistant\n<think></think>" + example.output + "<|im_end|>\n"
        }
        return text
    }

    static func suffix(
        request: String, context: String?, playbook: Playbook, registry: CapabilityRegistry
    ) -> String {
        var lines = ["Capabilities:", PlanContract.promptSection(for: registry)]
        lines.append("How this kind of job usually goes: \(playbook.guidance)")
        if let context, !context.isEmpty {
            lines.append(context)
        }
        lines.append("Request: " + request.replacingOccurrences(of: "\n", with: " "))
        return "<|im_start|>user\n" + lines.joined(separator: "\n") + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    struct Example: Sendable {
        let user: String
        let output: String
    }

    static let examples: [Example] = [
        Example(
            user: """
            Capabilities:
            - search_knowledge(query): Search the documents the user has shared with you.
            - write_artifact(title, kind, about): Write something for the user to read and keep.
            Request: what does the syllabus say about the midterm, and make me a study plan
            """,
            output: #"{"title":"Midterm study plan","steps":[{"do":"search_knowledge","why":"Find what the midterm covers","arguments":{"query":"midterm date and topics"}},{"do":"write_artifact","why":"Write the plan","arguments":{"title":"Midterm study plan","kind":"plan","about":"what to study each day before the midterm"}}]}"#
        ),
        Example(
            user: """
            Capabilities:
            - search_intelligence(query): Look up what is known about the user's projects and people.
            - get_calendar_events(when?): Read the user's calendar.
            - write_artifact(title, kind, about): Write something for the user to read and keep.
            Request: prep me for tomorrow's beta review
            """,
            output: #"{"title":"Beta review prep","steps":[{"do":"get_calendar_events","why":"Check the time and who is coming","arguments":{"when":"tomorrow"}},{"do":"search_intelligence","why":"Pull what is open on the beta","arguments":{"query":"beta"}},{"do":"write_artifact","why":"One page to read before the room","arguments":{"title":"Beta review brief","kind":"brief","about":"status, open work, decisions to make"}}]}"#
        ),
    ]
}
