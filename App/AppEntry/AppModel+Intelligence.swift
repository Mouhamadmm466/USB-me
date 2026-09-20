import Agent
import Connectors
import Core
import Foundation
import LLM
import Intelligence
import ShareInbox
import SwiftUI
import Telemetry

/// The V2 half of the composition root: the personal intelligence, the state the new tabs draw,
/// and the intents they report.
///
/// Reads are pulled on appearance and after anything changes, rather than pushed: the store is the
/// truth, and a screen that re-reads it can never show something the assistant would contradict.
extension AppModel {
    // MARK: Building

    /// Builds the intelligence for the running app. Learning uses the same model as the turn, so
    /// extraction only happens when a turn is worth it (`MemoryFilter`) and never on the path to
    /// an answer.
    func makeIntelligence(languageModel: (any LanguageModel)?) -> PersonalIntelligence? {
        do {
            let store = try IntelligenceStore(url: try IntelligenceStore.defaultURL(), logger: .shared)
            let extractor: any MemoryExtracting = languageModel.map {
                LanguageModelMemoryExtractor(model: $0, logger: .shared)
            } ?? NoMemoryExtractor()
            return PersonalIntelligence(
                store: store,
                dates: IntelligenceDateResolver(),
                extractor: extractor,
                settings: memoryPolicy,
                logger: .shared
            )
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "store_open_failed"))
            return nil
        }
    }

    /// Every outside service the app knows how to talk to, whether or not the user has connected
    /// one. Built once: it owns the Keychain handle and the account file.
    static let connectors: ConnectorRegistry = {
        let accounts = (try? FileConnectorAccountStore.defaultURL())
            .map { FileConnectorAccountStore(url: $0) }
        return ConnectorRegistry(
            connectors: [GmailConnector(), DriveConnector(), GitHubConnector()],
            accounts: accounts ?? FileConnectorAccountStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "connector-accounts.json")),
            tokens: KeychainTokenStore()
        )
    }()

    /// Planning and running jobs. The runtime's executors reach the user's own documents and world,
    /// the web, and any service they have connected — all through the same gate.
    func makeJobService(
        languageModel: any LanguageModel, intelligence: PersonalIntelligence?
    ) -> JobService? {
        guard let intelligence else { return nil }
        let writer = LanguageModelArtifactWriter(
            model: languageModel, store: intelligence.store, logger: .shared
        )
        let runtime = AgentRuntime(
            store: intelligence.store,
            executors: [
                IntelligenceStepExecutor(intelligence: intelligence, artifacts: writer, logger: .shared),
                // The only door out of the phone, and it is gated and logged on every request.
                WebStepExecutor(
                    store: intelligence.store,
                    policy: { [weak self] in await self?.currentNetworkPolicy() ?? NetworkPolicy() },
                    approve: { [weak self] descriptor in
                        guard let self else { return false }
                        return await self.askToSend(descriptor)
                    },
                    logger: .shared
                ),
                // The user's own accounts. Same gate, same log; the difference is that reading
                // their own mailbox is not a disclosure, so the leak check does not apply.
                ConnectorStepExecutor(
                    registry: Self.connectors,
                    store: intelligence.store,
                    policy: { [weak self] in await self?.currentNetworkPolicy() ?? NetworkPolicy() },
                    approve: { [weak self] descriptor in
                        guard let self else { return false }
                        return await self.askToSend(descriptor)
                    },
                    logger: .shared
                ),
            ],
            logger: .shared
        )
        return JobService(
            intelligence: intelligence,
            planner: Planner(model: languageModel, logger: .shared),
            runtime: runtime,
            availability: { [weak self] in
                let policy = await self?.currentNetworkPolicy() ?? NetworkPolicy()
                return CapabilityAvailability(
                    networkAllowed: policy.mode != .off,
                    isOnline: policy.isOnline,
                    connectedServices: await AppModel.connectors.connected()
                )
            },
            connectors: Self.connectors,
            logger: .shared
        )
    }

    /// What the world model is allowed to read, from the settings row the user edits.
    var ingestionPolicy: IngestionPolicy {
        IngestionPolicy(calendar: settings.ingestCalendar, reminders: settings.ingestReminders)
    }

    /// Reads the sources the user has switched on. Runs on launch and when the app comes forward:
    /// often enough that their week is current, cheap enough that it costs nothing.
    func syncIngestion() async {
        guard let intelligence, ingestionPolicy.isOn, let environment = toolEnvironmentForIngestion() else { return }
        intelligenceState.memory.ingestion.isSyncing = true
        defer { intelligenceState.memory.ingestion.isSyncing = false }

        let policy = ingestionPolicy
        let runner = IngestionRunner(
            store: intelligence.store,
            sources: [
                CalendarIngestionSource(store: environment.calendar, policy: policy),
                ReminderIngestionSource(store: environment.reminders, policy: policy),
            ],
            permissions: permissions,
            logger: .shared
        )
        let reports = await runner.sync(policy: policy)
        if reports.values.contains(where: { !$0.isEmpty }) {
            entityDetails.removeAll()
        }
        await refreshIntelligence()
    }

    func setIngestion(calendar: Bool? = nil, reminders: Bool? = nil) {
        let wasCalendar = settings.ingestCalendar
        let wasReminders = settings.ingestReminders
        applyIngestion(calendar: calendar ?? wasCalendar, reminders: reminders ?? wasReminders)
        intelligenceState.memory.ingestion.calendar = settings.ingestCalendar
        intelligenceState.memory.ingestion.reminders = settings.ingestReminders

        Task { @MainActor in
            guard let intelligence else { return }
            // Switching a source off takes back what it brought. What the user has since attached
            // their own words to stays theirs.
            if wasCalendar, !settings.ingestCalendar {
                _ = try? await intelligence.store.forgetEverything(from: .calendar)
            }
            if wasReminders, !settings.ingestReminders {
                _ = try? await intelligence.store.forgetEverything(from: .reminders)
            }
            entityDetails.removeAll()
            if settings.ingestCalendar || settings.ingestReminders {
                // Asking for the permission here is right: the user just asked for this.
                if settings.ingestCalendar { _ = await permissions.request(.calendar) }
                if settings.ingestReminders { _ = await permissions.request(.reminders) }
                await syncIngestion()
            } else {
                await refreshIntelligence()
            }
        }
    }

    // MARK: Reading

    /// Collects whatever the user sent in from the share sheet.
    ///
    /// The extension only copied bytes; the reading happens here, where a parse failure can be
    /// shown and a long document is not a memory limit away from being killed. Each item leaves the
    /// inbox only once it is in — a crash halfway costs a retry, not the document. What cannot be
    /// read is dropped with a message rather than retried forever.
    func drainShareInbox() async {
        guard let intelligence, let inbox = ShareInbox() else { return }
        let waiting = inbox.pending()
        guard !waiting.isEmpty else { return }

        intelligenceState.memory.isImporting = true
        defer { intelligenceState.memory.isImporting = false }

        var kept = 0
        for item in waiting {
            do {
                let document = try await intelligence.importDocument(
                    data: try inbox.data(of: item),
                    fileName: item.payloadName,
                    mediaType: item.mediaType,
                    origin: .share,
                    sourceID: item.id.uuidString,
                    named: item.title
                )
                inbox.remove(item)
                kept += 1
                PrivacySafeLogger.shared.log(.counter(name: "share.imported", value: document.chunkCount))
            } catch let error as DocumentParseError {
                inbox.remove(item)
                intelligenceState.memory.importError = "\(item.title): \(error.description)"
            } catch {
                inbox.remove(item)
                intelligenceState.memory.importError = "\(item.title) couldn't be read."
            }
        }
        if kept > 0 { await refreshIntelligence() }
    }

    /// Reads files the user picked and indexes them. Security-scoped access is opened and closed
    /// around the read, and the file itself is never copied into the app — only its text.
    func importDocuments(_ urls: [URL]) {
        guard let intelligence, !urls.isEmpty else { return }
        intelligenceState.memory.isImporting = true
        intelligenceState.memory.importError = nil
        Task { @MainActor in
            defer { intelligenceState.memory.isImporting = false }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    _ = try await intelligence.importDocument(
                        data: data,
                        fileName: url.lastPathComponent,
                        mediaType: nil,
                        origin: .files,
                        sourceID: url.lastPathComponent
                    )
                } catch let error as DocumentParseError {
                    intelligenceState.memory.importError = error.description
                } catch {
                    intelligenceState.memory.importError = "\(url.lastPathComponent) couldn't be read."
                }
            }
            await refreshIntelligence()
        }
    }

    /// Re-reads everything the V2 tabs show. Cheap: five indexed queries against a local file.
    func refreshIntelligence() async {
        guard let intelligence else { return }
        do {
            let snapshot = try await intelligence.snapshot(now: Date())
            let policy = await intelligence.settings
            var state = presenter.viewState(from: snapshot, settings: policy)
            state.memory.searchText = intelligenceState.memory.searchText
            state.memory.results = intelligenceState.memory.results
            state.memory.isImporting = intelligenceState.memory.isImporting
            state.memory.importError = intelligenceState.memory.importError
            state.memory.documents = (try? await intelligence.documents(limit: 50))?
                .map { presenter.documentRow($0) } ?? []
            state.memory.ingestion = IntelligenceViewState.Ingestion(
                calendar: settings.ingestCalendar,
                reminders: settings.ingestReminders,
                summary: await ingestionSummary(),
                isSyncing: intelligenceState.memory.ingestion.isSyncing
            )
            intelligenceState = state
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "snapshot_failed"))
        }
    }

    /// What the detail screen shows for an entity. Returns what is already loaded (or a placeholder)
    /// and loads the rest, so pushing a screen never waits on the store.
    func entityDetail(_ id: UUID) -> EntityDetailViewState {
        if let loaded = entityDetails[id] { return loaded }
        Task { await loadEntityDetail(id) }
        return EntityDetailViewState(id: id, title: "", kind: .project, status: "", isLoading: true)
    }

    func loadEntityDetail(_ id: UUID) async {
        guard let intelligence else { return }
        let store = intelligence.store
        do {
            guard let entity = try await store.entity(id) else { return }
            let assertions = try await store.assertions(about: id, states: [.active, .proposed], limit: 60)
            let neighbourIDs = Set(assertions.flatMap { [$0.subjectID, $0.objectID].compactMap { $0 } })
                .union([entity.projectID].compactMap { $0 })
                .subtracting([id])
            let neighbours = try await store.entities(Array(neighbourIDs.prefix(40)))
            let activity = try await store.activity(about: id, limit: 20)
            entityDetails[id] = presenter.detail(
                entity: entity,
                assertions: assertions,
                neighbours: Dictionary(uniqueKeysWithValues: neighbours.map { ($0.id, $0) }),
                activity: activity
            )
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "detail_failed"))
        }
    }

    /// Opens something the assistant wrote. Read from the store, so it is the same document the
    /// job actually produced — not a fresh generation.
    func openArtifact(_ id: UUID) {
        guard let intelligence else { return }
        Task { @MainActor in
            guard let artifact = try? await intelligence.store.artifact(id) else { return }
            let sources = (try? await intelligence.store.entities(artifact.sourceIDs))?.map(\.title) ?? []
            openedArtifact = ArtifactViewState(artifact: artifact, sources: sources)
        }
    }

    /// Writes the artifact to a file the user can keep or send on.
    func shareArtifact(_ artifact: Artifact) {
        let name = artifact.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).md")
        do {
            try Data(artifact.markdown.utf8).write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "artifact_share_failed"))
        }
    }

    func forgetArtifact(_ id: UUID) {
        guard let intelligence else { return }
        Task { @MainActor in
            try? await intelligence.store.forgetArtifact(id)
            openedArtifact = nil
            entityDetails[id] = nil
            await refreshIntelligence()
        }
    }

    // MARK: Intents

    var intelligenceIntents: IntelligenceIntents {
        IntelligenceIntents(
            confirm: { [weak self] id in self?.answerQuestion(id, yes: true) },
            reject: { [weak self] id in self?.answerQuestion(id, yes: false) },
            undo: { [weak self] id in
                guard let self, let intelligence else { return }
                Task { @MainActor in
                    _ = try? await intelligence.undo(id)
                    self.entityDetails.removeAll()
                    await self.refreshIntelligence()
                }
            },
            openEntity: { [weak self] id in self?.showEntity(id) },
            search: { [weak self] text in self?.searchIntelligence(text) },
            setLearningEnabled: { [weak self] enabled in
                self?.updateMemoryPolicy { $0.learningEnabled = enabled }
            },
            setConfirmInferences: { [weak self] enabled in
                self?.updateMemoryPolicy { $0.confirmInferences = enabled }
            },
            addDocument: { [weak self] in self?.isDocumentPickerPresented = true },
            setCalendarIngestion: { [weak self] enabled in self?.setIngestion(calendar: enabled) },
            setReminderIngestion: { [weak self] enabled in self?.setIngestion(reminders: enabled) },
            forgetDocument: { [weak self] id in
                guard let self, let intelligence else { return }
                Task { @MainActor in
                    try? await intelligence.store.forgetDocument(id)
                    self.entityDetails[id] = nil
                    await self.refreshIntelligence()
                }
            },
            exportEverything: { [weak self] in self?.exportIntelligence() },
            deleteEverything: { [weak self] in
                guard let self, let intelligence else { return }
                Task { @MainActor in
                    try? await intelligence.store.deleteEverything()
                    self.entityDetails.removeAll()
                    await self.refreshIntelligence()
                }
            },
            refresh: { [weak self] in await self?.refreshIntelligence() }
        )
    }

    /// Opens an entity: as the sheet when nothing is open, pushed on top when something is.
    func showEntity(_ id: UUID) {
        Task { @MainActor in await self.loadEntityDetail(id) }
        if openedEntityID == nil { openedEntityID = id } else { entityPath.append(id) }
    }

    /// What the main screen holds up when it is at rest, and what the person can do with it.
    var standby: AssistantStandby { intelligenceState.standby }

    var standbyIntents: StandbyIntents {
        StandbyIntents(
            open: { [weak self] id in self?.showEntity(id) },
            confirm: { [weak self] id in self?.answerQuestion(id, yes: true) },
            reject: { [weak self] id in self?.answerQuestion(id, yes: false) }
        )
    }

    var entityDetailIntents: EntityDetailIntents {
        EntityDetailIntents(
            confirmFact: { [weak self] id in self?.answerQuestion(id, yes: true) },
            forgetFact: { [weak self] id in self?.answerQuestion(id, yes: false) },
            openEntity: { [weak self] id in self?.showEntity(id) },
            forgetEntity: { [weak self] id in
                guard let self, let intelligence else { return }
                Task { @MainActor in
                    try? await intelligence.store.forget(id)
                    self.entityDetails[id] = nil
                    self.entityPath.removeAll { $0 == id }
                    if self.openedEntityID == id { self.openedEntityID = self.entityPath.popLast() }
                    await self.refreshIntelligence()
                }
            }
        )
    }

    /// "42 events and 18 reminders" — what is currently held from the sources that are on.
    private func ingestionSummary() async -> String? {
        guard let intelligence, ingestionPolicy.isOn else { return nil }
        let store = intelligence.store
        var parts: [String] = []
        if settings.ingestCalendar, let events = try? await store.links(of: .calendar).count, events > 0 {
            parts.append(events == 1 ? "1 event" : "\(events) events")
        }
        if settings.ingestReminders, let reminders = try? await store.links(of: .reminders).count, reminders > 0 {
            parts.append(reminders == 1 ? "1 reminder" : "\(reminders) reminders")
        }
        guard !parts.isEmpty else { return "Nothing read yet." }
        return "Keeping track of " + parts.joined(separator: " and ") + "."
    }

    // MARK: Private helpers

    private func answerQuestion(_ assertionID: UUID, yes: Bool) {
        guard let intelligence else { return }
        Task { @MainActor in
            if yes {
                try? await intelligence.confirm(assertionID)
            } else {
                try? await intelligence.reject(assertionID)
            }
            entityDetails.removeAll()
            await refreshIntelligence()
        }
    }

    private func searchIntelligence(_ text: String) {
        intelligenceState.memory.searchText = text
        guard let intelligence, text.count > 1 else {
            intelligenceState.memory.results = []
            return
        }
        Task { @MainActor in
            let found = (try? await intelligence.store.search(text, limit: 25)) ?? []
            guard intelligenceState.memory.searchText == text else { return }
            intelligenceState.memory.results = found
                .filter { $0.id != IntelligenceIdentity.userEntityID }
                .map { presenter.item($0) }
        }
    }

    private func updateMemoryPolicy(_ change: @escaping (inout MemoryPolicySettings) -> Void) {
        var policy = memoryPolicy
        change(&policy)
        applyMemoryPolicy(policy)
        guard let intelligence else { return }
        Task { @MainActor in
            await intelligence.update(settings: policy)
            await refreshIntelligence()
        }
    }

    /// Writes the whole store to a file the user can keep, and offers the share sheet.
    private func exportIntelligence() {
        guard let intelligence else { return }
        Task { @MainActor in
            guard let data = try? await intelligence.store.export() else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("What I know \(Self.exportStamp()).json")
            do {
                try data.write(to: url, options: .atomic)
                exportedFile = url
            } catch {
                PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "export_failed"))
            }
        }
    }

    private static func exportStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Demo content

