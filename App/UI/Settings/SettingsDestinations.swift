import Core
import Intelligence
import SwiftUI

/// The screens behind the rows in Settings. Each one answers a single question, which is why they
/// are separate screens rather than sections of one long list: "what can you reach" and "how much
/// space are you using" have nothing to say to each other.

// MARK: - Calendar & reminders

/// The sources the world model is allowed to read, and the permissions they need.
///
/// The switch and the permission are deliberately on the same screen. They are two halves of one
/// decision, and an app that asks for calendar access in one place and offers to read the calendar
/// in another is asking twice for the same thing.
struct SourcesScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents
    let permissions: [SettingsViewState.PermissionRow]
    let onAllow: (PermissionKind) -> Void
    let onOpenSystemSettings: (PermissionKind) -> Void

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { state.memory.ingestion.calendar },
                    set: { intents.setCalendarIngestion($0) }
                )) {
                    RowLabel(title: "Your calendar",
                             subtitle: "What\u{2019}s on, when, and who\u{2019}s in it — so I can answer without asking you first.")
                }
                if let row = permissions.first(where: { $0.kind == .calendar }), state.memory.ingestion.calendar {
                    PermissionStatusRow(row: row,
                                        onAllow: { onAllow(.calendar) },
                                        onOpenSettings: { onOpenSystemSettings(.calendar) })
                }

                Toggle(isOn: Binding(
                    get: { state.memory.ingestion.reminders },
                    set: { intents.setReminderIngestion($0) }
                )) {
                    RowLabel(title: "Your reminders",
                             subtitle: "What you\u{2019}ve told yourself to do, and what you\u{2019}ve already done.")
                }
                if let row = permissions.first(where: { $0.kind == .reminders }), state.memory.ingestion.reminders {
                    PermissionStatusRow(row: row,
                                        onAllow: { onAllow(.reminders) },
                                        onOpenSettings: { onOpenSystemSettings(.reminders) })
                }
            } header: {
                SettingsHeader("Let me read")
            } footer: {
                SettingsFooter("Anything from these is marked as coming from them, never outranks what you tell me, and goes when you switch it off.")
            }

            if let summary = state.memory.ingestion.summary {
                Section {
                    HStack(spacing: Spacing.s) {
                        if state.memory.ingestion.isSyncing { ProgressView().controlSize(.mini) }
                        Text(summary)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    SettingsHeader("Right now")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}

// MARK: - Documents

/// What the person has handed over, and the two ways to hand over more.
struct DocumentsScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents

    var body: some View {
        List {
            Section {
                Button(action: intents.addDocument) {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.clay)
                            .frame(width: 26)
                        Text("Add from Files").textStyle(.body).foregroundStyle(Palette.ink)
                    }
                }
                .disabled(state.memory.isImporting)
                if state.memory.isImporting {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.mini)
                        Text("Reading it\u{2026}").textStyle(.subheadline).foregroundStyle(Palette.inkSecondary)
                    }
                }
                if let error = state.memory.importError {
                    Text(error)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                SettingsFooter("Or share a PDF, a Word file, a page or a note to Voice Agent from any app — I\u{2019}ll read it the next time you open me, and answer from it, quoting the page it came from.")
            }

            if state.memory.documents.isEmpty {
                Section {
                    Text("Nothing yet.")
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkTertiary)
                }
            } else {
                Section {
                    ForEach(state.memory.documents) { document in
                        Button { intents.openEntity(document.id) } label: {
                            HStack(spacing: Spacing.m) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Palette.inkSecondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(document.title).textStyle(.body).foregroundStyle(Palette.ink)
                                    Text(document.meta).textStyle(.footnote).foregroundStyle(Palette.inkSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Forget", role: .destructive) { intents.forgetDocument(document.id) }
                        }
                    }
                } header: {
                    SettingsHeader("What I\u{2019}ve read")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}

// MARK: - Permissions & folders

struct PermissionsScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions

    var body: some View {
        List {
            Section {
                ForEach(state.permissions) { row in
                    PermissionStatusRow(
                        row: row,
                        onAllow: { actions.requestPermission(row.kind) },
                        onOpenSettings: { actions.openSystemSettings(row.kind) }
                    )
                }
            } footer: {
                SettingsFooter("Voice Agent asks for each permission the first time a request needs it.")
            }

            Section {
                ForEach(state.sharedFolders) { folder in
                    SharedFolderRow(folder: folder, onRemove: { actions.removeFolder(folder.id) })
                }
                Button(action: actions.chooseFolder) {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 16, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.clay)
                            .frame(width: 26)
                        Text(state.sharedFolders.isEmpty ? "Choose folder\u{2026}" : "Choose another folder\u{2026}")
                            .textStyle(.body)
                            .foregroundStyle(Palette.ink)
                    }
                }
                .accessibilityHint("Opens Files so you can choose a folder Voice Agent may search.")
            } header: {
                SettingsHeader("Folders")
            } footer: {
                SettingsFooter(state.sharedFolders.isEmpty
                    ? "Voice Agent can\u{2019}t see any of your files. Choose a folder to let it search and open the files inside."
                    : "Voice Agent can search and open files only in these folders.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}

// MARK: - Internet

/// The only door out of the phone, and the record of everything that went through it.
struct InternetScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions

    var body: some View {
        List {
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
                .pickerStyle(.inline)
            } footer: {
                SettingsFooter("Everything else — your voice, your world, your documents — is processed here and never sent, whatever this is set to.")
            }

            Section {
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}

// MARK: - Models & storage

struct ModelsScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions

    var body: some View {
        List {
            Section {
                ModelDownloadsView(state: state.models, actions: actions.models)
                if let bulk = bulkAction {
                    Button(action: bulk.action) {
                        Label(bulk.title, systemImage: bulk.image)
                            .textStyle(.body, weight: .medium)
                            .foregroundStyle(Palette.ink)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if !state.models.allInstalled {
                        ModelDownloadHints(state: state.models)
                    }
                    SettingsFooter("The models run only on this iPhone. Each file is checked against a pinned checksum before it\u{2019}s used.")
                }
            }

            Section {
                if let capacity = state.storage.capacityBytes, let free = state.storage.freeBytes {
                    StorageBar(modelBytes: state.storage.modelBytes, freeBytes: free, capacityBytes: capacity)
                        .padding(.vertical, Spacing.s)
                }
                ValueRow(title: "Voice models", value: Formatting.bytes(state.storage.modelBytes), swatch: Palette.clay)
                if let history = state.storage.historyBytes {
                    ValueRow(title: "Conversation history", value: Formatting.bytes(history))
                }
                if let free = state.storage.freeBytes {
                    ValueRow(title: "Available on iPhone", value: Formatting.bytes(free))
                }
            } header: {
                SettingsHeader("Storage")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }

    private var bulkAction: (title: String, image: String, action: @MainActor () -> Void)? {
        let models = state.models
        if models.allInstalled { return nil }
        if models.isInProgress { return ("Pause downloads", "pause.circle", actions.models.pauseAll) }
        if models.isPaused { return ("Resume downloads", "arrow.down.circle", actions.models.resumeAll) }
        return ("Download all (\(Formatting.bytes(models.remainingBytes)))", "arrow.down.circle", actions.models.downloadAll)
    }
}

// MARK: - Conversation history

struct HistoryScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions

    @State private var confirmsClear = false

    var body: some View {
        List {
            Section {
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
            } footer: {
                SettingsFooter("History is what lets me answer \u{201C}what did I just ask you?\u{201D}. It never leaves this iPhone either way.")
            }

            Section {
                Button(role: .destructive) { confirmsClear = true } label: {
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
                .confirmationDialog("Clear all history?", isPresented: $confirmsClear, titleVisibility: .visible) {
                    Button("Clear history", role: .destructive, action: actions.clearHistory)
                } message: {
                    Text("Every saved conversation is removed from this iPhone. This can\u{2019}t be undone.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
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
}

// MARK: - About

struct AboutScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Palette.clay)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing leaves this iPhone").textStyle(.headline)
                        Text("Your voice, requests and history are processed and stored only here. There\u{2019}s no account and no server.")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .combine)
            }

            Section {
                ValueRow(title: "Version", value: "\(state.about.version) (\(state.about.build))")
                NavigationLink {
                    LicensesView(licenses: state.about.licenses)
                } label: {
                    Text("Third-party licenses").textStyle(.body)
                }
            } footer: {
                SettingsFooter("Speech recognition, the language model and the voice all run on this iPhone.")
            }

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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}
