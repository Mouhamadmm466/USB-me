import Agent
import ASR
import Audio
import Core
import DeviceBenchmark
import Foundation
import Intelligence
import LLM
import Models
import Observation
import Permissions
import Storage
import SwiftData
import SwiftUI
import Telemetry
import Tools
import TTS
import UIKit
import VoiceLoop
#if KOKORO_TTS
import KokoroTTS
#endif

/// Composition root: builds every service once, runs the launch sequence (reconcile → import →
/// verify → warm up), and adapts services to the SwiftUI screens' plain view states.
@MainActor
@Observable
final class AppModel {
    enum Route: Equatable {
        case launching
        case onboarding
        case assistant
    }

    private(set) var route: Route = .launching
    var isSettingsPresented = false
    var isFolderPickerPresented = false
    /// Explains the microphone before iOS asks for it (first mic tap only).
    var isMicrophoneSheetPresented = false
    /// Section Settings scrolls to when it opens (e.g. Files from a folder-access card).
    private(set) var settingsInitialSection: SettingsSection?
    private(set) var coordinator: AgentCoordinator?
    private(set) var voice: VoiceSessionController?
    private(set) var downloads = ModelDownloadViewState(packs: [])
    private(set) var settings = AppSettings()
    private(set) var diagnostics = SettingsViewState.Diagnostics()
    private(set) var permissionRows: [SettingsViewState.PermissionRow] = []
    private(set) var sharedFolders: [SettingsViewState.SharedFolder] = []
    private(set) var storage = SettingsViewState.Storage(modelBytes: 0)
    private(set) var storedTurnCount: Int?
    /// Shown while models load or when warm-up failed.
    private(set) var warmUpMessage: String?
    let isDemoMode: Bool

    // MARK: V2 — the personal intelligence

    /// Everything the main screen's standby list and the Settings screens draw.
    var intelligenceState = IntelligenceViewState()
    /// The entity the person opened from the main screen; the sheet's root.
    var openedEntityID: UUID?
    /// Entities pushed on top of it, when one detail leads to another.
    var entityPath: [UUID] = []
    /// Loaded detail screens, keyed by entity. Cleared whenever the store changes underneath them.
    var entityDetails: [UUID: EntityDetailViewState] = [:]
    /// Set when an export is ready; the share sheet is presented from it.
    var exportedFile: URL?
    /// Presents the Files picker for importing a document.
    var isDocumentPickerPresented = false
    /// What the internet section shows: the mode, and the record of what left.
    var networkState = SettingsViewState.Network()
    /// A request waiting on the user's yes or no, with the continuation that carries their answer.
    var pendingNetworkRequest: PendingNetworkRequest?
    /// The artifact being read, with the sources it was built from.
    var openedArtifact: ArtifactViewState?
    @ObservationIgnored private(set) var intelligence: PersonalIntelligence?
    @ObservationIgnored let presenter = IntelligencePresenter()

    /// Whether anything may reach the internet right now, from the settings row the user edits.
    var networkMode: NetworkMode {
        NetworkMode(rawValue: settings.networkMode) ?? .off
    }

    /// The two switches the intelligence reads, taken from the settings row the user edits.
    var memoryPolicy: MemoryPolicySettings {
        MemoryPolicySettings(
            learningEnabled: settings.learningEnabled,
            confirmInferences: settings.confirmInferences
        )
    }

    func applyIngestion(calendar: Bool, reminders: Bool) {
        settings.ingestCalendar = calendar
        settings.ingestReminders = reminders
        persistSettings()
    }

    /// The EventKit adapters the ingestion sources read through — the same ones the tools use, so
    /// what the assistant sees and what the world model keeps can never disagree.
    func toolEnvironmentForIngestion() -> (calendar: any CalendarStore, reminders: any ReminderStore)? {
        let environment = isDemoMode ? demoEnvironment : systemToolEnvironment()
        guard let environment else { return nil }
        return (environment.calendar, environment.reminders)
    }

    func applyNetworkMode(_ mode: NetworkMode) {
        settings.networkMode = mode.rawValue
        persistSettings()
    }

    func applyMemoryPolicy(_ policy: MemoryPolicySettings) {
        settings.learningEnabled = policy.learningEnabled
        settings.confirmInferences = policy.confirmInferences
        persistSettings()
    }

    func setIntelligence(_ intelligence: PersonalIntelligence?) {
        self.intelligence = intelligence
    }