extension AppModel {
    /// Fills an empty store with a small, plausible world so the screens can be seen (and
    /// screenshotted) without a real history. Demo mode only; never runs against a real store
    /// that already holds something.
    func seedDemoIntelligence() async {
        guard isDemoMode, let intelligence else { return }
        let store = intelligence.store
        guard let counts = try? await store.counts(), counts.activeAssertions == 0 else { return }
        let now = Date()
        let source = Provenance(sourceType: .conversation, sourceID: "demo", excerpt: "the beta ships next Friday")
        do {
            let project = try await store.create(kind: .project, title: "Beta launch", importance: 0.9)
            let goal = try await store.create(kind: .goal, title: "Ship the beta")
            let task = try await store.create(kind: .task, title: "Write the release note")
            let standup = try await store.create(kind: .event, title: "Standup")
            let sarah = try await store.create(kind: .person, title: "Sarah Chen")
            let abdou = try await store.create(kind: .person, title: "Abdou")
            let promise = try await store.create(kind: .commitment, title: "Send Sarah the deck")
            let thesis = try await store.create(kind: .project, title: "Thesis")

            let friday = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
            try await store.record(subject: goal.id, .belongsTo, object: project.id, provenance: source, at: now)
            try await store.record(subject: goal.id, .deadline, value: .date(friday, phrase: "next Friday"),
                                   provenance: source, at: now)
            try await store.record(subject: task.id, .belongsTo, object: project.id, provenance: source, at: now)
            try await store.record(subject: task.id, .deadline, value: .date(now, phrase: "today"),
                                   provenance: source, at: now)
            try await store.record(subject: standup.id, .starts,
                                   value: .date(now.addingTimeInterval(3_600), phrase: "today"),
                                   provenance: Provenance(sourceType: .calendar, sourceID: "demo-standup"), at: now)
            try await store.record(subject: sarah.id, .worksOn, object: project.id, value: .text("design"),
                                   provenance: source, at: now)
            try await store.record(subject: abdou.id, .worksOn, object: project.id, value: .text("the voice loop"),
                                   provenance: source, at: now)
            try await store.record(subject: promise.id, .belongsTo, object: project.id, provenance: source, at: now)
            try await store.record(subject: promise.id, .owedTo, object: sarah.id, provenance: source, at: now)
            try await store.record(subject: promise.id, .deadline,
                                   value: .date(now.addingTimeInterval(-86_400), phrase: "yesterday"),
                                   provenance: source, at: now)
            try await store.record(subject: thesis.id, .status, value: .text(EntityStatus.paused.rawValue),
                                   provenance: source, at: now)

            // One thing the system worked out and has not been told it may keep.
            let guess = Assertion(
                subjectID: sarah.id, predicate: .role, value: .text("design lead"), type: .inferred,
                confidence: 0.7, state: .proposed, provenance: source, validFrom: now, createdAt: now
            )
            try await store.propose(guess)

            _ = try await store.record([
                ActivityEntry(kind: .learned, headline: "Abdou works on Beta launch (the voice loop)",
                              detail: "You told me today.", entityID: abdou.id,
                              createdAt: now.addingTimeInterval(-600)),
                ActivityEntry(kind: .asked, headline: "Sarah Chen is responsible for design lead",
                              detail: "I worked it out from what I've seen.", entityID: sarah.id,
                              assertionID: guess.id, undo: .reject(guess.id), createdAt: now.addingTimeInterval(-300)),
            ])
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "intelligence", code: "demo_seed_failed"))
        }
        await refreshIntelligence()
    }
}

