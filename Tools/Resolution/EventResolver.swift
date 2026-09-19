import Core
import Foundation

/// Resolves a spoken `event_query` to one native event.
struct EventResolver {
    enum Outcome {
        case event(EventReference)
        case clarification(reason: ClarificationReason, question: String, candidates: [ClarificationCandidate])
        case failure(ToolFailureCode)
    }

    /// Search window around "now" for title matches.
    static let lookBack: TimeInterval = 86_400
    static let lookAhead: TimeInterval = 60 * 86_400
    static let maxCandidates = 8

    let store: any CalendarStore
    let parser: any DateParsing
    let calendar: Calendar

    /// Order: pinned selection (an event id), pronoun/deictic → the session's last event, otherwise
    /// title-word search in [now − 1 day, now + 60 days].
    func resolve(query: String?, pinned: ClarificationCandidate?, session: SessionState, now: Date) async -> Outcome {
        do {
            if let pinned, pinned.kind == .event {
                if let event = try await store.event(identifier: pinned.identifier) { return .event(event) }
                return .clarification(reason: .eventNotFound, question: ClarificationText.eventGone, candidates: [])
            }
            guard let query else {
                return .clarification(reason: .missingField, question: ClarificationText.whichEvent, candidates: [])
            }
            let reference = EventMatcher.classify(query)
            if reference != .search, let last = session.lastCalendarEvent {
                if let event = try await store.event(identifier: last.eventIdentifier) { return .event(event) }
                return .clarification(reason: .eventNotFound, question: ClarificationText.eventGone, candidates: [])
            }
            if reference == .pronoun {
                return .clarification(reason: .eventNotFound, question: ClarificationText.whichEvent, candidates: [])
            }

            let window = DateInterval(start: now.addingTimeInterval(-Self.lookBack), end: now.addingTimeInterval(Self.lookAhead))
            let ranked = EventMatcher.rank(query: query, events: try await store.events(in: window), now: now)
            guard let topScore = ranked.first?.score else {
                let question = reference == .deictic ? ClarificationText.whichEvent : ClarificationText.eventNotFound(query)
                return .clarification(reason: .eventNotFound, question: question, candidates: [])
            }
            var best = ranked.filter { $0.score == topScore }
            if best.count > 1, let residual = EventMatcher.residualPhrase(query: query, events: best) {
                let narrowed = narrow(best, byDatePhrase: residual)
                if !narrowed.isEmpty { best = narrowed }
            }
            if best.count == 1 { return .event(best[0].event) }

            let events = best.map(\.event)
            return .clarification(
                reason: .eventAmbiguous,
                question: ClarificationText.eventAmbiguous(events, query: query, calendar: calendar),
                candidates: events.prefix(Self.maxCandidates).map(candidate)
            )
        } catch {
            return .failure(ToolAdapterError.failureCode(for: error))
        }
    }

    /// Keeps the events that fall on a day/range or start at a time named in the leftover words
    /// ("tomorrow's standup", "the 3 pm meeting").
    private func narrow(_ scored: [EventMatcher.Scored], byDatePhrase residual: String) -> [EventMatcher.Scored] {
        var phrases = [residual]
        let words = residual.split(separator: " ").map(String.init)
        if let first = words.first, ["on", "at", "for", "from", "in"].contains(first), words.count > 1 {
            phrases.append(words.dropFirst().joined(separator: " "))
        }
        for phrase in phrases {
            if let range = parser.parseRange(phrase) {
                let inRange = scored.filter { $0.event.startDate < range.end && $0.event.endDate > range.start }
                if !inRange.isEmpty { return inRange }
            }
            if let instant = parser.parseDateTime(phrase) {
                let matching: [EventMatcher.Scored]
                if !instant.hasTime {
                    matching = scored.filter { calendar.isDate($0.event.startDate, inSameDayAs: instant.date) }
                } else if DatePhraseClassifier.isTimeOnly(phrase) {
                    let wanted = calendar.dateComponents([.hour, .minute], from: instant.date)
                    matching = scored.filter {
                        !$0.event.isAllDay && calendar.dateComponents([.hour, .minute], from: $0.event.startDate) == wanted
                    }
                } else {
                    matching = scored.filter { abs($0.event.startDate.timeIntervalSince(instant.date)) < 60 }
                }
                if !matching.isEmpty { return matching }
            }
        }
        return []
    }

    private func candidate(_ event: EventReference) -> ClarificationCandidate {
        let weekday = formatted(event.startDate, "EEEE")
        let monthDay = formatted(event.startDate, "MMMM d")
        var terms = [EventFormatting.displayTitle(event), weekday, formatted(event.startDate, "EEE"), monthDay]
        if event.isAllDay {
            terms.append("all day")
        } else {
            terms += [EventFormatting.spokenTime(event.startDate, calendar: calendar), formatted(event.startDate, "h:mm a")]
        }
        var seen = Set<String>()
        return ClarificationCandidate(
            kind: .event,
            identifier: event.eventIdentifier,
            displayText: EventFormatting.candidateText(event, calendar: calendar),
            matchTerms: terms.filter { seen.insert($0.lowercased()).inserted }
        )
    }

    private func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
