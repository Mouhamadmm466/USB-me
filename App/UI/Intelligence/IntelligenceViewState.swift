import Foundation
import Intelligence

/// Everything the V2 screens draw, already formatted.
///
/// The screens never touch the store, a calendar or a formatter: by the time state reaches them,
/// every date is a phrase, every count is a number and every sentence is the deterministic one the
/// intelligence itself would say. That keeps the views previewable and the wording in one place.
struct IntelligenceViewState: Equatable {
    /// A piece of the user's world in a list: a task, a goal, an event, a person.
    struct Item: Identifiable, Equatable {
        let id: UUID
        var title: String
        /// "due Friday", "part of Beta launch", "design lead".
        var meta: String?
        var kind: EntityKind
        var tone: Tone
        var systemImage: String
        var isOverdue = false
    }

    /// Something that needs the user, with the reason it is being raised.
    struct AttentionRow: Identifiable, Equatable {
        let id: UUID
        var title: String
        var reason: String
        var kind: AttentionKind
        var tone: Tone
        var systemImage: String
        var entityID: UUID?
    }

    /// Something the system wants to keep but has not been told it may.
    struct Question: Identifiable, Equatable {
        let id: UUID
        var sentence: String
        var explanation: String
        /// What it would replace, when the question is a contradiction rather than a guess.
        var replaces: String?
    }

    struct ProjectRow: Identifiable, Equatable {
        let id: UUID
        var title: String
        var status: String
        var tone: Tone
        var openWork: Int
        var commitments: Int
        var people: [String]
        var nextDue: String?
        var nextDueTitle: String?
        /// The next thing due has already passed.
        var isLate = false
    }

    struct ActivityRow: Identifiable, Equatable {
        let id: UUID
        var kind: ActivityKind
        var headline: String
        var detail: String?
        /// "just now", "2 hours ago", "Tuesday".
        var timeText: String
        var canUndo: Bool
        var isUndone: Bool
        var entityID: UUID?
    }

    /// The sources the user has let the world model read, and what they have brought in.
    struct Ingestion: Equatable {
        var calendar = false
        var reminders = false
        /// "42 events, 18 reminders" — what is currently held from those sources.
        var summary: String?
        /// True while a sync is running.
        var isSyncing = false
    }

    /// A document the user brought in.
    struct DocumentRow: Identifiable, Equatable {
        let id: UUID
        var title: String
        /// "12 pages · shared · today".
        var meta: String
    }

    /// The My Intelligence tab: what is held, and the controls over it.
    struct Memory: Equatable {
        struct KindCount: Identifiable, Equatable {
            var id: EntityKind { kind }
            var kind: EntityKind
            var count: Int
        }

        var kinds: [KindCount] = []
        var facts = 0
        var questions = 0
        var inferred = 0
        var sizeText = "0 KB"
        var learningEnabled = true
        var confirmInferences = true
        /// Results of the current search, empty when the field is empty.
        var results: [Item] = []
        var searchText = ""
        var documents: [DocumentRow] = []
        /// What the world model is allowed to feed itself from.
        var ingestion = Ingestion()
        /// Set while a file is being read and indexed.
        var isImporting = false
        /// Why the last import failed, in the user's words.
        var importError: String?
    }

    var attention: [AttentionRow] = []
    var overdue: [Item] = []
    var today: [Item] = []
    var soon: [Item] = []
    var questions: [Question] = []
    var projects: [ProjectRow] = []
    var activity: [ActivityRow] = []
    var memory = Memory()
    /// False until the first snapshot arrives, so Home can hold its shape instead of flashing empty.
    var isLoaded = false

    var hasAnything: Bool {
        !attention.isEmpty || !questions.isEmpty || !projects.isEmpty || !activity.isEmpty
    }

    static let empty = IntelligenceViewState()
}

