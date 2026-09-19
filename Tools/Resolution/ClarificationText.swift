import Core
import Foundation

/// Every question the resolver can ask. Deterministic, short, natural spoken English, built only
/// from native data (contact names, event titles, labels) and the user's own words.
public enum ClarificationText {
    public enum Purpose: Sendable {
        case call, message, lookup

        var verb: String {
            switch self {
            case .call: "call"
            case .message: "message"
            case .lookup: "look up"
            }
        }

        var numberVerb: String {
            switch self {
            case .call: "call"
            case .message, .lookup: "text"
            }
        }
    }

    // MARK: Lists

    /// "A", "A and B", "A, B, and C".
    public static func andList(_ items: [String]) -> String { list(items, conjunction: "and") }

    /// "A", "A or B", "A, B, or C".
    public static func orList(_ items: [String]) -> String { list(items, conjunction: "or") }

    private static func list(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) \(items[items.count - 1])"
        }
    }

    /// The user's words, cleaned and shortened for echoing back.
    static func echo(_ text: String, maxLength: Int = 60) -> String {
        let cleaned = TextSanitizer.clean(text, allowNewlines: false)
        guard cleaned.count > maxLength else { return cleaned }
        let cut = cleaned.prefix(maxLength)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return String(cut)
    }

    /// Maximum number of options read aloud in one question.
    static let maxSpokenOptions = 3

    // MARK: Contacts

    public static let whoDoYouMean = "Who do you mean?"
    public static let whoToLookUp = "Who should I look up?"

    public static func whoTo(_ purpose: Purpose) -> String { "Who should I \(purpose.verb)?" }

    public static func contactNotFound(_ name: String, purpose: Purpose) -> String {
        "I couldn't find \(echo(name)) in your contacts. Who should I \(purpose.verb)?"
    }

    public static func contactAmbiguous(names: [String], query: String) -> String {
        if Set(names.map(TextTokens.fold)).count == 1, let name = names.first {
            return "I found \(names.count) contacts named \(name). Which one?"
        }
        if names.count > maxSpokenOptions {
            return "I found \(names.count) contacts named \(echo(query)). Which one?"
        }
        return "I found \(andList(names)). Which one?"
    }

    public static func contactHasNoPhone(_ name: String, purpose: Purpose) -> String {
        "\(name) doesn't have a phone number. What number should I \(purpose.numberVerb)?"
    }

    public static func whichNumber(for name: String, options: [String]) -> String {
        "Which number for \(name): \(orList(options))?"
    }

    public static func missingLabel(_ label: PhoneLabel, for name: String, options: [String]) -> String {
        if options.count == 1 {
            return "I don't see a \(label.rawValue) number for \(name). Should I use \(options[0])?"
        }
        return "I don't see a \(label.rawValue) number for \(name). Which one: \(orList(options))?"
    }

    public static func numberNotHeard(_ purpose: Purpose) -> String {
        "I didn't catch the number. What number should I \(purpose.numberVerb)?"
    }

    // MARK: Messages

    public static let whatShouldMessageSay = "What should the message say?"
    public static let messageTooLong = "That message is too long. What should it say?"

    // MARK: Calendar

    public static let eventTitleMissing = "What should I call the event?"
    public static let eventTitleTooLong = "That title is too long. What should I call the event?"
    public static let whenToSchedule = "What day and time should I schedule it for?"
    public static let whenToScheduleUnclear = "I didn't catch when. What day and time should I schedule it for?"
    public static let startTimeNeeded = "What time should it start?"
    public static let endUnclear = "When should it end?"
    public static let endTimeNeeded = "What time should it end?"
    public static let endBeforeStart = "The end time is before the start. When should it end?"
    public static let howLong = "How long should it be?"
    public static let whichDayToCheck = "Which day should I check?"
    public static let whenToMove = "When should I move it to?"
    public static let whatToChange = "What should I change?"
    public static let locationTooLong = "That place is too long. Where should it be?"
    public static let whichEvent = "Which event do you mean?"
    public static let eventGone = "I couldn't find that event anymore. Which event do you mean?"

    public static func eventNotFound(_ query: String) -> String {
        "I couldn't find \(echo(query)) on your calendar. Which event do you mean?"
    }

    /// Titles when they differ; "Which Team sync: Monday… or Tuesday…?" when they are the same.
    public static func eventAmbiguous(_ events: [EventReference], query: String, calendar: Calendar) -> String {
        let titles = events.map(EventFormatting.displayTitle)
        let foldedTitles = titles.map(TextTokens.fold)
        if Set(foldedTitles).count == 1, let title = titles.first {
            if events.count > maxSpokenOptions {
                return "I found \(events.count) \(title) events. Which one?"
            }
            let whens = events.map { EventFormatting.spokenWhen($0, calendar: calendar) }
            return "Which \(title): \(orList(whens))?"
        }
        if events.count > maxSpokenOptions {
            return "I found \(events.count) events matching \(echo(query)). Which one?"
        }
        if Set(foldedTitles).count == foldedTitles.count {
            return "I found \(andList(titles)). Which one?"
        }
        let described = events.map { "\(EventFormatting.displayTitle($0)) on \(EventFormatting.spokenWhen($0, calendar: calendar))" }
        return "I found \(andList(described)). Which one?"
    }

    // MARK: Reminders

    public static let reminderTitleMissing = "What should I remind you about?"
    public static let reminderTitleTooLong = "That's too long for a reminder. What should I remind you about?"
    public static let reminderWhenUnclear = "When should I remind you?"

    // MARK: Files

    public static let whichFileToOpen = "Which file should I open?"
    public static let whatFileToFind = "What file should I look for?"

    public static func fileNotFound(_ query: String) -> String {
        "I couldn't find \(echo(query)) in your shared folders. What's the file called?"
    }

    public static func fileAmbiguous(names: [String], query: String) -> String {
        if names.count > maxSpokenOptions {
            return "I found \(names.count) files matching \(echo(query)). Which one?"
        }
        return "I found \(andList(names)). Which one?"
    }
}