    @ObservationIgnored private let modelManager: ModelManager
    @ObservationIgnored private let fileScopes: BookmarkFileScopeStore
    @ObservationIgnored let permissions: PermissionManager
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var sessionStore: SessionStore?
    @ObservationIgnored private var settingsStore: SettingsStore?
    @ObservationIgnored private let audioEngine = AudioEngine()
    @ObservationIgnored private var runtimes = Runtimes()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var benchmarkTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Demo mode's fake tool world, so the ingestion switches do something visible there too.
    @ObservationIgnored private var demoEnvironment: ToolEnvironment?

    struct Runtimes {
        var whisper: WhisperRuntime?
        var vad: (any VoiceActivityDetecting)?
        var nemotron: NemotronRuntime?
        var synthesizer: (any SpeechSynthesizer)?
        #if KOKORO_TTS
        var kokoro: KokoroRuntime?
        #endif
    }

    static var speechOutputAvailable: Bool {
        #if KOKORO_TTS
        true
        #else
        false
        #endif
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEVELOPER_MODES
        isDemoMode = arguments.contains("-DemoMode")
        #else
        isDemoMode = false
        #endif
        modelManager = ModelManager()
        let scopes = BookmarkFileScopeStore.standard()
        fileScopes = scopes
        permissions = PermissionManager(backend: SystemPermissionBackend(fileScopes: scopes))
        DesignSystemAppearance.install()
    }

    // MARK: - Launch

    func start() async {
        guard route == .launching, tasks.isEmpty else { return }
        openStores()
        if let settingsStore { settings = (try? await settingsStore.load()) ?? AppSettings() }
        observeSystem()
        if isDemoMode {
            startDemoMode()
            return
        }
        _ = await modelManager.reconcileOnLaunch()
        // Developer sideload / Finder copies: Documents/ModelImport → verified store.
        _ = await modelManager.importPendingFiles()
        let updates = await modelManager.statusUpdates()
        tasks.append(Task { [weak self] in
            for await statuses in updates {
                guard let self else { return }
                await self.apply(statuses: statuses)
            }
        })
        await refreshSettingsState()
        if await modelManager.isReady, settings.hasCompletedOnboarding {
            route = .assistant
            await warmUp()
        } else {
            route = .onboarding
        }
    }

    private func apply(statuses: [ModelPackStatus]) async {
        downloads = ModelDownloadViewState(statuses: statuses, freeSpaceBytes: storage.freeBytes, network: .unknown)
        if route == .assistant, coordinator == nil, warmUpMessage == nil, await modelManager.isReady {
            await warmUp()
        }
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        persistSettings()
        route = .assistant
        Task { if await modelManager.isReady { await warmUp() } }
    }

