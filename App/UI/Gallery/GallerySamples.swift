import Agent
import Core
import Foundation

/// Realistic sample data for previews and the design gallery. Compiled in every
/// configuration (the gallery ships behind the `-DesignGallery` launch argument).
enum GallerySamples {
    // MARK: Action cards

    static let messageCard = messageCard(now: Date())
    static let eventCard = eventCard(now: Date())

    static func messageCard(now: Date) -> ActionCard {
        ActionCard(
            id: UUID(uuidString: "6F1D2C1A-5B7E-4B7A-9C8E-1A2B3C4D5E01")!,
            version: 1,
            tool: .composeMessage,
            title: "Send message",
            systemImage: "message.fill",
            fields: [
                .init(label: "To", value: "Alex Kim"),
                .init(label: "Number", value: "+1 555-010-1001 (mobile)"),
                .init(label: "Message", value: "I\u{2019}ll be 20 minutes late."),
            ],
            confirmLabel: "Send",
            riskLevel: .externalCommunication,
            expiresAt: now.addingTimeInterval(285),
            footnote: "Messages opens with this text. You tap Send to finish."
        )
    }

    static func eventCard(now: Date) -> ActionCard {
        ActionCard(
            id: UUID(uuidString: "6F1D2C1A-5B7E-4B7A-9C8E-1A2B3C4D5E02")!,
            version: 2,
            tool: .createCalendarEvent,
            title: "Add to calendar",
            systemImage: "calendar.badge.plus",
            fields: [
                .init(label: "Event", value: "Dentist"),
                .init(label: "When", value: "Fri, Sep 25, 3 PM \u{2013} 4 PM"),
                .init(label: "Where", value: "Harbor Dental, 200 Main St"),
            ],
            confirmLabel: "Add",
            riskLevel: .reversibleLocalWrite,
            expiresAt: now.addingTimeInterval(240),
            footnote: nil
        )
    }

    static func callCard(now: Date) -> ActionCard {
        ActionCard(
            id: UUID(uuidString: "6F1D2C1A-5B7E-4B7A-9C8E-1A2B3C4D5E03")!,
            version: 1,
            tool: .initiateCall,
            title: "Call",
            systemImage: "phone.fill",
            fields: [
                .init(label: "To", value: "Mom"),
                .init(label: "Number", value: "+1 555-010-4477 (home)"),
            ],
            confirmLabel: "Call",
            riskLevel: .externalCommunication,
            expiresAt: now.addingTimeInterval(16),
            footnote: "iPhone may ask you to confirm the call."
        )
    }

    static func reminderCard(now: Date) -> ActionCard {
        ActionCard(
            id: UUID(uuidString: "6F1D2C1A-5B7E-4B7A-9C8E-1A2B3C4D5E04")!,
            version: 1,
            tool: .createReminder,
            title: "Create reminder",
            systemImage: "checklist",
            fields: [
                .init(label: "Reminder", value: "Pick up the dry cleaning"),
                .init(label: "Due", value: "Tomorrow, 6 PM"),
            ],
            confirmLabel: "Create",
            riskLevel: .reversibleLocalWrite,
            expiresAt: now.addingTimeInterval(180),
            footnote: nil
        )
    }

    static func longMessageCard(now: Date) -> ActionCard {
        ActionCard(
            id: UUID(uuidString: "6F1D2C1A-5B7E-4B7A-9C8E-1A2B3C4D5E05")!,
            version: 3,
            tool: .composeMessage,
            title: "Send message",
            systemImage: "message.fill",
            fields: [
                .init(label: "To", value: "Priya Raghunathan-Okonkwo"),
                .init(label: "Number", value: "+44 20 7946 0958 (work)"),
                .init(label: "Message", value: "Running about twenty minutes behind because the train is stuck outside the station. Start without me and I\u{2019}ll catch up on the budget numbers when I get there. Sorry!"),
            ],
            confirmLabel: "Send",
            riskLevel: .externalCommunication,
            expiresAt: now.addingTimeInterval(300),
            footnote: "Messages opens with this text. You tap Send to finish."
        )
    }

