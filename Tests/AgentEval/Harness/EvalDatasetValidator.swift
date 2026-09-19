import Core
import Foundation

/// One inconsistency in the dataset (not in the agent).
public struct EvalDatasetIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Rule: String, Sendable, CaseIterable {
        /// `now` / `timezone` malformed.
        case caseClock
        /// Empty utterance or empty outcome list.
        case emptyTurn
        /// recipient_id / event_id / file_id / contact_result_ids / recipient_phone not in the fixture.
        case unknownReference
        /// A read-only tool expecting confirmation, or a consequential tool executing without a
        /// pending confirmation.
        case toolOutcome
        /// side_effects not cumulative, jumping, or incremented by something other than an
        /// executed consequential action.
        case sideEffects
        /// pending_version without a pending outcome, or not following 1, n+1 (modification), n.
        case pendingVersion
        /// clarification_reason without a clarification outcome.
        case clarificationReason
        /// release_safety without safety limits, or safety limits contradicting the turns.
        case safety
        /// Malformed or inverted date expectations.
        case dateFormat
        /// A dictated number (recipient_phone without recipient_id) that the user never said.
        case dictatedNumber
        /// Two cases with the same sequence of user utterances.
        case duplicateTurns
        /// Fixture-level problems (duplicate ids, inverted events, numbers without digits).
        case fixture
    }

    public let rule: Rule
    public let caseID: String?
    /// Zero-based turn index.
    public let turn: Int?
    public let message: String

    public init(rule: Rule, caseID: String?, turn: Int?, message: String) {
        self.rule = rule
        self.caseID = caseID
        self.turn = turn
        self.message = message
    }

    public var description: String {
        var prefix = "[\(rule.rawValue)]"
        if let caseID { prefix += " \(caseID)" }
        if let turn { prefix += " turn \(turn + 1)" }
        return "\(prefix): \(message)"
    }
}

/// Structural and policy-consistency checks over the dataset itself. The runner can call
/// `validate` before a run; `AgentEvalTests` asserts it reports nothing.
public enum EvalDatasetValidator {
    static let pendingOutcomes: Set<ObservedOutcome> = [.confirmationRequested, .reprompted, .deferred]

    public static func validate(_ dataset: EvalDataset) -> [EvalDatasetIssue] {
        var issues: [EvalDatasetIssue] = []
        for fixture in dataset.fixtures.values.sorted(by: { $0.id < $1.id }) {
            issues += validate(fixture: fixture)
        }
        var seenTurns: [[String]: String] = [:]
        for evalCase in dataset.cases {
            if let fixture = dataset.fixture(for: evalCase) {
                issues += validate(evalCase, fixture: fixture)
            }
            let utterances = evalCase.turns.map(\.user)
            if let other = seenTurns[utterances] {
                issues.append(EvalDatasetIssue(rule: .duplicateTurns, caseID: evalCase.id, turn: nil,
                                               message: "same user turns as \(other)"))
            } else {
                seenTurns[utterances] = evalCase.id
            }
        }
        return issues
    }

    public static func validate(fixture: EvalFixture) -> [EvalDatasetIssue] {
        var issues: [EvalDatasetIssue] = []
        func issue(_ message: String) {
            issues.append(EvalDatasetIssue(rule: .fixture, caseID: "fixture:\(fixture.id)", turn: nil, message: message))
        }
        let contactIDs = fixture.contacts.map(\.id)
        if Set(contactIDs).count != contactIDs.count { issue("duplicate contact ids") }
        let eventIDs = fixture.events.map(\.id)
        if Set(eventIDs).count != eventIDs.count { issue("duplicate event ids") }
        let paths = fixture.files.map(\.path)
        if Set(paths).count != paths.count { issue("duplicate file paths (file ids)") }
        for contact in fixture.contacts {
            for phone in contact.phones {
                if ArgumentComparator.digits(phone.number).count < 3 {
                    issue("contact \(contact.id) has a phone number without digits: \(phone.number)")
                }
                if let label = phone.label, PhoneLabel(rawValue: label) == nil {
                    issue("contact \(contact.id) uses unknown phone label \(label)")
                }
            }
        }
        for event in fixture.events {
            guard EvalTime.isDateTime(event.start), EvalTime.isDateTime(event.end) else {
                issue("event \(event.id) has malformed times \(event.start) / \(event.end)")
                continue
            }
            if event.end <= event.start { issue("event \(event.id) ends before it starts") }
        }
        for file in fixture.files where file.modified.map({ !EvalTime.isDateTime($0) }) ?? false {
            issue("file \(file.path) has a malformed modified date")
        }
        let statuses = Set(["notDetermined", "granted", "denied", "restricted", "limited"])
        let kinds = Set(PermissionKind.allCases.map(\.rawValue))
        for (kind, status) in fixture.permissions.merging(fixture.permissionResponses ?? [:], uniquingKeysWith: { a, _ in a }) {
            if !kinds.contains(kind) { issue("unknown permission kind \(kind)") }
            if !statuses.contains(status) { issue("unknown permission status \(status)") }
        }
        return issues
    }

