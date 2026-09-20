import Core
import Intelligence
import SwiftUI

/// Sections of Settings, for deep links (for example the shared-folder permission card
/// opens Settings at `.permissions`).
enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case models, storage, permissions, files, privacy, network, voice, diagnostics, about
}

/// Settings: models, storage, permissions, privacy, voice, diagnostics and about. Present it
/// in a sheet; "Done" calls `actions.done`.
struct SettingsScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions
    var initialSection: SettingsSection?

    @State private var confirmsClearHistory = false

    init(state: SettingsViewState, actions: SettingsActions, initialSection: SettingsSection? = nil) {
        self.state = state
        self.actions = actions
        self.initialSection = initialSection
        DesignSystemAppearance.install()
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    modelsSection
                    storageSection
                    permissionsSection
                    filesSection
                    privacySection
                    networkSection
                    voiceSection
                    diagnosticsSection
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
                .font(.dm(.body))
                .tint(Palette.jade)
                .task {
                    guard let initialSection else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    scroller.scrollTo(initialSection, anchor: .top)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: actions.done) {
                        Text("Done").textStyle(.body, weight: .semibold)
                    }
                }
            }
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            ModelDownloadsView(state: state.models, actions: actions.models)
            if let bulk = bulkModelAction {
                Button(action: bulk.action) {
                    Label(bulk.title, systemImage: bulk.image)
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                }
            }
        } header: {
            SettingsHeader("Models")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if !state.models.allInstalled {
                    ModelDownloadHints(state: state.models)
                }
                SettingsFooter("The models run only on this iPhone. Each file is checked against a pinned checksum before it\u{2019}s used.")
            }
        }
        .id(SettingsSection.models)
    }

    private var bulkModelAction: (title: String, image: String, action: @MainActor () -> Void)? {
        let models = state.models
        if models.allInstalled { return nil }
        if models.isInProgress { return ("Pause downloads", "pause.circle", actions.models.pauseAll) }
        if models.isPaused { return ("Resume downloads", "arrow.down.circle", actions.models.resumeAll) }
        return ("Download all (\(Formatting.bytes(models.remainingBytes)))", "arrow.down.circle", actions.models.downloadAll)
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            if let capacity = state.storage.capacityBytes, let free = state.storage.freeBytes {
                StorageBar(modelBytes: state.storage.modelBytes, freeBytes: free, capacityBytes: capacity)
                    .padding(.vertical, Spacing.s)
            }
            ValueRow(title: "Voice models", value: Formatting.bytes(state.storage.modelBytes), swatch: Palette.jade)
            if let history = state.storage.historyBytes {
                ValueRow(title: "Conversation history", value: Formatting.bytes(history))
            }
            if let free = state.storage.freeBytes {
                ValueRow(title: "Available on iPhone", value: Formatting.bytes(free))
            }
        } header: {
            SettingsHeader("Storage")
        }
        .id(SettingsSection.storage)
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(state.permissions) { row in
                PermissionStatusRow(
                    row: row,
                    onAllow: { actions.requestPermission(row.kind) },
                    onOpenSettings: { actions.openSystemSettings(row.kind) }
                )
            }
        } header: {
            SettingsHeader("Permissions")
        } footer: {
            SettingsFooter("Voice Agent asks for each permission the first time a request needs it.")
        }
        .id(SettingsSection.permissions)
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            ForEach(state.sharedFolders) { folder in
                SharedFolderRow(folder: folder, onRemove: { actions.removeFolder(folder.id) })
            }
            Button(action: actions.chooseFolder) {
                HStack(spacing: Spacing.m) {
                    IconTile(systemImage: "folder.badge.plus", tone: .neutral, size: 30)
                    Text(state.sharedFolders.isEmpty ? "Choose folder\u{2026}" : "Choose another folder\u{2026}")
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                }
            }
            .accessibilityHint("Opens Files so you can choose a folder Voice Agent may search.")
        } header: {
            SettingsHeader("Files")
        } footer: {
            SettingsFooter(state.sharedFolders.isEmpty
                ? "Voice Agent can\u{2019}t see any of your files. Choose a folder to let it search and open the files inside."
                : "Voice Agent can search and open files only in these folders.")
        }
        .id(SettingsSection.files)
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.m) {
                IconTile(systemImage: "lock.shield.fill", tone: .jade, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing leaves this iPhone")
                        .textStyle(.headline)
                    Text("Your voice, requests and history are processed and stored only here. There\u{2019}s no account and no server.")
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .combine)

            Toggle(isOn: Binding(get: { state.privacy.keepHistory }, set: { actions.setKeepHistory($0) })) {
                RowLabel(title: "Keep history", subtitle: "Save recent conversations on this iPhone.")
            }

            Picker(selection: Binding(get: { state.privacy.retentionDays }, set: { actions.setRetentionDays($0) })) {
                ForEach(retentionOptions, id: \.self) { days in
                    Text(retentionLabel(days)).tag(days)
                }
            } label: {
                Text("Keep for").textStyle(.body)
            }
            .disabled(!state.privacy.keepHistory)

            Button(role: .destructive) {
                confirmsClearHistory = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clear history\u{2026}")
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.danger)
                    if let count = state.privacy.storedTurnCount {
                        Text(count == 1 ? "1 saved turn" : "\(count) saved turns")
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmsClearHistory, titleVisibility: .visible) {
                Button("Clear history", role: .destructive, action: actions.clearHistory)
            } message: {
                Text("Every saved conversation is removed from this iPhone. This can\u{2019}t be undone.")
            }
        } header: {
            SettingsHeader("Privacy")
        }
        .id(SettingsSection.privacy)
    }

    // MARK: Internet

    /// The only door out of the phone, and the record of everything that went through it.
    private var networkSection: some View {
        Section {
            Picker(selection: Binding(
                get: { state.privacy.network.mode },
                set: { actions.setNetworkMode($0) }
            )) {
                ForEach(NetworkMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                RowLabel(title: "Reach the internet", subtitle: state.privacy.network.mode.explanation)
            }
            .pickerStyle(.navigationLink)

            NavigationLink {
                NetworkLogScreen(network: state.privacy.network, onClear: actions.clearNetworkLog)
            } label: {
                RowLabel(
                    title: "What left this iPhone",
                    subtitle: state.privacy.network.sent == 0
                        ? "Nothing has ever left."
                        : "\(state.privacy.network.sent) sent · \(state.privacy.network.refused) refused · \(state.privacy.network.bytesText)"
                )
            }
        } header: {
            SettingsHeader("Internet")
        } footer: {
            Text("Everything else — your voice, your world, your documents — is processed here and never sent, whatever this is set to.")
                .textStyle(.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
        .id(SettingsSection.network)
    }

    private var retentionOptions: [Int] {
        var options = [7, 30, 90, 365]
        if !options.contains(state.privacy.retentionDays) {
            options.append(state.privacy.retentionDays)
            options.sort()
        }
        return options
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 7: "1 week"
        case 30: "30 days"
        case 90: "90 days"
        case 365: "1 year"
        default: days == 1 ? "1 day" : "\(days) days"
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            Toggle(isOn: Binding(get: { state.voice.continueListening }, set: { actions.setContinueListening($0) })) {
                RowLabel(title: "Keep listening after replies", subtitle: "Answer follow-up questions without tapping again.")
            }
            Toggle(isOn: Binding(get: { state.voice.hapticsEnabled }, set: { actions.setHapticsEnabled($0) })) {
                RowLabel(title: "Haptics", subtitle: nil)
            }
            if !state.voice.speechOutputAvailable {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text("Spoken replies aren\u{2019}t available in this build. Replies appear as text.")
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            SettingsHeader("Voice")
        }
        .id(SettingsSection.voice)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            DiagnosticsControls(diagnostics: state.diagnostics, onRun: actions.runBenchmark, onCancel: actions.cancelBenchmark)
            ForEach(state.diagnostics.results) { metric in
                MetricRow(metric: metric)
            }
            if let url = state.diagnostics.reportURL, !state.diagnostics.isRunning {
                ShareLink(item: url) {
                    Label("Share results", systemImage: "square.and.arrow.up")
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                }
            }
        } header: {
            SettingsHeader("Diagnostics")
        } footer: {
            SettingsFooter("The benchmark measures speech recognition, the language model and the voice on this iPhone. Results stay here unless you share them.")
        }
        .id(SettingsSection.diagnostics)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            ValueRow(title: "Version", value: "\(state.about.version) (\(state.about.build))")
            NavigationLink {
                LicensesView(licenses: state.about.licenses)
            } label: {
                Text("Third-party licenses").textStyle(.body)
            }
        } header: {
            SettingsHeader("About")
        } footer: {
            SettingsFooter("Speech recognition, the language model and the voice all run on this iPhone.")
        }
        .id(SettingsSection.about)
    }
}

