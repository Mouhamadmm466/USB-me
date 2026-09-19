import Core
import Foundation

/// Deterministic English renderings of events for clarification questions and candidates.
/// Always `en_US_POSIX` in the clock's calendar and time zone.
public enum EventFormatting {
    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Compact form for cards and candidate lists: "Mon Sep 21 at 10:00 AM" / "Mon Sep 21, all day".
    public static func compactWhen(_ event: EventReference, calendar: Calendar) -> String {
        let day = formatter("EEE MMM d", calendar: calendar).string(from: event.startDate)
        if event.isAllDay { return "\(day), all day" }
        let time = formatter("h:mm a", calendar: calendar).string(from: event.startDate)
        return "\(day) at \(time)"
    }

    /// "Team sync, Mon Sep 21 at 10:00 AM".
    public static func candidateText(_ event: EventReference, calendar: Calendar) -> String {
        "\(displayTitle(event)), \(compactWhen(event, calendar: calendar))"
    }

    /// Spoken form: "Monday, September 21 at 10 AM" / "Monday, September 21 at 10:30 AM" /
    /// "Monday, September 21, all day".
    public static func spokenWhen(_ event: EventReference, calendar: Calendar) -> String {
        let day = formatter("EEEE, MMMM d", calendar: calendar).string(from: event.startDate)
        if event.isAllDay { return "\(day), all day" }
        return "\(day) at \(spokenTime(event.startDate, calendar: calendar))"
    }

    /// "10 AM", "10:30 AM".
    public static func spokenTime(_ date: Date, calendar: Calendar) -> String {
        let minute = calendar.component(.minute, from: date)
        return formatter(minute == 0 ? "h a" : "h:mm a", calendar: calendar).string(from: date)
    }

    static func displayTitle(_ event: EventReference) -> String {
        let title = TextSanitizer.clean(event.title, allowNewlines: false)
        return title.isEmpty ? "Untitled event" : title
    }
}
