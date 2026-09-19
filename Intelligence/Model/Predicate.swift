import Foundation

/// The closed vocabulary of things that can be said about the user's world.
///
/// This is to the intelligence what `ToolCatalog` is to actions: it generates the grammar the model
/// decodes under, validates every proposed memory, decides what supersedes what, and defines which
/// statements materialize onto an entity's columns. Nothing outside this list can enter the store.
///
/// Deliberately not `SafeLabelConvertible`: a predicate can be built from a runtime string (model
/// output, a stored row), and the telemetry vocabulary only admits compile-time-closed values.
public struct Predicate: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Relationships
    public static let worksOn = Predicate("works_on")
    public static let hasGoal = Predicate("has_goal")
    public static let hasTask = Predicate("has_task")
    public static let assignedTo = Predicate("assigned_to")
    public static let owedTo = Predicate("owed_to")
    public static let involves = Predicate("involves")
    public static let belongsTo = Predicate("belongs_to")
    public static let about = Predicate("about")
    public static let dependsOn = Predicate("depends_on")
    public static let attends = Predicate("attends")
    public static let derivedFrom = Predicate("derived_from")

    // Attributes
    public static let deadline = Predicate("deadline")
    public static let starts = Predicate("starts")
    public static let ends = Predicate("ends")
    public static let status = Predicate("status")
    public static let role = Predicate("role")
    public static let describes = Predicate("description")
    public static let outcome = Predicate("outcome")
    public static let rationale = Predicate("rationale")
    public static let location = Predicate("location")
    public static let progress = Predicate("progress")
    public static let note = Predicate("note")
    public static let preference = Predicate("preference")
    public static let alias = Predicate("alias")
}

public enum AssertionKind: String, Codable, Sendable, Hashable {
    /// subject → predicate → object entity (may also carry a value, e.g. a role).
    case relationship
    /// subject → predicate → value.
    case attribute
}

/// Which entity column a statement keeps up to date, if any.
public enum MaterializedField: String, Sendable, Codable {
    case dueAt, startsAt, endsAt, status, subtitle, projectID, importance, progress, aliases
}

public enum ValueKind: Sendable, Equatable {
    case none
    case text(maxLength: Int)
    /// A date the user expressed in words; Swift resolves the phrase, both are stored.
    case date
    case number(ClosedRange<Double>)
    case flag
}

public struct PredicateSpec: Sendable {
    public let predicate: Predicate
    public let kind: AssertionKind
    public let subjectKinds: Set<EntityKind>
    /// Empty for attributes.
    public let objectKinds: Set<EntityKind>
    public let valueKind: ValueKind
    /// At most one active statement per (subject, predicate[, object]): a new one supersedes.
    public let isFunctional: Bool
    public let materializes: MaterializedField?
    /// May the memory extractor propose this from a conversation?
    public let isLearnable: Bool
    /// How it reads in a sentence, for prompts and the memory inspector ("works on", "is due").
    public let phrase: String

    public var acceptsValue: Bool { valueKind != .none }
}