// MARK: - Rows

struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textStyle(.subheadline, weight: .semibold)
            .foregroundStyle(Palette.inkSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.inkSecondary)
    }
}

/// Title with an optional one-line explanation.
struct RowLabel: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textStyle(.body)
                .foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Voice models ........ 3.31 GB".
struct ValueRow: View {
    let title: String
    let value: String
    var swatch: Color?

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let swatch {
                Circle().fill(swatch).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(title).textStyle(.body).foregroundStyle(Palette.ink)
            Spacer(minLength: Spacing.m)
            Text.tabular(value)
                .textStyle(.body)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// How much of the iPhone the models take, next to everything else and the free space.
struct StorageBar: View {
    let modelBytes: Int64
    let freeBytes: Int64
    let capacityBytes: Int64

    var body: some View {
        let capacity = Double(max(capacityBytes, 1))
        let models = Double(modelBytes) / capacity
        let other = max(0, Double(capacityBytes - freeBytes - modelBytes) / capacity)
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("\(Formatting.bytes(capacityBytes - freeBytes)) of \(Formatting.bytes(capacityBytes)) used")
                .textStyle(.subheadline, weight: .medium)
                .foregroundStyle(Palette.ink)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Palette.jade).frame(width: max(3, proxy.size.width * models))
                    Rectangle().fill(Palette.mist.opacity(0.55)).frame(width: proxy.size.width * other)
                    Spacer(minLength: 0)
                }
                .background(Palette.fill)
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 10)
            HStack(spacing: Spacing.l) {
                legend("Voice models", color: Palette.jade)
                legend("Everything else", color: Palette.mist.opacity(0.55))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue("\(Formatting.bytes(modelBytes)) used by voice models, \(Formatting.bytes(freeBytes)) available")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).textStyle(.footnote).foregroundStyle(Palette.inkSecondary)
        }
    }
}