    /// Loads the verified models and builds the coordinator and voice session.
    func warmUp() async {
        guard coordinator == nil else { return }
        warmUpMessage = "Preparing your assistant…"
        do {
            let asr = try await modelManager.verifiedFileURLs(for: .asr)
            let llm = try await modelManager.verifiedFileURLs(for: .llm)
            guard let whisperURL = asr[ModelFileName.whisperBaseEn], let llmURL = llm[ModelFileName.nemotronNano4B] else {
                throw BenchmarkModeError.missing("model files")
            }
            let whisper = WhisperRuntime(modelURL: whisperURL, speechGateModelURL: asr[ModelFileName.sileroVAD])
            try await whisper.load()
            runtimes.whisper = whisper
            if let vadURL = asr[ModelFileName.sileroVAD], let silero = try? SileroVAD(modelURL: vadURL) {
                runtimes.vad = silero
            } else {
                runtimes.vad = EnergyVAD()
            }
            let nemotron = NemotronRuntime(modelURL: llmURL, stateCacheDirectory: Self.applicationSupport.appendingPathComponent("LLMState"))
            try await nemotron.prepare(cacheablePrefix: PromptBuilder().cacheablePrefix)
            runtimes.nemotron = nemotron
            #if KOKORO_TTS
            let tts = try await modelManager.verifiedFileURLs(for: .tts)
            if let weights = tts[ModelFileName.kokoroWeights], let voiceURL = tts[ModelFileName.kokoroVoiceAfHeart] {
                let kokoro = KokoroRuntime(modelURL: weights, voiceURL: voiceURL)
                try await kokoro.warmUp()
                runtimes.kokoro = kokoro
                runtimes.synthesizer = kokoro
            }
            #endif
            buildAgent(languageModel: nemotron, environment: systemToolEnvironment())
            warmUpMessage = nil
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "app", code: "warm_up_failed"))
            warmUpMessage = "The models couldn't be loaded. Check Settings → Models."
        }
    }

    private func systemToolEnvironment() -> ToolEnvironment {
        ToolEnvironment.system(presenter: { AppModel.topViewController() }, fileScopes: fileScopes, permissions: permissions)
    }

    private func buildAgent(languageModel: any LanguageModel, environment: ToolEnvironment) {
        let speech = SpeechQueue(synthesizer: runtimes.synthesizer, player: runtimes.synthesizer == nil ? nil : audioEngine,
                                 metrics: .shared)
        let messages = environment.messages
        let calls = environment.calls
        var configuration = AgentConfiguration.default
        configuration.continueListeningAfterResponse = settings.continueListening
        let intelligence = makeIntelligence(languageModel: languageModel)
        setIntelligence(intelligence)
        let jobs = makeJobService(languageModel: languageModel, intelligence: intelligence)
        let coordinator = AgentCoordinator(
            dependencies: AgentDependencies(
                languageModel: languageModel,
                resolver: ActionResolver(environment: environment),
                executor: ToolExecutor(environment: environment),
                permissions: permissions,
                speech: speech,
                capabilities: DeviceCapabilities(canSendText: { await messages.canSendText() },
                                                 canPlaceCalls: { await calls.canPlaceCalls() }),
                intelligence: intelligence,
                jobs: jobs,
                clock: AgentClock(),
                metrics: .shared
            ),
            configuration: configuration
        )
        coordinator.onTurnRecorded = { [weak self] turn in self?.persist(turn) }
        // A turn that learned something changes what the other tabs show.
        coordinator.onMemoryLearned = { [weak self] report in
            guard let self, !report.isEmpty else { return }
            self.entityDetails.removeAll()
            Task { @MainActor in await self.refreshIntelligence() }
        }
        self.coordinator = coordinator
        Task { @MainActor in
            await drainShareInbox()
            await syncIngestion()
            await refreshIntelligence()
        }
        if let whisper = runtimes.whisper, let vad = runtimes.vad {
            let contacts = environment.contacts
            let permissions = permissions
            let engine = audioEngine
            voice = VoiceSessionController(
                coordinator: coordinator,
                dependencies: VoiceSessionController.Dependencies(
                    capture: engine,
                    recognizer: whisper,
                    vad: vad,
                    speech: speech,
                    permissions: permissions,
                    biasNames: {
                        guard PermissionManager.isUsable(await permissions.status(for: .contacts), for: .contacts) else { return [] }
                        return ((try? await contacts.allContacts()) ?? []).prefix(200).map(\.displayName)
                    },
                    sessionEvents: { AudioSessionManager.shared.events() },
                    initialEchoRisk: AudioSessionManager.shared.currentRoute.echoRisk,
                    levels: { engine.levelUpdates() },
                    metrics: .shared
                ),
                configuration: configuration
            )
        }
        coordinator.transition(to: .idle, reason: .modelsReady)
    }

    // MARK: - Demo mode (UI tests / Simulator without models)

    private func startDemoMode() {
        let now = Date()
        let suite = FakeToolSuite(
            contacts: [
                ContactRecord(identifier: "demo-alex", givenName: "Alex", familyName: "Kim",
                              phones: [LabeledPhone(label: "mobile", number: "+1 (555) 010-1001")]),
                ContactRecord(identifier: "demo-priya", givenName: "Priya", familyName: "Patel",
                              phones: [LabeledPhone(label: "mobile", number: "+1 (555) 010-2002")]),
            ],
            events: [
                EventReference(eventIdentifier: "demo-sync", title: "Team sync",
                               startDate: now.addingTimeInterval(86_400), endDate: now.addingTimeInterval(88_200)),
                EventReference(eventIdentifier: "demo-review", title: "Beta review with Sarah",
                               startDate: now.addingTimeInterval(3 * 86_400),
                               endDate: now.addingTimeInterval(3 * 86_400 + 3_600), location: "Room 3"),
            ],
            clock: AgentClock()
        )
        demoEnvironment = suite.environment
        Task { await suite.reminders.seed([
            "demo-deck": ReminderDraft(title: "Send Sarah the deck", dueDate: now.addingTimeInterval(-86_400), dueHasTime: false),
            "demo-notes": ReminderDraft(title: "Write the release note", dueDate: now.addingTimeInterval(7_200), dueHasTime: true),
        ]) }
        buildAgent(languageModel: DemoLanguageModel(), environment: suite.environment)
        route = .assistant
        Task { @MainActor in await seedDemoIntelligence() }
    }

    // MARK: - Assistant intents

    var assistantIntents: AssistantIntents {
        AssistantIntents(
            toggleSession: { [weak self] in self?.toggleSession() },
            confirm: { [weak self] id, version in
                guard let coordinator = self?.coordinator else { return }
                Task { await coordinator.confirmFromCard(id: id, version: version) }
            },
            cancel: { [weak self] id in
                guard let coordinator = self?.coordinator else { return }
                Task { await coordinator.cancelFromCard(id: id) }
            },
            chooseClarification: { [weak self] id in
                guard let coordinator = self?.coordinator else { return }
                Task { await coordinator.chooseClarification(candidateID: id) }
            },
            submitText: { [weak self] text in self?.submit(text) },
            openSettings: { [weak self] in
                guard let self else { return }
                // From a shared-folder card, land on Files (the spoken reply says "under Files").
                self.settingsInitialSection = self.coordinator?.presentation.permissionPrompt?.kind == .fileScope ? .permissions : nil
                self.isSettingsPresented = true
                Task { await self.refreshSettingsState() }
            },
            openSystemSettings: { _ in AppModel.openSystemSettings() },
            dismissPermission: { [weak self] in self?.coordinator?.dismissPermissionPrompt() },
            approveJob: { [weak self] id in
                guard let self, let coordinator else { return }
                Task { @MainActor in
                    await coordinator.approveJob(id: id)
                    await self.refreshIntelligence()
                }
            },
            cancelJob: { [weak self] id in
                guard let self, let coordinator else { return }
                Task { @MainActor in
                    await coordinator.cancelJob(id: id)
                    await self.refreshIntelligence()
                }
            },
            openArtifact: { [weak self] id in self?.openArtifact(id) }
        )
    }

    func toggleSession() {
        guard let voice else { return }
        Task {
            if voice.isActive {
                await voice.stop()
            } else if await permissions.status(for: .microphone) == .notDetermined {
                // Just in time (PRD §11): explain first; the system prompt follows "Continue".
                isMicrophoneSheetPresented = true
            } else {
                await voice.start()
            }
        }
    }

    /// Honours a pending "start listening" from the Action button, Siri or a shortcut.
    ///
    /// Called whenever the app reaches a state where it could: after launch, once the models are
    /// ready, and when the app comes forward. A request made while the models were still warming is
    /// not dropped — it waits here until there is something to listen with.
    func startListeningIfAsked() {
        guard LaunchRequest.shared.wantsListening else { return }
        guard route == .assistant, let voice, !voice.isActive else { return }
        LaunchRequest.shared.wantsListening = false
        toggleSession()
    }

    /// "Continue" on the microphone explainer: iOS asks, then the session starts if allowed.
    func continueAfterMicrophoneExplainer() {
        isMicrophoneSheetPresented = false
        guard let voice else { return }
        Task { await voice.start() }
    }

    private func submit(_ text: String) {
        if let voice {
            voice.submitTyped(text)
        } else if let coordinator {
            Task { await coordinator.handle(.typed(text)) }
        }
    }

    // MARK: - Settings

    var settingsState: SettingsViewState {
        SettingsViewState(
            models: downloads,
            storage: storage,
            permissions: permissionRows,
            sharedFolders: sharedFolders,
            privacy: .init(keepHistory: settings.retainHistory, retentionDays: settings.historyRetentionDays,
                           storedTurnCount: storedTurnCount, network: networkState),
            voice: .init(continueListening: settings.continueListening, hapticsEnabled: settings.hapticsEnabled,
                         speechOutputAvailable: Self.speechOutputAvailable),
            diagnostics: diagnostics,
            about: .current()
        )
    }

    var modelActions: ModelDownloadActions {
        let manager = modelManager
        return ModelDownloadActions(
            downloadAll: { Task { try? await manager.installAll() } },
            pauseAll: { Task { for pack in manager.manifest.packs { await manager.pause(packID: pack.id) } } },
            resumeAll: { Task { for pack in manager.manifest.packs { _ = try? await manager.resume(packID: pack.id) } } },
            download: { id in Task { _ = try? await manager.startInstall(packID: id) } },
            retry: { id in Task { _ = try? await manager.startInstall(packID: id) } },
            verify: { id in
                Task {
                    guard let pack = manager.manifest.pack(id: id) else { return }
                    _ = await manager.downloader.verifyInstallation(of: pack, progress: nil)
                    _ = await manager.reconcileOnLaunch(resumeInterruptedDownloads: false)
                }
            },
            delete: { id in Task { try? await manager.delete(packID: id) } },
            redownload: { id in Task { try? await manager.redownload(packID: id) } }
        )
    }

    var settingsActions: SettingsActions {
        SettingsActions(
            done: { [weak self] in self?.isSettingsPresented = false },
            models: modelActions,
            requestPermission: { [weak self] kind in
                guard let self else { return }
                Task {
                    _ = await self.permissions.request(kind)
                    await self.refreshSettingsState()
                }
            },
            openSystemSettings: { _ in AppModel.openSystemSettings() },
            chooseFolder: { [weak self] in self?.isFolderPickerPresented = true },
            removeFolder: { [weak self] id in
                guard let self else { return }
                Task {
                    try? await self.fileScopes.removeScope(id: id)
                    await self.refreshSettingsState()
                }
            },
            setKeepHistory: { [weak self] keep in
                self?.settings.retainHistory = keep
                self?.persistSettings()
            },
            setRetentionDays: { [weak self] days in
                self?.settings.historyRetentionDays = days
                self?.persistSettings()
            },
            clearHistory: { [weak self] in
                guard let self else { return }
                Task {
                    try? await self.sessionStore?.clearHistory()
                    self.coordinator?.resetConversation()
                    await self.refreshSettingsState()
                }
            },
            setContinueListening: { [weak self] enabled in
                self?.settings.continueListening = enabled
                self?.voice?.continueListeningAfterResponse = enabled
                self?.persistSettings()
            },
            setHapticsEnabled: { [weak self] enabled in
                self?.settings.hapticsEnabled = enabled
                self?.persistSettings()
            },
            runBenchmark: { [weak self] in self?.runBenchmark() },
            cancelBenchmark: { [weak self] in
                self?.benchmarkTask?.cancel()
                self?.diagnostics.phase = .idle
            },
            setNetworkMode: { [weak self] mode in self?.setNetworkMode(mode) },
            clearNetworkLog: { [weak self] in self?.clearNetworkLog() }
        )
    }

    func addSharedFolder(_ url: URL) {
        Task {
            _ = try? await fileScopes.addScope(folderURL: url)
            await refreshSettingsState()
        }
    }

    func refreshSettingsState() async {
        let snapshot = await permissions.snapshot()
        permissionRows = [PermissionKind.microphone, .contacts, .calendar, .reminders].map {
            SettingsViewState.PermissionRow(kind: $0, status: snapshot.status($0))
        }
        sharedFolders = await fileScopes.scopes().map { SettingsViewState.SharedFolder(id: $0.id, name: $0.displayName) }
        let usage = await modelManager.storageUsage()
        storage = SettingsViewState.Storage(modelBytes: usage.totalBytes, freeBytes: usage.availableBytes)
        storedTurnCount = try? await sessionStore?.count()
        await refreshNetworkState()
    }

    // MARK: - Persistence

    private func openStores() {
        guard container == nil else { return }
        do {
            let container = try PersistenceSchema.makeContainer()
            self.container = container
            sessionStore = SessionStore(modelContainer: container)
            settingsStore = SettingsStore(modelContainer: container)
        } catch {
            PrivacySafeLogger.shared.log(.error(domain: "storage", code: "container_failed"))
        }
    }

    private func persist(_ turn: ConversationTurn) {
        guard settings.retainHistory, let sessionStore, let coordinator else { return }
        let conversation = coordinator.session.conversationID
        let retention = settings.historyRetentionDays
        Task {
            try? await sessionStore.append(turn, conversationID: conversation)
            try? await sessionStore.prune(olderThan: Date().addingTimeInterval(-Double(retention) * 86_400))
        }
    }

    func persistSettings() {
        guard let settingsStore else { return }
        let snapshot = settings
        Task { try? await settingsStore.save(snapshot) }
    }

    // MARK: - System events

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleMemoryWarning() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleThermalChange() }
        })
        // Coming forward is when the user's week is most likely to have moved under us — and when
        // whatever they shared while they were elsewhere is waiting to be read.
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.drainShareInbox()
                await self?.syncIngestion()
                await self?.refreshIntelligence()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.voice?.stop(reason: .appBackgrounded)
                if let scopes = self?.fileScopes { await scopes.relinquishAccess() }
            }
        })
    }

    private func handleMemoryWarning() async {
        PrivacySafeLogger.shared.log(.counter(name: "memory_warning", value: 1))
        await PerformanceMetrics.shared.sampleMemory()
        // Free the cheapest-to-reload model first; the LLM stays resident during a session.
        #if KOKORO_TTS
        if coordinator?.state.assistantIsSpeaking != true { await runtimes.kokoro?.unload() }
        #endif
    }

    private func handleThermalChange() async {
        let state = ThermalProbe.current
        PrivacySafeLogger.shared.log(.thermal(state: SafeLabel(state)))
        if state == .critical {
            await voice?.stop(reason: .failure)
        }
    }

    // MARK: - Diagnostics

    private func runBenchmark() {
        guard !diagnostics.isRunning else { return }
        diagnostics = SettingsViewState.Diagnostics(phase: .running(progress: 0, step: "Preparing"))
        let manager = modelManager
        let synthesizer = runtimes.synthesizer
        benchmarkTask = Task { [weak self] in
            do {
                let asr = try await manager.verifiedFileURLs(for: .asr)
                let llm = try await manager.verifiedFileURLs(for: .llm)
                let configuration = BenchmarkConfiguration(
                    whisperModel: asr[ModelFileName.whisperBaseEn]!, vadModel: asr[ModelFileName.sileroVAD],
                    nemotronModel: llm[ModelFileName.nemotronNano4B]!, synthesizer: synthesizer, synthesizerLoader: nil,
                    utteranceAudio: try BenchmarkController.loadBundledUtterance(),
                    utteranceReference: "text alex that i will be twenty minutes late",
                    iterations: 3, stateCacheDirectory: AppModel.applicationSupport.appendingPathComponent("LLMState")
                )
                let report = await DeviceBenchmarkRunner(configuration: configuration).run { progress in
                    Task { @MainActor in
                        if case let .stage(step, fraction) = progress {
                            self?.diagnostics.phase = .running(progress: fraction, step: step)
                        }
                    }
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-agent-benchmark.json")
                try? report.jsonData.write(to: url)
                self?.diagnostics = SettingsViewState.Diagnostics(phase: .finished(Date()), results: AppModel.metrics(from: report), reportURL: url)
            } catch {
                self?.diagnostics = SettingsViewState.Diagnostics(phase: .failed(message: "Install the models first."))
            }
        }
    }

    static func metrics(from report: BenchmarkReport) -> [SettingsViewState.Metric] {
        func row(_ stage: String, _ name: String, _ label: String, target: Double?, unit: String = "ms") -> SettingsViewState.Metric? {
            guard let metric = report.metric(stage, name) else { return nil }
            let value = unit == "ms" ? (metric.p50 >= 1000 ? String(format: "%.1f s", metric.p50 / 1000) : "\(Int(metric.p50)) ms")
                                     : String(format: "%.1f×", metric.p50)
            var assessment: SettingsViewState.Metric.Assessment = .info
            if let target { assessment = metric.p50 <= target ? .good : (metric.p50 <= target * 1.5 ? .fair : .poor) }
            let detail = target.map { $0 >= 1000 ? String(format: "Target under %.1f s", $0 / 1000) : "Target under \(Int($0)) ms" }
            return SettingsViewState.Metric(id: "\(stage).\(name)", label: label, value: value, detail: detail, assessment: assessment)
        }
        var rows = [
            row("end_to_end", "endpoint_to_first_audio", "Speech to first word", target: 1_500),
            row("asr", "final_transcript", "Transcription", target: 500),
            row("llm", "structured_result_total", "Understanding", target: 750),
            row("tts", "first_chunk_synthesis", "Voice start", target: 500),
            row("llm", "cold_load", "Language model load", target: nil),
        ].compactMap { $0 }
        rows.append(SettingsViewState.Metric(id: "memory", label: "Peak memory", value: "\(Int(report.peakFootprintMB)) MB"))
        rows.append(SettingsViewState.Metric(id: "thermal", label: "Thermal state", value: report.thermalStates.last?.capitalized ?? "—"))
        return rows
    }

    // MARK: - UIKit helpers

    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