// MARK: - The internet

/// A request waiting on the user's yes or no, with the continuation their answer resumes.
struct PendingNetworkRequest: Identifiable {
    let id = UUID()
    let descriptor: NetworkRequestDescriptor
    let answer: @Sendable (Bool) -> Void
}

extension AppModel {
    /// The policy the web capabilities are gated by, read fresh for each request so changing the
    /// mode takes effect immediately — including while a job is running.
    func currentNetworkPolicy() -> NetworkPolicy {
        NetworkPolicy(
            mode: networkMode,
            isOnline: Reachability.isOnline,
            // The public sources, plus the hosts of whatever the user has connected. A service that
            // is not connected is not on this list, so a step naming it cannot reach anything.
            allowedHosts: CompositeWebProvider.standard.hosts.union(connectorHosts)
        )
    }

    func setNetworkMode(_ mode: NetworkMode) {
        applyNetworkMode(mode)
        networkState.mode = mode
        // A request waiting for a yes is not carried across a change of mind.
        pendingNetworkRequest?.answer(false)
        pendingNetworkRequest = nil
    }

    /// Shows one request and waits for the user. Returns false if they say no, dismiss it, or the
    /// app goes away — nothing is sent on a timeout or an ambiguity.
    func askToSend(_ descriptor: NetworkRequestDescriptor) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = PendingNetworkRequest(descriptor: descriptor) { allowed in
                continuation.resume(returning: allowed)
            }
            Task { @MainActor in
                self.pendingNetworkRequest?.answer(false)
                self.pendingNetworkRequest = request
            }
        }
    }

    func answerNetworkRequest(_ allowed: Bool) {
        pendingNetworkRequest?.answer(allowed)
        pendingNetworkRequest = nil
        Task { @MainActor in await refreshNetworkState() }
    }

    func refreshNetworkState() async {
        guard let intelligence else {
            networkState = SettingsViewState.Network(mode: networkMode)
            return
        }
        let store = intelligence.store
        let entries = (try? await store.networkLog(limit: 100)) ?? []
        let summary = (try? await store.networkSummary()) ?? (sent: 0, refused: 0, bytes: 0)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        networkState = SettingsViewState.Network(
            mode: networkMode,
            sent: summary.sent,
            refused: summary.refused,
            bytesText: formatter.string(fromByteCount: Int64(summary.bytes)),
            log: entries.map { entry in
                SettingsViewState.Network.LogRow(
                    id: entry.id,
                    provider: entry.provider,
                    payload: entry.payload,
                    categories: entry.categories.map(\.displayName).joined(separator: ", "),
                    reason: entry.reason,
                    outcome: entry.outcome,
                    detail: entry.refusal?.explanation,
                    timeText: presenter.relative(entry.at, now: Date())
                )
            }
        )
    }

    func clearNetworkLog() {
        guard let intelligence else { return }
        Task { @MainActor in
            try? await intelligence.store.clearNetworkLog()
            await refreshNetworkState()
        }
    }
}

/// Whether there is any route off the device at all.
///
/// Deliberately coarse: the app never probes the network to find out, it only reports what the
/// system already knows, and a wrong "online" only costs a failed request that is logged anyway.
enum Reachability {
    nonisolated(unsafe) static var isOnline: Bool = true
}