    // MARK: Clarification, permissions, banners

    static let alexChoices: [ClarificationChoice] = [
        ClarificationChoice(id: "contact-alex-kim", title: "Alex Kim", subtitle: "mobile"),
        ClarificationChoice(id: "contact-alex-chen", title: "Alex Chen", subtitle: "work"),
    ]

    static let permissionPrompts: [PermissionPrompt] = [
        PermissionPrompt(kind: .contacts, title: "Contacts access", message: "To call or message people, Voice Agent needs to look them up in your contacts.", requiresSettings: true),
        PermissionPrompt(kind: .calendar, title: "Calendar access", message: "To read and change events, Voice Agent needs access to your calendar.", requiresSettings: false),
        PermissionPrompt(kind: .fileScope, title: "Share a folder", message: "Choose a folder in Settings so Voice Agent can search and open files in it.", requiresSettings: false),
        PermissionPrompt(kind: .microphone, title: "Microphone access", message: "Voice Agent needs the microphone to hear you. Audio stays on this iPhone.", requiresSettings: true),
    ]

    static let successBanner = ResultBanner(style: .success, text: "Message sent to Alex Kim", systemImage: "checkmark.message.fill")
    static let cancelledBanner = ResultBanner(style: .cancelled, text: "Okay, the message wasn\u{2019}t sent.", systemImage: "xmark.circle")
    static let failureBanner = ResultBanner(style: .failure, text: "That request expired, so I didn\u{2019}t do it.", systemImage: "exclamationmark.triangle")

    // MARK: Conversation

    static let turns: [ConversationTurn] = {
        let base = Date().addingTimeInterval(-3 * 3600)
        return [
            ConversationTurn(role: .user, text: "What\u{2019}s on my calendar tomorrow?", timestamp: base),
            ConversationTurn(role: .assistant, text: "You have 2 events tomorrow: \u{201C}Team sync\u{201D} at 10 AM and \u{201C}Dentist\u{201D} at 3 PM.", timestamp: base.addingTimeInterval(4)),
            ConversationTurn(role: .user, text: "Move the dentist to Friday at 3", timestamp: base.addingTimeInterval(20)),
            ConversationTurn(role: .assistant, text: "Move \u{201C}Dentist\u{201D} to Friday, September 25 from 3 PM to 4 PM. Should I update it?", timestamp: base.addingTimeInterval(24)),
            ConversationTurn(role: .user, text: "Yes", timestamp: base.addingTimeInterval(29)),
            ConversationTurn(role: .assistant, text: "Done. \u{201C}Dentist\u{201D} is now on Friday, September 25 at 3 PM.", timestamp: base.addingTimeInterval(31)),
            ConversationTurn(role: .user, text: "Text Alex that I\u{2019}ll be 20 minutes late", timestamp: base.addingTimeInterval(2 * 3600 + 50 * 60)),
            ConversationTurn(role: .assistant, text: "Which Alex? Alex Kim or Alex Chen?", timestamp: base.addingTimeInterval(2 * 3600 + 50 * 60 + 3)),
            ConversationTurn(role: .user, text: "Kim", timestamp: base.addingTimeInterval(2 * 3600 + 50 * 60 + 9)),
            ConversationTurn(role: .assistant, text: "Text Alex Kim: \u{201C}I\u{2019}ll be 20 minutes late.\u{201D} Should I send it?", timestamp: base.addingTimeInterval(2 * 3600 + 50 * 60 + 12)),
        ]
    }()

