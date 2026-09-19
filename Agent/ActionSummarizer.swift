import Core
import Foundation

/// Deterministic, exact descriptions of actions and results. The spoken confirmation and the
/// visual card are generated here from the *resolved* action — never from model prose — so the
/// user hears and sees exactly what will run (recipient, number, date/time, content).
public struct ActionSummarizer: Sendable {
    public let clock: AgentClock

    public init(clock: AgentClock) {
        self.clock = clock
    }

    // MARK: - Confirmation prompts

    public func confirmationPrompt(for action: ResolvedAction) -> String {
        switch action {
        case let .composeMessage(target, body):
            return "Text \(recipient(target)): \u{201C}\(body)\u{201D} Should I send it?"
        case let .initiateCall(target):
            if target.contactIdentifier == nil {
                return "Should I call \(spokenNumber(target.phoneNumber))?"
            }
            if let label = target.phoneLabel {
                return "Should I call \(target.displayName) on \(label)?"
            }
            return "Should I call \(target.displayName)?"
        case let .createCalendarEvent(draft):
            var text = "Add \u{201C}\(draft.title)\u{201D} \(eventWhen(draft.startDate, draft.endDate, allDay: draft.isAllDay))"
            if let location = draft.location { text += " at \(location)" }
            return text + ". Should I add it?"
        case let .updateCalendarEvent(event, changes):
            return updateDescription(event, changes) + ". Should I update it?"
        case let .createReminder(draft):
            var text = "Remind you to \u{201C}\(draft.title)\u{201D}"
            if let due = draft.dueDate {
                text += draft.dueHasTime ? " \(dayPhrase(due)) at \(time(due))" : " \(dayPhrase(due))"
            }
            return text + ". Should I create it?"
        case let .searchContacts(query):
            return "Look up \(query)?"
        case let .getCalendarEvents(range):
            return "Check your calendar for \(range.spokenDescription)?"
        case let .searchFiles(query):
            return "Search your files for \(query)?"
        case let .openFile(reference):
            return "Open \(reference.displayName)?"
        case let .openSupportedApp(app, _):
            return "Open \(app.displayName)?"
        }
    }