public enum PredicateCatalog {
    public static let all: [PredicateSpec] = [
        // MARK: Relationships
        PredicateSpec(predicate: .worksOn, kind: .relationship, subjectKinds: [.person], objectKinds: [.project],
                      valueKind: .text(maxLength: 60), isFunctional: false, materializes: nil, isLearnable: true,
                      phrase: "works on"),
        PredicateSpec(predicate: .hasGoal, kind: .relationship, subjectKinds: [.project], objectKinds: [.goal],
                      valueKind: .none, isFunctional: false, materializes: nil, isLearnable: true, phrase: "has the goal"),
        PredicateSpec(predicate: .hasTask, kind: .relationship, subjectKinds: [.project, .goal], objectKinds: [.task],
                      valueKind: .none, isFunctional: false, materializes: nil, isLearnable: true, phrase: "includes the task"),
        PredicateSpec(predicate: .assignedTo, kind: .relationship, subjectKinds: [.task], objectKinds: [.person],
                      valueKind: .none, isFunctional: true, materializes: nil, isLearnable: true, phrase: "is assigned to"),
        PredicateSpec(predicate: .owedTo, kind: .relationship, subjectKinds: [.commitment], objectKinds: [.person],
                      valueKind: .none, isFunctional: true, materializes: nil, isLearnable: true, phrase: "is owed to"),
        PredicateSpec(predicate: .involves, kind: .relationship, subjectKinds: [.event, .decision, .commitment],
                      objectKinds: [.person], valueKind: .none, isFunctional: false, materializes: nil, isLearnable: true,
                      phrase: "involves"),
        PredicateSpec(predicate: .belongsTo, kind: .relationship,
                      subjectKinds: [.goal, .task, .commitment, .decision, .event, .document, .artifact],
                      objectKinds: [.project], valueKind: .none, isFunctional: true, materializes: .projectID,
                      isLearnable: true, phrase: "belongs to"),
        PredicateSpec(predicate: .about, kind: .relationship, subjectKinds: [.document, .artifact, .source],
                      objectKinds: [.project, .goal, .person, .event], valueKind: .none, isFunctional: false,
                      materializes: nil, isLearnable: false, phrase: "is about"),
        PredicateSpec(predicate: .dependsOn, kind: .relationship, subjectKinds: [.task, .goal, .planStep],
                      objectKinds: [.task, .goal, .planStep], valueKind: .none, isFunctional: false, materializes: nil,
                      isLearnable: true, phrase: "depends on"),
        PredicateSpec(predicate: .attends, kind: .relationship, subjectKinds: [.person], objectKinds: [.event],
                      valueKind: .none, isFunctional: false, materializes: nil, isLearnable: true, phrase: "attends"),
        PredicateSpec(predicate: .derivedFrom, kind: .relationship, subjectKinds: [.artifact], objectKinds: [.source, .document],
                      valueKind: .none, isFunctional: false, materializes: nil, isLearnable: false, phrase: "came from"),

        // MARK: Attributes
        PredicateSpec(predicate: .deadline, kind: .attribute, subjectKinds: [.project, .goal, .task, .commitment, .plan],
                      objectKinds: [], valueKind: .date, isFunctional: true, materializes: .dueAt, isLearnable: true,
                      phrase: "is due"),
        PredicateSpec(predicate: .starts, kind: .attribute, subjectKinds: [.event, .task, .plan], objectKinds: [],
                      valueKind: .date, isFunctional: true, materializes: .startsAt, isLearnable: true, phrase: "starts"),
        PredicateSpec(predicate: .ends, kind: .attribute, subjectKinds: [.event, .task, .plan], objectKinds: [],
                      valueKind: .date, isFunctional: true, materializes: .endsAt, isLearnable: false, phrase: "ends"),
        PredicateSpec(predicate: .status, kind: .attribute, subjectKinds: Set(EntityKind.allCases), objectKinds: [],
                      valueKind: .text(maxLength: 20), isFunctional: true, materializes: .status, isLearnable: true,
                      phrase: "is"),
        PredicateSpec(predicate: .role, kind: .attribute, subjectKinds: [.person], objectKinds: [],
                      valueKind: .text(maxLength: 60), isFunctional: true, materializes: .subtitle, isLearnable: true,
                      phrase: "is responsible for"),
        PredicateSpec(predicate: .describes, kind: .attribute, subjectKinds: Set(EntityKind.allCases), objectKinds: [],
                      valueKind: .text(maxLength: 300), isFunctional: true, materializes: nil, isLearnable: true,
                      phrase: "is described as"),
        PredicateSpec(predicate: .outcome, kind: .attribute, subjectKinds: [.goal], objectKinds: [],
                      valueKind: .text(maxLength: 200), isFunctional: true, materializes: nil, isLearnable: true,
                      phrase: "should end with"),
        PredicateSpec(predicate: .rationale, kind: .attribute, subjectKinds: [.decision], objectKinds: [],
                      valueKind: .text(maxLength: 300), isFunctional: true, materializes: nil, isLearnable: true,
                      phrase: "because"),
        PredicateSpec(predicate: .location, kind: .attribute, subjectKinds: [.event], objectKinds: [],
                      valueKind: .text(maxLength: 120), isFunctional: true, materializes: nil, isLearnable: true,
                      phrase: "is at"),
        PredicateSpec(predicate: .progress, kind: .attribute, subjectKinds: [.goal, .project, .task], objectKinds: [],
                      valueKind: .number(0...1), isFunctional: true, materializes: .progress, isLearnable: false,
                      phrase: "is at"),
        PredicateSpec(predicate: .note, kind: .attribute, subjectKinds: Set(EntityKind.allCases), objectKinds: [],
                      valueKind: .text(maxLength: 300), isFunctional: false, materializes: nil, isLearnable: true,
                      phrase: "note"),
        PredicateSpec(predicate: .preference, kind: .attribute, subjectKinds: [.person], objectKinds: [],
                      valueKind: .text(maxLength: 200), isFunctional: false, materializes: nil, isLearnable: true,
                      phrase: "prefers"),
        PredicateSpec(predicate: .alias, kind: .attribute, subjectKinds: Set(EntityKind.allCases), objectKinds: [],
                      valueKind: .text(maxLength: 60), isFunctional: false, materializes: .aliases, isLearnable: true,
                      phrase: "is also called"),
    ]

