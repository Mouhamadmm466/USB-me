import Core
import Intelligence
import SwiftUI

/// Everywhere Settings can go. Also the deep-link vocabulary: a permission card that needs a
/// folder opens Settings at `.permissions`.
enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case memory, documents, projects, sources, permissions, internet, models, history, about
}

/// Everything that is not the conversation.
///
/// The app has one screen; this is the drawer behind it. It is organised by the question the
/// person is actually asking when they open it, in the order they ask it:
///
/// 1. **Your world** — what do you know about me, and where did you get it?
/// 2. **What I can reach** — what are you allowed to touch?
/// 3. **How I behave** — what do you do without asking?
/// 4. and the housekeeping: models, history, about.
///
/// Nothing is more than one push deep. A settings screen you have to explore is a settings screen
/// that hides things, and everything hidden here is something the user has a right to see.
struct SettingsScreen: View {
    let state: SettingsViewState
    let actions: SettingsActions
    /// The world model's own state, so its screens can live here rather than in tabs of their own.
    var world: IntelligenceViewState = .empty
    var worldIntents: IntelligenceIntents = .inert
    var initialSection: SettingsSection?

    @State private var path: [SettingsSection] = []

    init(
        state: SettingsViewState,
        actions: SettingsActions,
        world: IntelligenceViewState = .empty,
        worldIntents: IntelligenceIntents = .inert,
        initialSection: SettingsSection? = nil
    ) {
        self.state = state
        self.actions = actions
        self.world = world
        self.worldIntents = worldIntents
        self.initialSection = initialSection
        DesignSystemAppearance.install()
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                worldGroup
                reachGroup
                behaviourGroup
                systemGroup
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(Palette.groupedCanvas)
            .font(.dm(.body))
            .tint(Palette.clay)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: SettingsSection.self, destination: screen(for:))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: actions.done) {
                        Text("Done").textStyle(.body, weight: .semibold)
                    }
                }
            }
            .task {
                guard let initialSection else { return }
                path = [initialSection]
            }
        }
    }

    // MARK: The four questions

    private var worldGroup: some View {
        Section {
            SettingsLink(.memory, "What I know", systemImage: "brain.fill", tone: .clay,
                         value: world.memory.facts > 0 ? "\(world.memory.facts)" : nil)
            SettingsLink(.documents, "Documents", systemImage: "doc.fill", tone: .clay,
                         value: world.memory.documents.isEmpty ? nil : "\(world.memory.documents.count)")
            SettingsLink(.projects, "Projects", systemImage: "folder.fill", tone: .clay,
                         value: world.projects.isEmpty ? nil : "\(world.projects.count)")
        } header: {
            SettingsHeader("Your world")
        } footer: {
            SettingsFooter("Everything I hold about you, where each piece came from, and the way to take it back.")
        }
    }

    private var reachGroup: some View {
        Section {
            SettingsLink(.sources, "Calendar & reminders", systemImage: "calendar", tone: .neutral,
                         value: sourcesValue)
            SettingsLink(.permissions, "Permissions & folders", systemImage: "lock.fill", tone: .neutral,
                         value: permissionsValue)
            SettingsLink(.internet, "Internet", systemImage: "globe", tone: .neutral,
                         value: state.privacy.network.mode.displayName)
        } header: {
            SettingsHeader("What I can reach")
        } footer: {
            SettingsFooter("Off until you say otherwise. Whatever any of these is set to, your voice and your world stay on this iPhone.")
        }
    }

    private var behaviourGroup: some View {
        Section {
            Toggle(isOn: Binding(get: { world.memory.learningEnabled }, set: { worldIntents.setLearningEnabled($0) })) {
                RowLabel(title: "Learn from our conversations",
                         subtitle: "Off means I answer from what I already know and add nothing new.")
            }
            Toggle(isOn: Binding(get: { world.memory.confirmInferences }, set: { worldIntents.setConfirmInferences($0) })) {
                RowLabel(title: "Ask before keeping a guess",
                         subtitle: "Anything I work out rather than am told waits for your yes.")
            }
            Toggle(isOn: Binding(get: { state.voice.continueListening }, set: { actions.setContinueListening($0) })) {
                RowLabel(title: "Keep listening after replies",
                         subtitle: "Answer follow-up questions without tapping again.")
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
            SettingsHeader("How I behave")
        }
    }

    private var systemGroup: some View {
        Section {
            SettingsLink(.models, "Models & storage", systemImage: "arrow.down.circle.fill", tone: .neutral,
                         value: state.models.allInstalled ? Formatting.bytes(state.storage.modelBytes) : "Incomplete")
            SettingsLink(.history, "Conversation history", systemImage: "clock.arrow.circlepath", tone: .neutral,
                         value: state.privacy.keepHistory ? nil : "Off")
            SettingsLink(.about, "About", systemImage: "info.circle.fill", tone: .neutral,
                         value: state.about.version)
        }
    }

    private var sourcesValue: String? {
        switch (world.memory.ingestion.calendar, world.memory.ingestion.reminders) {
        case (false, false): "Off"
        case (true, true): "On"
        case (true, false): "Calendar"
        case (false, true): "Reminders"
        }
    }

    private var permissionsValue: String? {
        let waiting = state.permissions.count { $0.status != .granted && $0.status != .limited }
        return waiting == 0 ? nil : "\(waiting) to allow"
    }

    // MARK: Where each row goes

    @ViewBuilder
    private func screen(for section: SettingsSection) -> some View {
        switch section {
        case .memory:
            MemoryScreen(state: world, intents: worldIntents).navigationTitle("What I know")
        case .documents:
            DocumentsScreen(state: world, intents: worldIntents).navigationTitle("Documents")
        case .projects:
            ProjectsScreen(state: world, intents: worldIntents).navigationTitle("Projects")
        case .sources:
            SourcesScreen(state: world, intents: worldIntents, permissions: state.permissions,
                          onAllow: actions.requestPermission, onOpenSystemSettings: actions.openSystemSettings)
                .navigationTitle("Calendar & reminders")
        case .permissions:
            PermissionsScreen(state: state, actions: actions).navigationTitle("Permissions & folders")
        case .internet:
            InternetScreen(state: state, actions: actions).navigationTitle("Internet")
        case .models:
            ModelsScreen(state: state, actions: actions).navigationTitle("Models & storage")
        case .history:
            HistoryScreen(state: state, actions: actions).navigationTitle("Conversation history")
        case .about:
            AboutScreen(state: state, actions: actions).navigationTitle("About")
        }
    }
}

