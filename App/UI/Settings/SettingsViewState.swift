import Core
import Foundation

/// Everything the Settings screen renders. A plain value; the app assembles it from
/// `ModelManager`, `PermissionManager`, `SettingsStore`, the session store and the benchmark.
struct SettingsViewState: Equatable, Sendable {
    var models: ModelDownloadViewState
    var storage: Storage
    /// Microphone, contacts, calendar and reminders, in that order (shared folders are listed
    /// in `sharedFolders`).
    var permissions: [PermissionRow]
    var sharedFolders: [SharedFolder]
    var privacy: Privacy
    var voice: Voice
    var diagnostics: Diagnostics
    var about: About

    init(
        models: ModelDownloadViewState,
        storage: Storage,
        permissions: [PermissionRow],
        sharedFolders: [SharedFolder] = [],
        privacy: Privacy,
        voice: Voice,
        diagnostics: Diagnostics = Diagnostics(),
        about: About
    ) {
        self.models = models
        self.storage = storage
        self.permissions = permissions
        self.sharedFolders = sharedFolders
        self.privacy = privacy
        self.voice = voice
        self.diagnostics = diagnostics
        self.about = about
    }

    struct Storage: Equatable, Sendable {
        /// Bytes used by model files, including resumable partial downloads.
        var modelBytes: Int64
        /// Bytes used by saved conversations; nil hides the row.
        var historyBytes: Int64?
        /// Free space on this iPhone; nil hides the row.
        var freeBytes: Int64?
        /// Total capacity; when known, a usage bar is drawn.
        var capacityBytes: Int64?

        init(modelBytes: Int64, historyBytes: Int64? = nil, freeBytes: Int64? = nil, capacityBytes: Int64? = nil) {
            self.modelBytes = modelBytes
            self.historyBytes = historyBytes
            self.freeBytes = freeBytes
            self.capacityBytes = capacityBytes
        }
    }

    struct PermissionRow: Equatable, Sendable, Identifiable {
        var kind: PermissionKind
        var status: PermissionStatus
        var id: PermissionKind { kind }

        init(kind: PermissionKind, status: PermissionStatus) {
            self.kind = kind
            self.status = status
        }
    }

    /// A folder the person shared through the document picker.
    struct SharedFolder: Equatable, Sendable, Identifiable {
        /// Stable id of the security-scoped bookmark.
        var id: String
        /// Folder name as shown in Files ("Documents", "Invoices").
        var name: String
        /// Where it lives ("iCloud Drive", "On My iPhone"); optional.
        var location: String?

        init(id: String, name: String, location: String? = nil) {
            self.id = id
            self.name = name
            self.location = location
        }
    }

    struct Privacy: Equatable, Sendable {
        var keepHistory: Bool
        /// 1...365 (clamped by `SettingsStore`).
        var retentionDays: Int
        /// Saved turns; shown under "Clear history" when known.
        var storedTurnCount: Int?

        init(keepHistory: Bool, retentionDays: Int, storedTurnCount: Int? = nil) {
            self.keepHistory = keepHistory
            self.retentionDays = retentionDays
            self.storedTurnCount = storedTurnCount
        }
    }

    struct Voice: Equatable, Sendable {
        /// Re-open the microphone after the assistant answers.
        var continueListening: Bool
        var hapticsEnabled: Bool
        /// False in builds without on-device speech output (the Simulator build).
        var speechOutputAvailable: Bool

        init(continueListening: Bool, hapticsEnabled: Bool, speechOutputAvailable: Bool = true) {
            self.continueListening = continueListening
            self.hapticsEnabled = hapticsEnabled
            self.speechOutputAvailable = speechOutputAvailable
        }
    }