    private static let index: [Predicate: PredicateSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.predicate, $0) })

    public static func spec(for predicate: Predicate) -> PredicateSpec? { index[predicate] }

    public static var learnable: [PredicateSpec] { all.filter(\.isLearnable) }

    /// Statements the model may propose about this kind of subject.
    public static func learnable(forSubject kind: EntityKind) -> [PredicateSpec] {
        learnable.filter { $0.subjectKinds.contains(kind) }
    }

    /// Validates the shape of a statement against the catalog; nil when it is legal.
    public static func violation(
        predicate: Predicate, subjectKind: EntityKind, objectKind: EntityKind?, value: AssertionValue?
    ) -> String? {
        guard let spec = index[predicate] else { return "unknown predicate \(predicate)" }
        guard spec.subjectKinds.contains(subjectKind) else {
            return "\(predicate) cannot describe a \(subjectKind.rawValue)"
        }
        switch spec.kind {
        case .relationship:
            guard let objectKind else { return "\(predicate) needs something to point at" }
            guard spec.objectKinds.contains(objectKind) else {
                return "\(predicate) cannot point at a \(objectKind.rawValue)"
            }
        case .attribute:
            if objectKind != nil { return "\(predicate) takes a value, not an entity" }
            guard let value else { return "\(predicate) needs a value" }
            // A status is only legal if the kind actually has it ("achieved" is a goal's, not a task's).
            if predicate == .status {
                guard let raw = value.textValue, let status = EntityStatus(rawValue: raw),
                      subjectKind.statuses.contains(status) else {
                    return "a \(subjectKind.rawValue) cannot be \(value.displayText)"
                }
            }
            switch (spec.valueKind, value) {
            case let (.text(maxLength), .text(text)):
                if text.isEmpty { return "\(predicate) value is empty" }
                if text.count > maxLength { return "\(predicate) value is too long" }
            case (.date, .date): break
            case let (.number(range), .number(number)):
                if !range.contains(number) { return "\(predicate) value out of range" }
            case (.flag, .flag): break
            case (.none, _): return "\(predicate) takes no value"
            default: return "\(predicate) got the wrong kind of value"
            }
        }
        if case .relationship = spec.kind, let value {
            if case let .text(text) = value, text.count > 60 { return "\(predicate) role is too long" }
        }
        return nil
    }
}
