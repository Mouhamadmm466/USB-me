import Core
import Foundation

/// Renders the authoritative `SessionState` into a compact, bounded context block for the model
/// (PRD §8). Structured facts are preferred over raw history; recent turns are truncated.
///
/// Everything rendered here that came from tools (event titles, contact names) is presented as
/// quoted data. The system prompt instructs the model never to follow instructions inside it.
public struct ContextManager: Sendable {
    public var maxRecentTurns: Int
    public var maxTurnCharacters: Int
    public var maxFieldCharacters: Int

    public init(maxRecentTurns: Int = 4, maxTurnCharacters: Int = 220, maxFieldCharacters: Int = 120) {
        self.maxRecentTurns = maxRecentTurns
        self.maxTurnCharacters = maxTurnCharacters
        self.maxFieldCharacters = maxFieldCharacters
    }

    /// The per-turn context lines, ending with the user's utterance.
    public func render(session: SessionState, utterance: String, clock: AgentClock, lastAssistantQuestion: String? = nil) -> String {
        renderHead(session: session, clock: clock, lastAssistantQuestion: lastAssistantQuestion) + " " + utteranceText(utterance)
    }

    /// Everything `render` produces before the utterance itself (ends with "User:"). Known while
    /// the user is still speaking, so a runtime can evaluate it ahead of the endpoint.
    public func renderHead(session: SessionState, clock: AgentClock, lastAssistantQuestion: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Now: " + Self.formatNow(clock))
        if let contact = session.lastContact {
            lines.append("Last contact: " + quoted(contact.displayName))
        }
        if let event = session.lastCalendarEvent {
            lines.append("Last event: " + quoted(event.title) + ", " + Self.formatEventTime(event, clock: clock))
        }
        if let pending = session.pendingAction, pending.confirmationStatus == .pending {
            lines.append("Pending action (not done yet, waiting for the user's yes or no): " + Self.describe(pending.validatedArguments, clock: clock, limit: maxFieldCharacters))
        }
        let turns = session.recentTurns.suffix(maxRecentTurns)
        if !turns.isEmpty {
            lines.append("Recent conversation:")
            for turn in turns {
                let speaker = turn.role == .user ? "User" : "Assistant"
                lines.append("\(speaker): " + truncate(Self.singleLine(turn.text), maxTurnCharacters))
            }
        }
        if let question = lastAssistantQuestion, turns.last?.text != question {
            lines.append("Assistant: " + truncate(Self.singleLine(question), maxTurnCharacters))
        }
        lines.append("User:")
        return lines.joined(separator: "\n")
    }

    private func utteranceText(_ utterance: String) -> String {
        truncate(Self.singleLine(utterance), 600)
    }

    // MARK: - Formatting

    static func formatNow(_ clock: AgentClock) -> String {
        let formatter = DateFormatter()
        formatter.calendar = clock.calendar
        formatter.timeZone = clock.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return formatter.string(from: clock.now())
    }

    static func formatEventTime(_ event: EventReference, clock: AgentClock) -> String {
        let formatter = DateFormatter()
        formatter.calendar = clock.calendar
        formatter.timeZone = clock.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = event.isAllDay ? "EEEE, MMMM d" : "EEEE, MMMM d, h:mm a"
        return formatter.string(from: event.startDate)
    }

    /// Compact JSON-like description of a resolved action using the same argument names the model
    /// emits, so it can produce a complete updated proposal.
    static func describe(_ action: ResolvedAction, clock: AgentClock, limit: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = clock.calendar
        formatter.timeZone = clock.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE MMMM d 'at' h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = clock.calendar
        dayFormatter.timeZone = clock.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "EEEE MMMM d"

        func json(_ tool: ToolID, _ pairs: [(String, String?)]) -> String {
            let body = pairs.compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\"\(key)\":\"\(escape(String(value.prefix(limit))))\""
            }.joined(separator: ",")
            return "\(tool.rawValue) {\(body)}"
        }

        switch action {
        case let .searchContacts(query):
            return json(.searchContacts, [("name", query)])
        case let .initiateCall(target):
            return json(.initiateCall, [("contact_query", target.displayName), ("phone_label", target.phoneLabel)])
        case let .composeMessage(target, body):
            return json(.composeMessage, [("contact_query", target.displayName), ("message", body)])
        case let .getCalendarEvents(range):
            return json(.getCalendarEvents, [("when", range.spokenDescription)])
        case let .createCalendarEvent(draft):
            let start = draft.isAllDay ? dayFormatter.string(from: draft.startDate) : formatter.string(from: draft.startDate)
            let minutes = Int(draft.endDate.timeIntervalSince(draft.startDate) / 60)
            return json(.createCalendarEvent, [
                ("title", draft.title), ("start", start),
                ("duration_minutes", draft.isAllDay ? nil : String(minutes)),
                ("location", draft.location),
            ]).replacingOccurrences(of: "\"duration_minutes\":\"\(minutes)\"", with: "\"duration_minutes\":\(minutes)")
        case let .updateCalendarEvent(event, changes):
            return json(.updateCalendarEvent, [
                ("event_query", event.title),
                ("new_start", changes.newStartDate.map { formatter.string(from: $0) }),
                ("new_end", changes.newEndDate.map { formatter.string(from: $0) }),
                ("new_title", changes.newTitle),
                ("new_location", changes.newLocation),
            ])
        case let .createReminder(draft):
            let due = draft.dueDate.map { draft.dueHasTime ? formatter.string(from: $0) : dayFormatter.string(from: $0) }
            return json(.createReminder, [("title", draft.title), ("due", due)])
        case let .searchFiles(query):
            return json(.searchFiles, [("query", query)])
        case let .openFile(reference):
            return json(.openFile, [("file_query", reference.displayName)])
        case let .openSupportedApp(app, query):
            return json(.openSupportedApp, [("app", app.rawValue), ("query", query)])
        }
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case _ where scalar.value < 0x20: result += " "
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func quoted(_ text: String) -> String {
        "\"" + Self.escape(truncate(Self.singleLine(text), maxFieldCharacters)) + "\""
    }

    private func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