    public func actionCard(for pending: PendingAction) -> ActionCard {
        let action = pending.validatedArguments
        var fields: [ActionCard.Field] = []
        let title: String, image: String, confirm: String
        var footnote: String?
        switch action {
        case let .composeMessage(target, body):
            title = "Send message"; image = "message.fill"; confirm = "Send"
            fields = [.init(label: "To", value: target.displayName),
                      .init(label: "Number", value: numberWithLabel(target)),
                      .init(label: "Message", value: body)]
            footnote = "Messages opens with this text. You tap Send to finish."
        case let .initiateCall(target):
            title = "Call"; image = "phone.fill"; confirm = "Call"
            fields = [.init(label: "To", value: target.displayName), .init(label: "Number", value: numberWithLabel(target))]
            footnote = "iPhone may ask you to confirm the call."
        case let .createCalendarEvent(draft):
            title = "Add to calendar"; image = "calendar.badge.plus"; confirm = "Add"
            fields = [.init(label: "Event", value: draft.title),
                      .init(label: "When", value: cardWhen(draft.startDate, draft.endDate, allDay: draft.isAllDay))]
            if let location = draft.location { fields.append(.init(label: "Where", value: location)) }
        case let .updateCalendarEvent(event, changes):
            title = "Update event"; image = "calendar"; confirm = "Update"
            fields = [.init(label: "Event", value: event.title),
                      .init(label: "Now", value: cardWhen(event.startDate, event.endDate, allDay: event.isAllDay))]
            let newStart = changes.newStartDate ?? event.startDate
            let newEnd = changes.newEndDate ?? (changes.newStartDate.map { $0.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate)) } ?? event.endDate)
            if changes.newStartDate != nil || changes.newEndDate != nil {
                fields.append(.init(label: "New time", value: cardWhen(newStart, newEnd, allDay: staysAllDay(event, changes))))
            }
            if let newTitle = changes.newTitle { fields.append(.init(label: "New name", value: newTitle)) }
            if let newLocation = changes.newLocation { fields.append(.init(label: "New place", value: newLocation)) }
        case let .createReminder(draft):
            title = "Create reminder"; image = "checklist"; confirm = "Create"
            fields = [.init(label: "Reminder", value: draft.title)]
            if let due = draft.dueDate {
                fields.append(.init(label: "Due", value: draft.dueHasTime ? "\(shortDay(due)), \(time(due))" : shortDay(due)))
            }
        default:
            title = "Confirm"; image = "checkmark.circle"; confirm = "Continue"
            fields = [.init(label: "Action", value: confirmationPrompt(for: action))]
        }
        return ActionCard(id: pending.id, version: pending.version, tool: pending.tool, title: title, systemImage: image,
                          fields: fields, confirmLabel: confirm, riskLevel: pending.riskLevel, expiresAt: pending.expiresAt,
                          footnote: footnote)
    }

    // MARK: - Results (only what actually happened)

    public func resultSpeech(_ result: ToolResult, for action: ResolvedAction) -> String {
        switch result {
        case let .success(outcome):
            return successSpeech(outcome)
        case let .cancelledByUser(tool):
            switch tool {
            case .composeMessage: return "Okay, the message wasn't sent."
            case .initiateCall: return "Okay, I didn't place the call."
            default: return "Okay, I stopped."
            }
        case let .failure(failure):
            return failureSpeech(failure)
        }
    }

    public func resultBanner(_ result: ToolResult, for action: ResolvedAction) -> ResultBanner {
        switch result {
        case let .success(outcome):
            let (text, image) = bannerSuccess(outcome)
            return ResultBanner(style: .success, text: text, systemImage: image)
        case .cancelledByUser:
            return ResultBanner(style: .cancelled, text: resultSpeech(result, for: action), systemImage: "xmark.circle")
        case .failure:
            return ResultBanner(style: .failure, text: resultSpeech(result, for: action), systemImage: "exclamationmark.triangle")
        }
    }

    func successSpeech(_ outcome: ToolOutcome) -> String {
        switch outcome {
        case let .messageSent(target):
            return "Sent to \(target.displayName)."
        case let .callStarted(target):
            return target.contactIdentifier == nil ? "Calling \(spokenNumber(target.phoneNumber))." : "Calling \(target.displayName)."
        case let .eventCreated(event):
            return "Done. \u{201C}\(event.title)\u{201D} is on your calendar \(eventWhenShort(event))."
        case let .eventUpdated(event):
            return "Done. \u{201C}\(event.title)\u{201D} is now \(eventWhenShort(event))."
        case let .reminderCreated(draft):
            if let due = draft.dueDate {
                return "Done. I'll remind you to \(draft.title) \(dayPhrase(due))" + (draft.dueHasTime ? " at \(time(due))." : ".")
            }
            return "Done. I added a reminder to \(draft.title)."
        case let .eventsListed(events, range):
            return eventsSpeech(events, range: range)
        case let .contactsFound(contacts):
            return contactsSpeech(contacts)
        case let .filesFound(files):
            if files.isEmpty { return "I didn't find any matching files in the folders you shared." }
            let names = files.prefix(3).map(\.reference.displayName)
            let more = files.count > 3 ? ", and \(files.count - 3) more" : ""
            return "I found \(files.count == 1 ? "one file" : "\(files.count) files"): \(list(names))\(more)."
        case let .fileOpened(reference):
            return "Opening \(reference.displayName)."
        case let .appOpened(app):
            return "Opening \(app.displayName)."
        }
    }

    func failureSpeech(_ failure: ToolFailure) -> String {
        switch failure.code {
        case .permissionDenied:
            return "I don't have permission to use your \(Self.permissionNoun(failure.tool)). You can allow it in Settings."
        case .notAvailableOnDevice:
            switch failure.tool {
            case .composeMessage: return "This iPhone can't send text messages right now."
            case .initiateCall: return "This iPhone can't make phone calls right now."
            default: return "That isn't available on this iPhone."
            }
        case .notFound: return "I couldn't find that."
        case .invalidArguments: return "Something about that request wasn't valid, so I didn't do it."
        case .confirmationMismatch: return "That confirmation didn't match the current request, so I didn't do anything."
        case .expired: return "That request expired, so I didn't do it. Please ask again."
        case .systemError: return "Something went wrong, so I couldn't do that."
        case .unsupported: return "I can't do that yet."
        case .timeout: return "That took too long, so I stopped."
        case .noAuthorizedScope: return "Choose a folder to share with me first, in Settings."
        }
    }

    static func permissionNoun(_ tool: ToolID) -> String {
        switch tool {
        case .searchContacts, .initiateCall, .composeMessage: "contacts"
        case .getCalendarEvents, .createCalendarEvent, .updateCalendarEvent: "calendar"
        case .createReminder: "reminders"
        case .searchFiles, .openFile: "files"
        case .openSupportedApp: "apps"
        }
    }

    func eventsSpeech(_ events: [EventReference], range: DateRange) -> String {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        switch sorted.count {
        case 0:
            return "You have nothing on your calendar \(range.spokenDescription)."
        case 1:
            return "You have one event \(range.spokenDescription): \u{201C}\(sorted[0].title)\u{201D} \(eventTimeOnly(sorted[0]))."
        default:
            let listed = sorted.prefix(3).map { "\u{201C}\($0.title)\u{201D} \(eventTimeOnly($0))" }
            let more = sorted.count > 3 ? ", and \(sorted.count - 3) more" : ""
            return "You have \(sorted.count) events \(range.spokenDescription): \(list(listed))\(more)."
        }
    }

    func contactsSpeech(_ contacts: [ContactSummary]) -> String {
        switch contacts.count {
        case 0: return "I couldn't find that person in your contacts."
        case 1:
            let contact = contacts[0]
            guard let phone = contact.phoneNumbers.first else { return "\(contact.displayName) doesn't have a phone number saved." }
            let label = phone.label.map { " \($0)" } ?? ""
            return "\(contact.displayName)'s\(label) number is \(spokenNumber(phone.number))."
        default:
            let names = contacts.prefix(4).map(\.displayName)
            return "I found \(contacts.count) people: \(list(names))."
        }
    }

    func bannerSuccess(_ outcome: ToolOutcome) -> (String, String) {
        switch outcome {
        case let .messageSent(target): ("Message sent to \(target.displayName)", "checkmark.message.fill")
        case let .callStarted(target): ("Calling \(target.displayName)", "phone.arrow.up.right.fill")
        case let .eventCreated(event): ("Added \u{201C}\(event.title)\u{201D}", "calendar.badge.checkmark")
        case let .eventUpdated(event): ("Updated \u{201C}\(event.title)\u{201D}", "calendar.badge.checkmark")
        case let .reminderCreated(draft): ("Reminder: \(draft.title)", "checklist.checked")
        case let .eventsListed(events, _): ("\(events.count) event\(events.count == 1 ? "" : "s")", "calendar")
        case let .contactsFound(contacts): ("\(contacts.count) contact\(contacts.count == 1 ? "" : "s")", "person.crop.circle")
        case let .filesFound(files): ("\(files.count) file\(files.count == 1 ? "" : "s")", "doc.text.magnifyingglass")
        case let .fileOpened(reference): ("Opened \(reference.displayName)", "doc.fill")
        case let .appOpened(app): ("Opened \(app.displayName)", "arrow.up.forward.app")
        }
    }

    // MARK: - Formatting helpers

    func recipient(_ target: ContactTarget) -> String {
        target.contactIdentifier == nil ? spokenNumber(target.phoneNumber) : target.displayName
    }

    func numberWithLabel(_ target: ContactTarget) -> String {
        let number = formattedNumber(target.phoneNumber)
        guard let label = target.phoneLabel else { return number }
        return "\(number) (\(label))"
    }

    /// "5550104477" → "555-010-4477"; "+15550104477" → "+1 555-010-4477".
    public func formattedNumber(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        let plus = raw.hasPrefix("+") ? "+" : ""
        switch digits.count {
        case 10:
            let d = Array(digits)
            return "\(plus)\(String(d[0..<3]))-\(String(d[3..<6]))-\(String(d[6..<10]))"
        case 11 where digits.hasPrefix("1"):
            let d = Array(digits)
            return "\(plus)1 \(String(d[1..<4]))-\(String(d[4..<7]))-\(String(d[7..<11]))"
        case 7:
            let d = Array(digits)
            return "\(String(d[0..<3]))-\(String(d[3..<7]))"
        default:
            return plus + digits
        }
    }

    func spokenNumber(_ raw: String) -> String { formattedNumber(raw) }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = clock.calendar
        formatter.timeZone = clock.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// "3 PM", "3:30 PM".
    func time(_ date: Date) -> String {
        let minute = clock.calendar.component(.minute, from: date)
        return formatter(minute == 0 ? "h a" : "h:mm a").string(from: date)
    }

    /// "today", "tomorrow", "on Friday, September 25".
    func dayPhrase(_ date: Date) -> String {
        let calendar = clock.calendar
        let now = clock.now()
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        return "on " + formatter("EEEE, MMMM d").string(from: date)
    }

    func shortDay(_ date: Date) -> String {
        let calendar = clock.calendar
        let now = clock.now()
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return formatter("EEE, MMM d").string(from: date)
    }

    func eventWhen(_ start: Date, _ end: Date, allDay: Bool) -> String {
        if allDay { return "\(dayPhrase(start)), all day" }
        if clock.calendar.isDate(start, inSameDayAs: end) {
            return "\(dayPhrase(start)) from \(time(start)) to \(time(end))"
        }
        return "\(dayPhrase(start)) at \(time(start)) until \(dayPhrase(end)) at \(time(end))"
    }

    func eventWhenShort(_ event: EventReference) -> String {
        event.isAllDay ? dayPhrase(event.startDate) : "\(dayPhrase(event.startDate)) at \(time(event.startDate))"
    }

    func eventTimeOnly(_ event: EventReference) -> String {
        event.isAllDay ? "all day" : "at \(time(event.startDate))"
    }

    func cardWhen(_ start: Date, _ end: Date, allDay: Bool) -> String {
        if allDay { return "\(shortDay(start)), all day" }
        if clock.calendar.isDate(start, inSameDayAs: end) {
            return "\(shortDay(start)), \(time(start)) – \(time(end))"
        }
        return "\(shortDay(start)) \(time(start)) – \(shortDay(end)) \(time(end))"
    }

    /// An all-day event moved to a clock time becomes a timed event (as `CalendarStore` applies
    /// it), so the read-back must say the time.
    func staysAllDay(_ event: EventReference, _ changes: EventChanges) -> Bool {
        guard event.isAllDay else { return false }
        return [changes.newStartDate, changes.newEndDate].compactMap { $0 }.allSatisfy { clock.calendar.startOfDay(for: $0) == $0 }
    }

    func updateDescription(_ event: EventReference, _ changes: EventChanges) -> String {
        var parts: [String] = []
        if let newStart = changes.newStartDate {
            let duration = event.endDate.timeIntervalSince(event.startDate)
            let newEnd = changes.newEndDate ?? newStart.addingTimeInterval(duration)
            parts.append("move \u{201C}\(event.title)\u{201D} to \(eventWhen(newStart, newEnd, allDay: staysAllDay(event, changes)))")
        } else if let newEnd = changes.newEndDate {
            parts.append("change \u{201C}\(event.title)\u{201D} to end at \(time(newEnd))")
        }
        if let newTitle = changes.newTitle {
            parts.append(parts.isEmpty ? "rename \u{201C}\(event.title)\u{201D} to \u{201C}\(newTitle)\u{201D}" : "rename it \u{201C}\(newTitle)\u{201D}")
        }
        if let newLocation = changes.newLocation {
            parts.append(parts.isEmpty ? "change the place of \u{201C}\(event.title)\u{201D} to \(newLocation)" : "set the place to \(newLocation)")
        }
        let sentence = parts.isEmpty ? "update \u{201C}\(event.title)\u{201D}" : list(parts)
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