struct PermissionStatusRow: View {
    let row: SettingsViewState.PermissionRow
    let onAllow: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        layout {
            HStack(spacing: Spacing.m) {
                IconTile(systemImage: row.kind.systemImage, tone: row.status == .granted ? .jade : .neutral, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.kind.displayName)
                        .textStyle(.body)
                        .foregroundStyle(Palette.ink)
                    Text(subtitle)
                        .textStyle(.footnote)
                        .foregroundStyle(row.status == .denied ? Palette.danger : Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(row.status.displayName)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            trailing
        }
    }

    private var subtitle: String {
        switch row.status {
        case .denied: "Turned off. \(row.kind.purpose)."
        case .restricted: "Restricted on this iPhone."
        case .limited: "Limited access. \(row.kind.purpose)."
        default: row.kind.purpose
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .granted:
            StatusPill("Allowed", systemImage: "checkmark", tone: .jade)
        case .notDetermined:
            Button(action: onAllow) { Text("Allow") }
                .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                .accessibilityLabel("Allow \(row.kind.displayName)")
        case .denied, .limited:
            Button(action: onOpenSettings) { Text("Open Settings") }
                .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                .accessibilityLabel("Open Settings for \(row.kind.displayName)")
        case .restricted:
            StatusPill("Restricted", tone: .neutral)
        }
    }
}

private struct SharedFolderRow: View {
    let folder: SettingsViewState.SharedFolder
    let onRemove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            IconTile(systemImage: "folder.fill", tone: .jade, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).textStyle(.body).foregroundStyle(Palette.ink)
                if let location = folder.location {
                    Text(location).textStyle(.footnote).foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer(minLength: Spacing.s)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop sharing \(folder.name)")
        }
        .accessibilityElement(children: .contain)
        .swipeActions {
            Button(role: .destructive, action: onRemove) { Label("Stop sharing", systemImage: "folder.badge.minus") }
        }
    }
}

private struct DiagnosticsControls: View {
    let diagnostics: SettingsViewState.Diagnostics
    let onRun: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        switch diagnostics.phase {
        case let .running(progress, step):
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Measuring \(step.lowercased())\u{2026}")
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: Spacing.s)
                    Text.tabular(Formatting.percent(progress))
                        .textStyle(.body)
                        .foregroundStyle(Palette.inkSecondary)
                }
                ProgressBar(value: progress)
                Button(action: onCancel) { Text("Stop") }
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    .padding(.top, Spacing.xs)
            }
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .contain)
        case let .failed(message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .textStyle(.subheadline, weight: .medium)
                    .foregroundStyle(Palette.danger)
                runButton(title: "Run again")
            }
        case let .finished(date):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Last run \(date.formatted(date: .abbreviated, time: .shortened))")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                runButton(title: "Run again")
            }
        case .idle:
            runButton(title: "Run benchmark")
        }
    }

    private func runButton(title: String) -> some View {
        Button(action: onRun) {
            Label(title, systemImage: "gauge.with.dots.needle.67percent")
                .textStyle(.body, weight: .medium)
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.borderless)
    }
}

private struct MetricRow: View {
    let metric: SettingsViewState.Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.label).textStyle(.body).foregroundStyle(Palette.ink)
                if let detail = metric.detail {
                    Text(detail).textStyle(.footnote).foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer(minLength: Spacing.s)
            HStack(spacing: 6) {
                Text(metric.value)
                    .textStyle(.body, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                if let tone = tone {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tone.color)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(assessmentText)
    }

    private var tone: Tone? {
        switch metric.assessment {
        case .good: .jade
        case .fair: .amber
        case .poor: .danger
        case .info: nil
        }
    }

    private var symbol: String {
        switch metric.assessment {
        case .good: "checkmark.circle.fill"
        case .fair: "minus.circle.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    private var assessmentText: String {
        switch metric.assessment {
        case .good: "Meets target"
        case .fair: "Near target"
        case .poor: "Misses target"
        case .info: ""
        }
    }
}

#Preview("Settings") {
    SettingsScreen(state: GallerySamples.settings, actions: .inert)
}
