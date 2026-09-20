import Core
import Foundation

/// A shape of job the agent knows how to do, with the capabilities it is allowed to use.
///
/// Playbooks exist because a 4B model plans badly from a blank page and well from a strong prior.
/// They also decide scope: a research job cannot reach `compose_message`, so nothing a web page or
/// a document says can turn into a message to somebody. Scope is derived from the user's request
/// before the model runs, and is never widened by anything the job reads.
public struct Playbook: Sendable, Equatable {
    public let id: String
    public let title: String
    /// Phrases in the user's request that pick this playbook.
    public let triggers: [String]
    public let scope: [CapabilityID]
    /// What a good plan for this job looks like. Goes in the planner's prompt, not the grammar.
    public let guidance: String
    public let maximumSteps: Int

    public func allows(_ id: CapabilityID) -> Bool { scope.contains(id) }
}

public enum PlaybookLibrary {
    /// Reading the user's own world and documents: safe for every job, on every playbook.
    static let localReads: [CapabilityID] = [
        .searchKnowledge, .readDocument, .searchIntelligence,
        CapabilityID(.getCalendarEvents), CapabilityID(.searchFiles), CapabilityID(.searchContacts),
    ]

    public static let all: [Playbook] = [
        Playbook(
            id: "research",
            title: "Look something up",
            triggers: ["look up", "research", "find out", "what does", "what do we know", "summarize", "summarise"],
            scope: localReads + [.writeArtifact, .askUser],
            guidance: """
            Find what is already known before writing anything. Read the user's own documents first, \
            then what is known about their projects and people. Write one artifact at the end only if \
            the answer is worth keeping.
            """,
            maximumSteps: 5
        ),
        Playbook(
            id: "meeting_prep",
            title: "Prepare for something",
            triggers: ["prepare", "prep", "get ready", "before the meeting", "agenda", "brief me"],
            scope: localReads + [.writeArtifact, .remember, .askUser],
            guidance: """
            Gather what the user will need in the room: the event itself, who is involved, what was \
            decided before, what is outstanding. Finish with a short brief they can read in a minute.
            """,
            maximumSteps: 6
        ),
        Playbook(
            id: "project_update",
            title: "Sum up where a project is",
            triggers: ["where are we", "status", "update on", "how is", "progress on", "catch me up"],
            scope: localReads + [.writeArtifact, .remember, .askUser],
            guidance: """
            Pull together the project's open work, its deadlines, its people and anything promised. \
            Say what changed and what is next, not everything that exists.
            """,
            maximumSteps: 5
        ),
        Playbook(
            id: "study_plan",
            title: "Make a plan of work",
            triggers: ["study plan", "plan for", "schedule for", "break down", "how should i", "what should i work on"],
            scope: localReads + [.writeArtifact, .remember, CapabilityID(.createReminder), .askUser],
            guidance: """
            Work back from the deadline. Use what the documents say is covered and what the user has \
            already done. Produce dated, specific steps — never "study more".
            """,
            maximumSteps: 6
        ),
        Playbook(
            id: "general",
            title: "Do something",
            triggers: [],
            scope: localReads + [.writeArtifact, .askUser],
            guidance: """
            Take the shortest route to the thing the user actually asked for. Prefer reading what is \
            already known over asking. Ask only when the job genuinely cannot continue without it.
            """,
            maximumSteps: 5
        ),
    ]

    public static func playbook(id: String) -> Playbook? { all.first { $0.id == id } }

    /// The playbook whose trigger the request matches, or the general one.
    public static func match(_ request: String) -> Playbook {
        let text = " " + request.lowercased() + " "
        let matched = all
            .filter { !$0.triggers.isEmpty }
            .first { $0.triggers.contains { text.contains($0) } }
        return matched ?? all.last!
    }

    /// The capabilities a job may use: the playbook's own, plus anything the user explicitly asked
    /// for in their request.
    ///
    /// Asking to "text Sarah the summary" is what puts `compose_message` in scope — and even then it
    /// is risk 2, so it still stops for confirmation at the moment of sending. Nothing the job reads
    /// can add to this list.
    /// - Parameter excluding: names of things the request mentions (a project called "call Bob",
    ///   a document titled "Text Sarah"). They are removed before triggers are matched, so quoting
    ///   the name of something can never widen what a job may do.
    public static func scope(for request: String, playbook: Playbook, excluding names: [String] = []) -> [String] {
        var scope = Set(playbook.scope.map(\.rawValue))
        var stripped = request.lowercased()
        for name in names.map({ $0.lowercased() }).sorted(by: { $0.count > $1.count }) where name.count > 2 {
            stripped = stripped.replacingOccurrences(of: name, with: " ")
        }
        let text = " " + stripped + " "
        for (id, phrases) in requestedCapabilities where phrases.contains(where: { text.contains($0) }) {
            scope.insert(id.rawValue)
        }
        // Registry order, so the grammar and the prompt list capabilities the same way every time.
        return CapabilityRegistry.all.specs.map(\.id.rawValue).filter(scope.contains)
    }

    /// Capabilities the user has to ask for by name before a job may use them at all.
    private static let requestedCapabilities: [CapabilityID: [String]] = [
        CapabilityID(.composeMessage): ["text ", "message ", "send them", "send her", "send him", "let them know", "tell "],
        CapabilityID(.initiateCall): ["call ", "ring ", "phone "],
        CapabilityID(.createCalendarEvent): ["schedule", "put it in my calendar", "book ", "add to my calendar"],
        CapabilityID(.updateCalendarEvent): ["move the", "reschedule", "change the meeting"],
        CapabilityID(.createReminder): ["remind me", "reminder", "don't let me forget"],
        CapabilityID(.openFile): ["open the", "show me the file"],
        CapabilityID(.openSupportedApp): ["open maps", "open music", "open settings"],
    ]
}
