import Foundation
import Intelligence

/// Turns what the store holds into what the screens draw.
///
/// Every string the V2 screens show is produced here — dates as phrases, counts as sentences,
/// statements as the deterministic sentence the intelligence itself would say. Keeping it in one
/// place means the wording in the UI, in the activity feed and in what the assistant says out loud
/// can never drift apart.
struct IntelligencePresenter: Sendable {
    var calendar: Calendar = .current

    // MARK: Home

    func viewState(
        from snapshot: IntelligenceSnapshot,
        settings: MemoryPolicySettings,
        now: Date = Date()
    ) -> IntelligenceViewState {
        var state = IntelligenceViewState()
        state.isLoaded = true
        // Questions have their own section on Home, with Yes/No on them; listing them twice makes
        // the screen look longer than the day actually is.
        state.attention = snapshot.attention.filter { $0.kind != .question }.map(attentionRow)
        state.overdue = snapshot.overdue.map { item($0, now: now, overdue: true) }
        state.today = snapshot.today.map { item($0, now: now) }
        state.soon = snapshot.soon.map { item($0, now: now) }
        state.questions = snapshot.questions.map(question)
        state.projects = snapshot.projects.map { projectRow($0, now: now) }
        state.activity = snapshot.activity.map { activityRow($0, now: now) }
        state.memory = memory(from: snapshot.counts, settings: settings)
        return state
    }

    func item(_ entity: IntelligenceEntity, now: Date = Date(), overdue: Bool = false) -> IntelligenceViewState.Item {
        IntelligenceViewState.Item(
            id: entity.id,
            title: entity.title,
            meta: meta(for: entity, now: now),
            kind: entity.kind,
            tone: tone(for: entity, overdue: overdue),
            systemImage: entity.kind.systemImage,
            isOverdue: overdue
        )
    }

    func attentionRow(_ item: AttentionItem) -> IntelligenceViewState.AttentionRow {
        IntelligenceViewState.AttentionRow(
            id: item.id, title: item.title, reason: item.reason, kind: item.kind,
            tone: item.kind.tone, systemImage: item.kind.systemImage, entityID: item.entityID
        )
    }

    func question(_ question: PendingQuestion) -> IntelligenceViewState.Question {
        IntelligenceViewState.Question(
            id: question.assertion.id,
            sentence: question.sentence,
            explanation: question.explanation,
            replaces: question.conflictsWith
        )
    }

    func projectRow(_ summary: ProjectSummary, now: Date = Date()) -> IntelligenceViewState.ProjectRow {
        IntelligenceViewState.ProjectRow(
            id: summary.project.id,
            title: summary.project.title,
            status: summary.project.status.rawValue.replacingOccurrences(of: "_", with: " "),
            tone: tone(for: summary.project, overdue: false),
            openWork: summary.openWork,
            commitments: summary.openCommitments,
            people: summary.people.map(\.title),
            nextDue: summary.nextDue.map { day($0, now: now) },
            nextDueTitle: summary.nextDueTitle,
            isLate: summary.nextDue.map { $0 < now } ?? false
        )
    }

    func activityRow(_ entry: ActivityEntry, now: Date = Date()) -> IntelligenceViewState.ActivityRow {
        IntelligenceViewState.ActivityRow(
            id: entry.id,
            kind: entry.kind,
            headline: entry.headline,
            detail: entry.detail,
            timeText: relative(entry.createdAt, now: now),
            canUndo: entry.canUndo,
            isUndone: entry.isUndone,
            entityID: entry.entityID
        )
    }

    func memory(from counts: IntelligenceCounts, settings: MemoryPolicySettings) -> IntelligenceViewState.Memory {
        IntelligenceViewState.Memory(
            kinds: EntityKind.allCases.compactMap { kind in
                guard let count = counts.entities[kind], count > 0 else { return nil }
                // The user's own person entity is not a row in a list of people they know.
                let adjusted = kind == .person ? count - 1 : count
                return adjusted > 0 ? .init(kind: kind, count: adjusted) : nil
            },
            facts: counts.activeAssertions,
            questions: counts.proposedAssertions,
            inferred: counts.inferredAssertions,
            sizeText: size(counts.sizeBytes),
            learningEnabled: settings.learningEnabled,
            confirmInferences: settings.confirmInferences
        )
    }