/// One row that goes somewhere. A tinted glyph, a name, what it is currently set to.
private struct SettingsLink: View {
    let section: SettingsSection
    let title: String
    let systemImage: String
    let tone: Tone
    let value: String?

    init(_ section: SettingsSection, _ title: String, systemImage: String, tone: Tone = .neutral, value: String? = nil) {
        self.section = section
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.value = value
    }

    var body: some View {
        NavigationLink(value: section) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tone == .neutral ? Palette.inkSecondary : tone.color)
                    .frame(width: 26)
                Text(title).textStyle(.body).foregroundStyle(Palette.ink)
                Spacer(minLength: Spacing.s)
                if let value {
                    Text(value)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
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
                    Rectangle().fill(Palette.clay).frame(width: max(3, proxy.size.width * models))
                    Rectangle().fill(Palette.mist.opacity(0.55)).frame(width: proxy.size.width * other)
                    Spacer(minLength: 0)
                }
                .background(Palette.fill)
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 10)
            HStack(spacing: Spacing.l) {
                legend("Voice models", color: Palette.clay)
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
                IconTile(systemImage: row.kind.systemImage, tone: row.status == .granted ? .clay : .neutral, size: 30)
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
            StatusPill("Allowed", systemImage: "checkmark", tone: .clay)
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

struct SharedFolderRow: View {
    let folder: SettingsViewState.SharedFolder
    let onRemove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            IconTile(systemImage: "folder.fill", tone: .clay, size: 30)
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

struct DiagnosticsControls: View {
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

struct MetricRow: View {
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
        case .good: .clay
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