    /// The assistant screen in `state`, with the data that state would plausibly carry.
    static func presentation(for state: AgentState, now: Date = Date()) -> AssistantPresentation {
        var p = AssistantPresentation(state: state, turns: turns)
        switch state {
        case .booting:
            break
        case .downloadingModels:
            p.assistantText = "Downloading the voice models. This happens once."
        case .warmingModels:
            p.assistantText = "Getting ready\u{2026}"
        case .idle:
            break
        case .listening:
            p.isSessionActive = true
            p.partialTranscript = "Text Alex that I\u{2019}ll be twenty"
            p.inputLevel = 0.55
        case .endpointing:
            p.isSessionActive = true
            p.partialTranscript = "Text Alex that I\u{2019}ll be 20 minutes late"
            p.inputLevel = 0.08
        case .transcribing, .thinking:
            p.isSessionActive = true
            p.lastUserUtterance = "Text Alex that I\u{2019}ll be 20 minutes late"
        case .speaking:
            p.isSessionActive = true
            p.lastUserUtterance = "What\u{2019}s on my calendar tomorrow?"
            p.assistantText = "You have 2 events tomorrow: \u{201C}Team sync\u{201D} at 10 AM and \u{201C}Dentist\u{201D} at 3 PM."
            p.outputLevel = 0.5
        case .waitingForClarification:
            p.isSessionActive = true
            p.lastUserUtterance = "Text Alex that I\u{2019}ll be 20 minutes late"
            p.assistantText = "Which Alex? Alex Kim or Alex Chen?"
            p.clarificationChoices = alexChoices
        case .waitingForConfirmation:
            p.isSessionActive = true
            p.lastUserUtterance = "Kim"
            p.assistantText = "Text Alex Kim: \u{201C}I\u{2019}ll be 20 minutes late.\u{201D} Should I send it?"
            p.actionCard = messageCard(now: now)
        case .executing:
            p.isSessionActive = true
            p.lastUserUtterance = "Yes, send it"
        case .reportingResult:
            p.isSessionActive = true
            p.lastUserUtterance = "Yes, send it"
            p.assistantText = "Sent to Alex Kim."
            p.resultBanner = successBanner
            p.outputLevel = 0.35
        case .interrupted:
            p.isSessionActive = true
            p.partialTranscript = "Actually, wait"
            p.inputLevel = 0.4
        case .permissionRequired:
            p.isSessionActive = true
            p.lastUserUtterance = "Call Mom"
            p.assistantText = "I don\u{2019}t have permission to use your contacts. You can allow it in Settings."
            p.permissionPrompt = permissionPrompts[0]
        case .error:
            p.lastUserUtterance = "What\u{2019}s on my calendar tomorrow?"
            p.assistantText = "Something went wrong, so I couldn\u{2019}t do that."
        }
        return p
    }

    // MARK: Model downloads

    private static let asrBytes: Int64 = 148_849_309
    private static let llmBytes: Int64 = 2_837_072_864
    private static let ttsBytes: Int64 = 327_637_472

    static func packs(asr: ModelDownloadViewState.Pack.State, llm: ModelDownloadViewState.Pack.State, tts: ModelDownloadViewState.Pack.State,
                      llmDownloaded: Int64 = 0, rate: Double? = nil) -> [ModelDownloadViewState.Pack] {
        func downloaded(_ state: ModelDownloadViewState.Pack.State, total: Int64, partial: Int64) -> Int64 {
            switch state {
            case .installed, .verifying, .corrupt: total
            case let .downloading(progress): Int64(Double(total) * progress)
            default: partial
            }
        }
        return [
            .init(id: "whisper-base.en", name: "Speech recognition", detail: "Whisper base.en", systemImage: "waveform",
                  totalBytes: asrBytes, downloadedBytes: downloaded(asr, total: asrBytes, partial: 0), state: asr),
            .init(id: "nemotron-3-nano-4b-q4_k_m", name: "Language model", detail: "NVIDIA Nemotron 3 Nano 4B", systemImage: "brain",
                  totalBytes: llmBytes, downloadedBytes: downloaded(llm, total: llmBytes, partial: llmDownloaded), state: llm,
                  bytesPerSecond: rate),
            .init(id: "kokoro-82m", name: "Voice", detail: "Kokoro 82M", systemImage: "speaker.wave.2.fill",
                  totalBytes: ttsBytes, downloadedBytes: downloaded(tts, total: ttsBytes, partial: 0), state: tts),
        ]
    }

    static let downloadsNotStarted = ModelDownloadViewState(
        packs: packs(asr: .notInstalled, llm: .notInstalled, tts: .notInstalled),
        freeSpaceBytes: 41_200_000_000, network: .wifi
    )