    public static func validate(_ evalCase: EvalCase, fixture: EvalFixture) -> [EvalDatasetIssue] {
        var issues: [EvalDatasetIssue] = []
        func issue(_ rule: EvalDatasetIssue.Rule, _ turn: Int?, _ message: String) {
            issues.append(EvalDatasetIssue(rule: rule, caseID: evalCase.id, turn: turn, message: message))
        }

        if evalCase.timeZoneValue == nil { issue(.caseClock, nil, "unknown time zone \(evalCase.timezone)") }
        if EvalTime.parse(evalCase.now)?.precision != .minute || evalCase.now.count != 19 {
            issue(.caseClock, nil, "now must be YYYY-MM-DDTHH:MM:SS, got \(evalCase.now)")
        }
        if evalCase.turns.isEmpty { issue(.emptyTurn, nil, "case has no turns") }

        let contacts = Dictionary(uniqueKeysWithValues: fixture.contacts.map { ($0.id, $0) })
        let eventIDs = Set(fixture.events.map(\.id))
        let files = Dictionary(uniqueKeysWithValues: fixture.files.map { ($0.path, $0) })
        let authorizedScopes = Set(fixture.authorizedFileScopes)

        var pendingVersion: Int?
        var previousSideEffects = 0
        var spokenDigits = ""

        for (index, turn) in evalCase.turns.enumerated() {
            let expect = turn.expect
            let outcomes = Set(expect.outcome)
            spokenDigits += " " + ArgumentComparator.digits(turn.user)
            if turn.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue(.emptyTurn, index, "empty utterance") }
            if expect.outcome.isEmpty { issue(.emptyTurn, index, "no accepted outcome") }

            // Tool / outcome consistency.
            let risk = expect.tool.map { ToolCatalog.spec(for: $0).riskLevel }
            if let risk, !risk.requiresConfirmation, outcomes.contains(.confirmationRequested) {
                issue(.toolOutcome, index, "read-only tool \(expect.tool!.rawValue) must execute without confirmation")
            }
            let consequentialExecution = outcomes.contains(.executed) && (risk?.requiresConfirmation ?? false)
            if consequentialExecution {
                if pendingVersion == nil {
                    issue(.toolOutcome, index, "\(expect.tool!.rawValue) executes without a pending confirmation in an earlier turn")
                }
                if outcomes.count > 1 {
                    issue(.toolOutcome, index, "a consequential execution must be the only accepted outcome")
                }
            }

            // Side effects: cumulative, +1 only on a confirmed consequential execution.
            if let sideEffects = expect.sideEffects {
                if sideEffects < previousSideEffects {
                    issue(.sideEffects, index, "side_effects decreased from \(previousSideEffects) to \(sideEffects)")
                } else if sideEffects > previousSideEffects {
                    if sideEffects - previousSideEffects > 1 { issue(.sideEffects, index, "side_effects jumped by more than 1") }
                    if !consequentialExecution { issue(.sideEffects, index, "side_effects increased without a consequential execution") }
                } else if consequentialExecution {
                    issue(.sideEffects, index, "consequential execution must increment side_effects")
                }
                previousSideEffects = sideEffects
            }

            // Clarification reason.
            if expect.clarificationReason != nil, !outcomes.contains(.clarificationRequested) {
                issue(.clarificationReason, index, "clarification_reason without clarification_requested")
            }

            // Pending version: 1 for a new action, n+1 for a modification, n while pending.
            if let version = expect.pendingVersion {
                if outcomes.isDisjoint(with: Self.pendingOutcomes) {
                    issue(.pendingVersion, index, "pending_version without a pending outcome")
                } else if outcomes.isSubset(of: Self.pendingOutcomes) {
                    let expected: Int
                    if outcomes == [.confirmationRequested] {
                        expected = (pendingVersion ?? 0) + 1
                    } else {
                        expected = pendingVersion ?? 1
                    }
                    if version != expected {
                        issue(.pendingVersion, index, "pending_version \(version), expected \(expected)")
                    }
                }
            }
            if outcomes.isSubset(of: Self.pendingOutcomes), !outcomes.isEmpty {
                pendingVersion = expect.pendingVersion ?? pendingVersion ?? 1
            } else if consequentialExecution || outcomes == [.cancelled] || outcomes.contains(.executed) {
                pendingVersion = nil
            } else if !outcomes.isDisjoint(with: Self.pendingOutcomes) {
                pendingVersion = nil // ambiguous branch (e.g. confirmation or clarification): no carried state
            }

            // References and dates.
            if let args = expect.args {
                if let id = args.recipientID, contacts[id] == nil { issue(.unknownReference, index, "unknown contact \(id)") }
                for id in args.contactResultIDs ?? [] where contacts[id] == nil {
                    issue(.unknownReference, index, "unknown contact \(id) in contact_result_ids")
                }
                if let id = args.eventID, !eventIDs.contains(id) { issue(.unknownReference, index, "unknown event \(id)") }
                if let id = args.fileID {
                    if let file = files[id] {
                        if !authorizedScopes.contains(file.scope) {
                            issue(.unknownReference, index, "file \(id) is outside the authorized scopes")
                        }
                    } else {
                        issue(.unknownReference, index, "unknown file \(id)")
                    }
                }
                if let phone = args.recipientPhone {
                    if phone != ArgumentComparator.digits(phone) || phone.isEmpty {
                        issue(.unknownReference, index, "recipient_phone must be digits only: \(phone)")
                    }
                    if let id = args.recipientID, let contact = contacts[id] {
                        if !contact.phones.contains(where: { ArgumentComparator.digits($0.number) == phone }) {
                            issue(.unknownReference, index, "recipient_phone \(phone) is not a number of \(id)")
                        }
                    } else if args.recipientID == nil, !spokenDigits.contains(phone) {
                        issue(.dictatedNumber, index, "dictated number \(phone) never appears in the user's words")
                    }
                }
                for (field, value) in [("start", args.start), ("end", args.end), ("new_start", args.newStart),
                                       ("new_end", args.newEnd), ("range_start", args.rangeStart), ("range_end", args.rangeEnd)] {
                    if let value, !EvalTime.isDateTime(value) {
                        issue(.dateFormat, index, "\(field) must be YYYY-MM-DDTHH:MM, got \(value)")
                    }
                }
                if let due = args.due {
                    switch args.dueDateOnly {
                    case true?: if !EvalTime.isDate(due) { issue(.dateFormat, index, "date-only due must be YYYY-MM-DD, got \(due)") }
                    case false?: if !EvalTime.isDateTime(due) { issue(.dateFormat, index, "timed due must be YYYY-MM-DDTHH:MM, got \(due)") }
                    case nil: if !EvalTime.isDate(due) && !EvalTime.isDateTime(due) { issue(.dateFormat, index, "malformed due \(due)") }
                    }
                }
                if let start = args.start, let end = args.end, EvalTime.isDateTime(start), EvalTime.isDateTime(end), end <= start {
                    issue(.dateFormat, index, "end \(end) is not after start \(start)")
                }
                if let start = args.rangeStart, let end = args.rangeEnd, end <= start {
                    issue(.dateFormat, index, "range_end \(end) is not after range_start \(start)")
                }
                if let minutes = args.durationMinutes, !(5...1440).contains(minutes) {
                    issue(.dateFormat, index, "duration_minutes \(minutes) outside 5...1440")
                }
            }
        }

        // Safety limits.
        let finalSideEffects = evalCase.turns.compactMap(\.expect.sideEffects).last ?? 0
        if evalCase.isReleaseSafety {
            let safety = evalCase.safety
            if safety?.forbidSideEffects != true && safety?.maxSideEffects == nil {
                issue(.safety, nil, "release_safety case without forbid_side_effects or max_side_effects")
            }
        }
        if evalCase.safety?.forbidSideEffects == true, finalSideEffects > 0 {
            issue(.safety, nil, "forbid_side_effects but the turns expect \(finalSideEffects) side effect(s)")
        }
        if let maximum = evalCase.safety?.maxSideEffects, finalSideEffects > maximum {
            issue(.safety, nil, "max_side_effects \(maximum) is below the expected \(finalSideEffects)")
        }
        return issues
    }
}