    struct Diagnostics: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            /// `progress` 0...1; `step` names what is being measured ("Language model").
            case running(progress: Double, step: String)
            case finished(Date)
            case failed(message: String)
        }

        var phase: Phase
        var results: [Metric]
        /// A report file to share. The Share button appears when it is set.
        var reportURL: URL?

        init(phase: Phase = .idle, results: [Metric] = [], reportURL: URL? = nil) {
            self.phase = phase
            self.results = results
            self.reportURL = reportURL
        }

        var isRunning: Bool {
            if case .running = phase { return true }
            return false
        }
    }

    struct Metric: Equatable, Sendable, Identifiable {
        enum Assessment: Equatable, Sendable {
            /// Meets its target.
            case good
            /// Close to its target.
            case fair
            /// Misses its target.
            case poor
            /// No target (for example thermal state).
            case info
        }

        var id: String
        /// "Speech to first word".
        var label: String
        /// "820 ms".
        var value: String
        /// "Target under 1.2 s".
        var detail: String?
        var assessment: Assessment

        init(id: String, label: String, value: String, detail: String? = nil, assessment: Assessment = .info) {
            self.id = id
            self.label = label
            self.value = value
            self.detail = detail
            self.assessment = assessment
        }
    }

    struct About: Equatable, Sendable {
        /// "1.0.0".
        var version: String
        /// "1".
        var build: String
        var licenses: [License]

        init(version: String, build: String, licenses: [License] = License.bundled) {
            self.version = version
            self.build = build
            self.licenses = licenses
        }

        /// Reads `CFBundleShortVersionString` / `CFBundleVersion`.
        static func current(bundle: Bundle = .main) -> About {
            About(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
            )
        }
    }

    struct License: Equatable, Sendable, Identifiable {
        var name: String
        /// SPDX-style name ("MIT", "Apache-2.0").
        var license: String
        /// What it does in this app.
        var role: String
        var url: URL?
        var id: String { name }

        init(name: String, license: String, role: String, url: URL? = nil) {
            self.name = name
            self.license = license
            self.role = role
            self.url = url
        }

        /// Third-party components shipped with or downloaded by the app.
        static let bundled: [License] = [
            License(name: "whisper.cpp", license: "MIT", role: "Speech recognition runtime", url: URL(string: "https://github.com/ggml-org/whisper.cpp")),
            License(name: "Whisper base.en", license: "MIT", role: "Speech recognition model (OpenAI)", url: URL(string: "https://github.com/openai/whisper")),
            License(name: "Silero VAD", license: "MIT", role: "Voice activity detection model", url: URL(string: "https://github.com/snakers4/silero-vad")),
            License(name: "llama.cpp", license: "MIT", role: "Language model runtime", url: URL(string: "https://github.com/ggml-org/llama.cpp")),
            License(name: "NVIDIA Nemotron 3 Nano 4B", license: "NVIDIA Nemotron Open Model License", role: "Language model", url: URL(string: "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF")),
            License(name: "Kokoro 82M", license: "Apache-2.0", role: "Voice model", url: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16")),
            License(name: "KokoroSwift", license: "MIT", role: "Voice runtime", url: URL(string: "https://github.com/mlalma/kokoro-ios")),
            License(name: "MisakiSwift", license: "Apache-2.0", role: "Pronunciation for the voice", url: URL(string: "https://github.com/mlalma/MisakiSwift")),
            License(name: "MLX Swift", license: "MIT", role: "On-device machine learning", url: URL(string: "https://github.com/ml-explore/mlx-swift")),
            License(name: "DM Sans", license: "SIL Open Font License 1.1", role: "Typeface", url: URL(string: "https://github.com/googlefonts/dm-fonts")),
        ]
    }
}

/// What the person can do in Settings.
struct SettingsActions {
    var done: @MainActor () -> Void
    var models: ModelDownloadActions
    /// "Allow" on a permission that iOS has not asked for yet (shows the system prompt).
    var requestPermission: @MainActor (_ kind: PermissionKind) -> Void
    /// "Open Settings" on a denied or limited permission.
    var openSystemSettings: @MainActor (_ kind: PermissionKind) -> Void
    /// "Choose folder…": present the document picker.
    var chooseFolder: @MainActor () -> Void
    /// Stop sharing a folder (`SharedFolder.id`).
    var removeFolder: @MainActor (_ id: String) -> Void
    var setKeepHistory: @MainActor (_ keep: Bool) -> Void
    var setRetentionDays: @MainActor (_ days: Int) -> Void
    /// After the confirmation dialog.
    var clearHistory: @MainActor () -> Void
    var setContinueListening: @MainActor (_ enabled: Bool) -> Void
    var setHapticsEnabled: @MainActor (_ enabled: Bool) -> Void
    var runBenchmark: @MainActor () -> Void
    var cancelBenchmark: @MainActor () -> Void

    init(
        done: @escaping @MainActor () -> Void,
        models: ModelDownloadActions,
        requestPermission: @escaping @MainActor (_ kind: PermissionKind) -> Void,
        openSystemSettings: @escaping @MainActor (_ kind: PermissionKind) -> Void,
        chooseFolder: @escaping @MainActor () -> Void,
        removeFolder: @escaping @MainActor (_ id: String) -> Void,
        setKeepHistory: @escaping @MainActor (_ keep: Bool) -> Void,
        setRetentionDays: @escaping @MainActor (_ days: Int) -> Void,
        clearHistory: @escaping @MainActor () -> Void,
        setContinueListening: @escaping @MainActor (_ enabled: Bool) -> Void,
        setHapticsEnabled: @escaping @MainActor (_ enabled: Bool) -> Void,
        runBenchmark: @escaping @MainActor () -> Void,
        cancelBenchmark: @escaping @MainActor () -> Void
    ) {
        self.done = done
        self.models = models
        self.requestPermission = requestPermission
        self.openSystemSettings = openSystemSettings
        self.chooseFolder = chooseFolder
        self.removeFolder = removeFolder
        self.setKeepHistory = setKeepHistory
        self.setRetentionDays = setRetentionDays
        self.clearHistory = clearHistory
        self.setContinueListening = setContinueListening
        self.setHapticsEnabled = setHapticsEnabled
        self.runBenchmark = runBenchmark
        self.cancelBenchmark = cancelBenchmark
    }

    static var inert: SettingsActions {
        SettingsActions(
            done: {}, models: .inert, requestPermission: { _ in }, openSystemSettings: { _ in },
            chooseFolder: {}, removeFolder: { _ in }, setKeepHistory: { _ in }, setRetentionDays: { _ in },
            clearHistory: {}, setContinueListening: { _ in }, setHapticsEnabled: { _ in },
            runBenchmark: {}, cancelBenchmark: {}
        )
    }
}