    func documentRow(_ document: KnowledgeDocument, now: Date = Date()) -> IntelligenceViewState.DocumentRow {
        var parts: [String] = []
        if let pages = document.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        parts.append(document.chunkCount == 1 ? "1 passage" : "\(document.chunkCount) passages")
        parts.append(relative(document.importedAt, now: now))
        return IntelligenceViewState.DocumentRow(
            id: document.id, title: document.title, meta: parts.joined(separator: " · ")
        )
    }

    // MARK: Entity detail

    func detail(
        entity: IntelligenceEntity,
        assertions: [Assertion],
        neighbours: [UUID: IntelligenceEntity],
        activity: [ActivityEntry],
        now: Date = Date()
    ) -> EntityDetailViewState {
        var meta: [String] = []
        if let due = entity.dueAt { meta.append("due \(day(due, now: now))") }
        if let starts = entity.startsAt { meta.append(day(starts, now: now)) }
        if let projectID = entity.projectID, let project = neighbours[projectID] {
            meta.append("part of \(project.title)")
        }
        if let subtitle = entity.subtitle { meta.append(subtitle) }

        let facts = assertions.map { assertion -> EntityDetailViewState.Fact in
            let subject = assertion.subjectID == entity.id ? entity : neighbours[assertion.subjectID]
            let object = assertion.objectID.flatMap { $0 == entity.id ? entity : neighbours[$0] }
            return EntityDetailViewState.Fact(
                id: assertion.id,
                sentence: StatementText.sentence(
                    assertion, subject: subject ?? entity, object: object, now: now, calendar: calendar
                ),
                explanation: assertion.explanation(now: now, calendar: calendar),
                isGuess: assertion.type == .inferred,
                isWaiting: assertion.state == .proposed
            )
        }

        let related = Set(assertions.flatMap { [$0.subjectID, $0.objectID].compactMap { $0 } })
            .subtracting([entity.id])
            .compactMap { neighbours[$0] }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }

        return EntityDetailViewState(
            id: entity.id,
            title: entity.title,
            kind: entity.kind,
            status: entity.status.rawValue.replacingOccurrences(of: "_", with: " "),
            tone: tone(for: entity, overdue: isOverdue(entity, now: now)),
            meta: meta,
            facts: facts,
            related: related.map { item($0, now: now) },
            activity: activity.map { activityRow($0, now: now) }
        )
    }

    // MARK: Formatting

    func meta(for entity: IntelligenceEntity, now: Date) -> String? {
        var parts: [String] = []
        if let due = entity.dueAt { parts.append("due \(day(due, now: now))") }
        else if let starts = entity.startsAt { parts.append(time(starts, now: now)) }
        if let subtitle = entity.subtitle { parts.append(subtitle) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "today", "tomorrow", "Friday", "September 25" — the words a person would use.
    func day(_ date: Date, now: Date) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return formatted(date, "EEEE")
        case ..<(-1): return "\(-days) days ago"
        default: return formatted(date, "MMMM d")
        }
    }

    /// A time today, a day and time otherwise.
    func time(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? formatted(date, "h:mm a")
            : "\(day(date, now: now)), \(formatted(date, "h:mm a"))"
    }

    /// "just now", "12 minutes ago", "Tuesday".
    func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) hr ago"
        default: return day(date, now: now)
        }
    }

    func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    private func isOverdue(_ entity: IntelligenceEntity, now: Date) -> Bool {
        guard let due = entity.dueAt, entity.status.isOutstanding else { return false }
        return due < now
    }

    private func tone(for entity: IntelligenceEntity, overdue: Bool) -> Tone {
        if overdue { return .danger }
        switch entity.kind {
        case .commitment: return .amber
        case .person: return .sky
        case .decision: return .neutral
        default: return entity.status.isOutstanding ? .clay : .neutral
        }
    }

    private func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter.string(from: date)
    }
}