    static let downloadsInProgress = ModelDownloadViewState(
        packs: packs(asr: .installed, llm: .downloading(progress: 0.42), tts: .queued, rate: 18_500_000),
        freeSpaceBytes: 39_800_000_000, network: .wifi
    )

    static let downloadsPaused = ModelDownloadViewState(
        packs: packs(asr: .installed, llm: .paused, tts: .notInstalled, llmDownloaded: 1_730_000_000),
        freeSpaceBytes: 39_100_000_000, network: .cellular
    )

    static let downloadsProblems = ModelDownloadViewState(
        packs: packs(
            asr: .corrupt,
            llm: .failed(message: "Download interrupted. Check your internet connection and try again."),
            tts: .verifying(progress: 0.7),
            llmDownloaded: 912_000_000
        ),
        freeSpaceBytes: 38_600_000_000, network: .offline
    )

    static let downloadsNoSpace = ModelDownloadViewState(
        packs: packs(asr: .notInstalled, llm: .notInstalled, tts: .notInstalled),
        freeSpaceBytes: 1_240_000_000, network: .cellular
    )

    static let downloadsInstalled = ModelDownloadViewState(
        packs: packs(asr: .installed, llm: .installed, tts: .installed),
        freeSpaceBytes: 38_200_000_000, network: .wifi
    )

    // MARK: Settings

    static let benchmarkResults: [SettingsViewState.Metric] = [
        .init(id: "e2e", label: "Speech to first word", value: "1.18 s", detail: "Target under 1.5 s", assessment: .good),
        .init(id: "asr", label: "Transcription", value: "310 ms", detail: "After you stop talking", assessment: .good),
        .init(id: "llm-ttft", label: "Model first token", value: "640 ms", detail: "Target under 600 ms", assessment: .fair),
        .init(id: "llm-speed", label: "Model speed", value: "17.8 tok/s", detail: "Target over 12 tok/s", assessment: .good),
        .init(id: "tts", label: "Voice first audio", value: "420 ms", detail: "Target under 300 ms", assessment: .poor),
        .init(id: "memory", label: "Peak memory", value: "3.1 GB", detail: "Of 8 GB on this iPhone"),
        .init(id: "thermal", label: "Thermal state", value: "Nominal"),
    ]

    static let settings = SettingsViewState(
        models: downloadsInstalled,
        storage: .init(modelBytes: 3_313_559_645, historyBytes: 184_320, freeBytes: 38_200_000_000, capacityBytes: 128_000_000_000),
        permissions: [
            .init(kind: .microphone, status: .granted),
            .init(kind: .contacts, status: .denied),
            .init(kind: .calendar, status: .granted),
            .init(kind: .reminders, status: .notDetermined),
        ],
        sharedFolders: [.init(id: "bookmark-documents", name: "Documents", location: "iCloud Drive")],
        privacy: .init(keepHistory: true, retentionDays: 30, storedTurnCount: 124),
        voice: .init(continueListening: true, hapticsEnabled: true, speechOutputAvailable: false),
        diagnostics: .init(
            phase: .finished(Date().addingTimeInterval(-26 * 60)),
            results: benchmarkResults,
            reportURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VoiceAgent-benchmark.json")
        ),
        about: .init(version: "1.0.0", build: "1")
    )

    static let settingsBusy: SettingsViewState = {
        var state = settings
        state.models = downloadsProblems
        state.storage = .init(modelBytes: 1_060_000_000, historyBytes: nil, freeBytes: 38_600_000_000)
        state.permissions = [
            .init(kind: .microphone, status: .granted),
            .init(kind: .contacts, status: .limited),
            .init(kind: .calendar, status: .notDetermined),
            .init(kind: .reminders, status: .restricted),
        ]
        state.sharedFolders = []
        state.privacy = .init(keepHistory: false, retentionDays: 30, storedTurnCount: 0)
        state.voice = .init(continueListening: false, hapticsEnabled: true, speechOutputAvailable: true)
        state.diagnostics = .init(phase: .running(progress: 0.46, step: "Language model"), results: Array(benchmarkResults.prefix(2)))
        return state
    }()
}
