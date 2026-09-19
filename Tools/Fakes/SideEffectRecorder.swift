import Core
import Foundation

/// One observable effect performed through a fake adapter.
public enum SideEffect: Sendable, Equatable {
    /// The message composer was presented and closed with `outcome`.
    case messageComposed(recipients: [String], body: String, outcome: MessageComposeOutcome)
    case callStarted(digits: String)
    case eventCreated(EventDraft)
    case eventUpdated(id: String, changes: EventChanges)
    case reminderCreated(ReminderDraft)
    case fileOpened(FileReference)
    case appOpened(SupportedApp, query: String?)

    /// Messages, calls and calendar/reminder writes (risk ≥ 1). A composer that was cancelled or
    /// failed still counts: the system UI was presented.
    public var isConsequential: Bool {
        switch self {
        case .messageComposed, .callStarted, .eventCreated, .eventUpdated, .reminderCreated: true
        case .fileOpened, .appOpened: false
        }
    }
}

/// Shared, ordered log of everything the fakes did, so tests and the evaluation harness can
/// assert exactly what happened.
public actor SideEffectRecorder {
    public private(set) var effects: [SideEffect] = []

    public init() {}

    public func record(_ effect: SideEffect) {
        effects.append(effect)
    }

    public var consequentialEffects: [SideEffect] { effects.filter(\.isConsequential) }

    public var count: Int { effects.count }

    public func reset() {
        effects.removeAll()
    }
}
