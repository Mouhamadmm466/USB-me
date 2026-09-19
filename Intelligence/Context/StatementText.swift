import Foundation

/// Turns a stored statement back into the sentence a person would say.
///
/// Deterministic and shared by the memory inspector, the activity feed and the questions the
/// assistant asks, so the same fact always reads the same way — and the model never writes any of
/// these sentences.
public enum StatementText {
    public static func sentence(
        _ assertion: Assertion,
        subject: IntelligenceEntity,
        object: IntelligenceEntity? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let spec = PredicateCatalog.spec(for: assertion.predicate)
        let phrase = spec?.phrase ?? assertion.predicate.rawValue.replacingOccurrences(of: "_", with: " ")
        var parts = [subject.title, phrase]
        if let object { parts.append(object.title) }
        if let value = assertion.value {
            switch value {
            case let .date(date, storedPhrase):
                parts.append(storedPhrase ?? ContextFormatter(now: now, calendar: calendar).day(date))
            case .text, .number, .flag:
                parts.append(object == nil ? value.displayText : "(\(value.displayText))")
            }
        }
        return parts.joined(separator: " ")
    }

    /// The same statement as a yes-or-no question: "Is Sarah responsible for design?"
    public static func question(
        _ assertion: Assertion,
        subject: IntelligenceEntity,
        object: IntelligenceEntity? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let statement = sentence(assertion, subject: subject, object: object, now: now, calendar: calendar)
        return statement.hasSuffix("?") ? statement : statement + "?"
    }
}

/// A statement waiting on the user, ready to display: the sentence, why it is being asked, and
/// what it would replace if they say yes.
public struct PendingQuestion: Identifiable, Sendable, Equatable {
    public var id: UUID { assertion.id }
    public var assertion: Assertion
    public var sentence: String
    public var explanation: String
    /// The statement this one contradicts, when the question is a conflict rather than a guess.
    public var conflictsWith: String?

    public init(assertion: Assertion, sentence: String, explanation: String, conflictsWith: String? = nil) {
        self.assertion = assertion
        self.sentence = sentence
        self.explanation = explanation
        self.conflictsWith = conflictsWith
    }
}

/// A project as the Projects tab shows it: the entity plus the few numbers that say how it is going.
public struct ProjectSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { project.id }
    public var project: IntelligenceEntity
    public var openWork: Int
    public var nextDue: Date?
    public var nextDueTitle: String?
    public var people: [IntelligenceEntity]
    public var openCommitments: Int

    public init(
        project: IntelligenceEntity, openWork: Int, nextDue: Date?, nextDueTitle: String?,
        people: [IntelligenceEntity], openCommitments: Int
    ) {
        self.project = project
        self.openWork = openWork
        self.nextDue = nextDue
        self.nextDueTitle = nextDueTitle
        self.people = people
        self.openCommitments = openCommitments
    }
}

/// Everything Home needs in one read, so the screen never issues queries of its own.
public struct IntelligenceSnapshot: Sendable, Equatable {
    public var overdue: [IntelligenceEntity] = []
    public var today: [IntelligenceEntity] = []
    public var soon: [IntelligenceEntity] = []
    public var projects: [ProjectSummary] = []
    public var questions: [PendingQuestion] = []
    public var activity: [ActivityEntry] = []
    public var counts: IntelligenceCounts = IntelligenceCounts(
        entities: [:], activeAssertions: 0, proposedAssertions: 0, inferredAssertions: 0, sizeBytes: 0
    )

    public var isEmpty: Bool {
        overdue.isEmpty && today.isEmpty && soon.isEmpty && projects.isEmpty && questions.isEmpty && activity.isEmpty
    }
}