/// What the person can ask of the V2 screens. As with the assistant screen, the views decide
/// nothing — they report intents.
struct IntelligenceIntents {
    var confirm: @MainActor (_ questionID: UUID) -> Void = { _ in }
    var reject: @MainActor (_ questionID: UUID) -> Void = { _ in }
    var undo: @MainActor (_ activityID: UUID) -> Void = { _ in }
    var openEntity: @MainActor (_ entityID: UUID) -> Void = { _ in }
    var search: @MainActor (_ text: String) -> Void = { _ in }
    var setLearningEnabled: @MainActor (_ enabled: Bool) -> Void = { _ in }
    var setConfirmInferences: @MainActor (_ enabled: Bool) -> Void = { _ in }
    var addDocument: @MainActor () -> Void = {}
    /// Let the world model read the calendar, or stop it and take back what it brought.
    var setCalendarIngestion: @MainActor (_ enabled: Bool) -> Void = { _ in }
    var setReminderIngestion: @MainActor (_ enabled: Bool) -> Void = { _ in }
    var forgetDocument: @MainActor (_ documentID: UUID) -> Void = { _ in }
    var exportEverything: @MainActor () -> Void = {}
    var deleteEverything: @MainActor () -> Void = {}
    var refresh: @MainActor () async -> Void = {}

    /// Does nothing (previews and the design gallery).
    static let inert = IntelligenceIntents()
}

// MARK: - Display vocabulary

extension EntityKind {
    /// One SF Symbol per kind, used everywhere the kind is shown. Filled variants throughout:
    /// at 17 pt an outline glyph next to text reads as noise, a filled one reads as a mark.
    var systemImage: String {
        switch self {
        case .person: "person.fill"
        case .project: "folder.fill"
        case .goal: "target"
        case .task: "checkmark.circle.fill"
        case .commitment: "hand.raised.fill"
        case .decision: "arrow.triangle.branch"
        case .event: "calendar"
        case .document: "doc.fill"
        case .artifact: "doc.text.fill"
        case .source: "link"
        case .connection: "antenna.radiowaves.left.and.right"
        case .plan: "list.bullet.rectangle.fill"
        case .planStep: "arrow.forward.circle.fill"
        case .conversation: "bubble.left.and.bubble.right.fill"
        }
    }

    var plural: String {
        switch self {
        case .person: "People"
        case .project: "Projects"
        case .goal: "Goals"
        case .task: "Tasks"
        case .commitment: "Commitments"
        case .decision: "Decisions"
        case .event: "Events"
        case .document: "Documents"
        case .artifact: "Artifacts"
        case .source: "Sources"
        case .connection: "Connections"
        case .plan: "Plans"
        case .planStep: "Steps"
        case .conversation: "Conversations"
        }
    }
}

extension AttentionKind {
    /// The symbol says *why* this is being raised, not what kind of thing it is — a late task and
    /// a late promise are both, first, late.
    var systemImage: String {
        switch self {
        case .overdue: "clock.badge.exclamationmark.fill"
        case .today: "clock.fill"
        case .promise: "hand.raised.fill"
        case .unstarted: "circle.dashed"
        case .approaching: "calendar.badge.clock"
        case .question: "questionmark.bubble.fill"
        case .stale: "pause.circle.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .overdue, .promise: .danger
        case .today: .clay
        case .unstarted: .amber
        case .approaching: .neutral
        case .question: .sky
        case .stale: .neutral
        }
    }
}

extension ActivityKind {
    var systemImage: String {
        switch self {
        case .learned: "sparkles"
        case .asked: "questionmark.circle"
        case .confirmed: "checkmark.circle"
        case .corrected: "arrow.uturn.backward"
        case .ended: "clock.arrow.circlepath"
        case .imported: "tray.and.arrow.down"
        case .acted: "bolt"
        }
    }

    var tone: Tone {
        switch self {
        case .learned: .clay
        case .asked: .sky
        case .confirmed: .clay
        case .corrected, .ended: .neutral
        case .imported: .sky
        case .acted: .amber
        }
    }
}
