import Agent
import Core
import SwiftUI

/// Every screen and every assistant state with sample data (launch with `-DesignGallery`).
///
/// - Browse: an index grouped by area; tapping a row opens a full-screen pager (swipe between
///   entries; the close button sits at the bottom-left).
/// - Screenshots: `-DesignGallery -GalleryPage <id>` opens one entry directly, full screen,
///   with no gallery chrome. `-GalleryReduceMotion` renders with Reduce Motion on.
///   Ids are listed in the index (for example `assistant.waitingForConfirmation`).
struct DesignGalleryView: View {
    private let requestedPage = UserDefaults.standard.string(forKey: "GalleryPage")
    private let forcesReduceMotion = ProcessInfo.processInfo.arguments.contains("-GalleryReduceMotion")

    init() {
        DesignSystemAppearance.install()
    }

    var body: some View {
        Group {
            if let requestedPage, let item = GalleryCatalog.item(id: requestedPage) {
                GalleryItemHost(item: item)
            } else {
                GalleryIndex()
            }
        }
        .font(.dm(.body))
        .tint(Palette.clay)
        .transformEnvironment(\._accessibilityReduceMotion) { value in
            if forcesReduceMotion { value = true }
        }
    }
}

// MARK: - Catalog

struct GalleryItem: Identifiable {
    /// Also the `-GalleryPage` launch value.
    let id: String
    let section: String
    let title: String
    let make: @MainActor () -> AnyView
}

@MainActor
enum GalleryCatalog {
    static let sections = ["Assistant states", "Assistant scenarios", "Onboarding", "Settings", "Permissions", "Components"]

    static func item(id: String) -> GalleryItem? { items.first { $0.id == id } }

    static let items: [GalleryItem] = assistantStates + assistantScenarios + onboarding + settings + permissions + components

    private static var assistantStates: [GalleryItem] {
        AgentState.allCases.map { state in
            GalleryItem(id: "assistant.\(state.rawValue)", section: "Assistant states", title: state.displayLabel) {
                AnyView(GalleryAssistantPage(presentation: GallerySamples.presentation(for: state)))
            }
        }
    }

    private static var assistantScenarios: [GalleryItem] {
        [
            GalleryItem(id: "assistant.confirm-event", section: "Assistant scenarios", title: "Confirm a calendar event") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .waitingForConfirmation)
                    p.lastUserUtterance = "Add dentist on Friday at 3 at Harbor Dental"
                    p.assistantText = "Add \u{201C}Dentist\u{201D} on Friday, September 25 from 3 PM to 4 PM at Harbor Dental. Should I add it?"
                    p.actionCard = GallerySamples.eventCard(now: Date())
                    return p
                }()))
            },
            GalleryItem(id: "assistant.confirm-call", section: "Assistant scenarios", title: "Confirm a call, about to expire") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .waitingForConfirmation)
                    p.lastUserUtterance = "Call Mom at home"
                    p.assistantText = "Should I call Mom on home?"
                    p.actionCard = GallerySamples.callCard(now: Date())
                    return p
                }()))
            },
            GalleryItem(id: "assistant.confirm-long", section: "Assistant scenarios", title: "Confirm a long message") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .waitingForConfirmation)
                    p.lastUserUtterance = "Text Priya that I\u{2019}m running twenty minutes behind"
                    p.assistantText = "Text Priya Raghunathan-Okonkwo. Should I send it?"
                    p.actionCard = GallerySamples.longMessageCard(now: Date())
                    return p
                }()))
            },
            GalleryItem(id: "assistant.confirm-reminder", section: "Assistant scenarios", title: "Confirm a reminder") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .waitingForConfirmation)
                    p.lastUserUtterance = "Remind me to pick up the dry cleaning tomorrow at 6"
                    p.assistantText = "Remind you to \u{201C}Pick up the dry cleaning\u{201D} tomorrow at 6 PM. Should I create it?"
                    p.actionCard = GallerySamples.reminderCard(now: Date())
                    return p
                }()))
            },
            GalleryItem(id: "assistant.permission-asking", section: "Assistant scenarios", title: "Permission, iOS about to ask") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .permissionRequired)
                    p.lastUserUtterance = "What\u{2019}s on my calendar tomorrow?"
                    p.assistantText = nil
                    p.permissionPrompt = GallerySamples.permissionPrompts[1]
                    return p
                }()))
            },
            GalleryItem(id: "assistant.permission-folder", section: "Assistant scenarios", title: "No shared folder yet") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .permissionRequired)
                    p.lastUserUtterance = "Open my lease agreement"
                    p.assistantText = "Choose a folder to share with me first. You can do that in Settings, under Files."
                    p.permissionPrompt = GallerySamples.permissionPrompts[2]
                    return p
                }()))
            },
            GalleryItem(id: "assistant.banner-cancelled", section: "Assistant scenarios", title: "Cancelled result") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .idle)
                    p.lastUserUtterance = "No, don\u{2019}t send it"
                    p.assistantText = "Okay, the message wasn\u{2019}t sent."
                    p.resultBanner = GallerySamples.cancelledBanner
                    return p
                }()))
            },
            GalleryItem(id: "assistant.banner-failure", section: "Assistant scenarios", title: "Failed result") {
                AnyView(GalleryAssistantPage(presentation: {
                    var p = GallerySamples.presentation(for: .idle)
                    p.lastUserUtterance = "Yes"
                    p.assistantText = "That request expired, so I didn\u{2019}t do it. Please ask again."
                    p.resultBanner = GallerySamples.failureBanner
                    return p
                }()))
            },
            GalleryItem(id: "assistant.keyboard", section: "Assistant scenarios", title: "Typing a request") {
                AnyView(GalleryAssistantPage(presentation: GallerySamples.presentation(for: .idle), inputMode: .keyboard))
            },
            GalleryItem(id: "assistant.history", section: "Assistant scenarios", title: "History sheet") {
                AnyView(HistorySheet(turns: GallerySamples.presentation(for: .idle).turns))
            },
        ]
    }

    private static var onboarding: [GalleryItem] {
        let page: (String, String, OnboardingPage, ModelDownloadViewState) -> GalleryItem = { id, title, start, models in
            GalleryItem(id: id, section: "Onboarding", title: title) {
                AnyView(OnboardingFlow(models: models, actions: .inert, initialPage: start))
            }
        }
        return [
            page("onboarding.privacy", "Private by design", .privacy, GallerySamples.downloadsNotStarted),
            page("onboarding.models", "Download: not started", .models, GallerySamples.downloadsNotStarted),
            page("onboarding.models-progress", "Download: in progress", .models, GallerySamples.downloadsInProgress),
            page("onboarding.models-paused", "Download: paused on cellular", .models, GallerySamples.downloadsPaused),
            page("onboarding.models-problems", "Download: problems, offline", .models, GallerySamples.downloadsProblems),
            page("onboarding.models-nospace", "Download: not enough space", .models, GallerySamples.downloadsNoSpace),
            page("onboarding.models-done", "Download: finished", .models, GallerySamples.downloadsInstalled),
            page("onboarding.ready", "Ready", .ready, GallerySamples.downloadsInstalled),
        ]
    }

    private static var settings: [GalleryItem] {
        [
            GalleryItem(id: "settings", section: "Settings", title: "Settings") {
                AnyView(SettingsScreen(state: GallerySamples.settings, actions: .inert))
            },
            GalleryItem(id: "settings.busy", section: "Settings", title: "Downloading, benchmark running") {
                AnyView(SettingsScreen(state: GallerySamples.settingsBusy, actions: .inert))
            },
            GalleryItem(id: "settings.permissions", section: "Settings", title: "Scrolled to permissions") {
                AnyView(SettingsScreen(state: GallerySamples.settings, actions: .inert, initialSection: .permissions))
            },
            GalleryItem(id: "settings.diagnostics", section: "Settings", title: "Scrolled to diagnostics") {
                AnyView(SettingsScreen(state: GallerySamples.settings, actions: .inert, initialSection: .about))
            },
            GalleryItem(id: "settings.licenses", section: "Settings", title: "Third-party licenses") {
                AnyView(NavigationStack { LicensesView(licenses: SettingsViewState.License.bundled) })
            },
        ]
    }

    private static var permissions: [GalleryItem] {
        [
            GalleryItem(id: "permissions.microphone", section: "Permissions", title: "Microphone explainer sheet") {
                AnyView(
                    GalleryAssistantPage(presentation: GallerySamples.presentation(for: .idle))
                        .sheet(isPresented: .constant(true)) {
                            MicrophonePermissionSheet(onContinue: {}, onNotNow: {})
                        }
                )
            },
            GalleryItem(id: "permissions.cards", section: "Permissions", title: "Permission cards") {
                AnyView(GallerySpecimen(title: "Permission cards") {
                    ForEach(GallerySamples.permissionPrompts, id: \.kind) { prompt in
                        PermissionCardView(prompt: prompt, onOpenSystemSettings: {}, onChooseFolder: {}, onDismiss: {})
                    }
                })
            },
        ]
    }

    private static var components: [GalleryItem] {
        [
            GalleryItem(id: "components.orb", section: "Components", title: "Orb modes") {
                AnyView(OrbSpecimen())
            },
            GalleryItem(id: "components.action-cards", section: "Components", title: "Action cards") {
                AnyView(GallerySpecimen(title: "Action cards") {
                    let now = Date()
                    ForEach([GallerySamples.messageCard(now: now), GallerySamples.eventCard(now: now), GallerySamples.callCard(now: now),
                             GallerySamples.reminderCard(now: now), GallerySamples.longMessageCard(now: now)]) { card in
                        ActionCardView(card: card, onConfirm: {}, onCancel: {})
                    }
                })
            },
            GalleryItem(id: "components.controls", section: "Components", title: "Controls") {
                AnyView(ControlsSpecimen())
            },
            GalleryItem(id: "components.type", section: "Components", title: "Type scale") {
                AnyView(TypeSpecimen())
            },
            GalleryItem(id: "components.downloads", section: "Components", title: "Model rows, every state") {
                AnyView(GallerySpecimen(title: "Model rows") {
                    ModelDownloadsView(state: GallerySamples.downloadsInProgress, actions: .inert, style: .card)
                    ModelDownloadsView(state: GallerySamples.downloadsPaused, actions: .inert, style: .card)
                    ModelDownloadsView(state: GallerySamples.downloadsProblems, actions: .inert, style: .card)
                    ModelDownloadsView(state: GallerySamples.downloadsInstalled, actions: .inert, style: .card)
                })
            },
        ]
    }
}

// MARK: - Browsing

private struct GalleryIndex: View {
    @State private var presented: PresentedPage?

    struct PresentedPage: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Every screen and state, with sample data. Tap an entry, then swipe to move through them.")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.xs, bottom: 0, trailing: Spacing.xs))
                }
                ForEach(GalleryCatalog.sections, id: \.self) { section in
                    Section {
                        ForEach(GalleryCatalog.items.filter { $0.section == section }) { item in
                            Button {
                                presented = PresentedPage(index: GalleryCatalog.items.firstIndex { $0.id == item.id } ?? 0)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).textStyle(.body).foregroundStyle(Palette.ink)
                                        Text(item.id).textStyle(.caption).foregroundStyle(Palette.inkTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Palette.inkTertiary)
                                }
                            }
                        }
                    } header: {
                        SettingsHeader(section)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Design gallery")
        }
        .fullScreenCover(item: $presented) { page in
            GalleryPager(start: page.index)
        }
    }
}

private struct GalleryPager: View {
    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(start: Int) {
        _selection = State(initialValue: start)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(GalleryCatalog.items.enumerated()), id: \.element.id) { index, item in
                GalleryItemHost(item: item)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Gallery", systemImage: "square.grid.2x2")
                        .textStyle(.caption, weight: .semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassSurface(Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(selection + 1) / \(GalleryCatalog.items.count)  \(GalleryCatalog.items[selection].title)")
                    .textStyle(.caption, weight: .medium)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, 2)
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Renders one entry exactly as it would appear in the app. The entry is built once, so its
/// sample dates (expiry countdowns) don't reset when the pager re-renders.
private struct GalleryItemHost: View {
    @State private var content: AnyView

    init(item: GalleryItem) {
        _content = State(initialValue: item.make())
    }

    var body: some View {
        content
    }
}

// MARK: - Assistant page with simulated audio

/// The assistant screen, with speech-like audio levels while listening or speaking so the
/// orb can be judged in motion.
private struct GalleryAssistantPage: View {
    let presentation: AssistantPresentation
    var inputMode: AssistantInputMode = .voice

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = presentation.state.orbMode
        if !reduceMotion, mode == .listening || mode == .speaking {
            TimelineView(.periodic(from: .now, by: 1.0 / 24)) { context in
                screen(with: SimulatedVoice.level(at: context.date.timeIntervalSinceReferenceDate, speaking: mode == .speaking))
            }
        } else {
            screen(with: nil)
        }
    }

    private func screen(with level: Float?) -> some View {
        var p = presentation
        if let level {
            if p.state.orbMode == .speaking { p.outputLevel = level } else { p.inputLevel = level }
        }
        return AssistantScreen(presentation: p, intents: .inert, inputMode: inputMode, bannerDuration: .seconds(600))
    }
}

/// A plausible syllabic envelope: bursts at ~4 Hz inside phrases, with pauses.
enum SimulatedVoice {
    static func level(at time: TimeInterval, speaking: Bool) -> Float {
        let phrase = max(0, sin(time * (speaking ? 0.9 : 0.7)) + 0.35)
        let syllables = 0.5 + 0.5 * sin(time * 2 * .pi * 3.7) * sin(time * 2 * .pi * 1.3 + 0.8)
        let jitter = 0.08 * sin(time * 41) * sin(time * 17)
        let value = min(1, max(0, phrase * (0.25 + 0.75 * syllables) * (speaking ? 0.7 : 0.9) + jitter))
        return Float(value)
    }
}

// MARK: - Specimens

private struct GallerySpecimen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(title)
                    .textStyle(.largeTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.l)
                content
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.bottom, Spacing.huge)
        }
        .background(Palette.canvas)
    }
}

private struct OrbSpecimen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GallerySpecimen(title: "Orb") {
            Text("One indicator, ten modes. Colour is the assistant\u{2019}s state; motion is its activity.")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
            TimelineView(.periodic(from: .now, by: 1.0 / 24)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.l), GridItem(.flexible(), spacing: Spacing.l)], spacing: Spacing.xl) {
                    ForEach(OrbMode.allCases) { mode in
                        VStack(spacing: Spacing.s) {
                            OrbView(
                                mode: mode,
                                inputLevel: reduceMotion ? 0.5 : SimulatedVoice.level(at: t, speaking: false),
                                outputLevel: reduceMotion ? 0.5 : SimulatedVoice.level(at: t + 1.3, speaking: true)
                            )
                            .frame(width: 132, height: 132)
                            Text(title(for: mode))
                                .textStyle(.subheadline, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Text(states(for: mode))
                                .textStyle(.caption)
                                .foregroundStyle(Palette.inkSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func title(for mode: OrbMode) -> String {
        switch mode {
        case .preparing: "Preparing"
        case .idle: "Ready"
        case .listening: "Listening"
        case .understanding: "Understanding"
        case .speaking: "Speaking"
        case .confirming: "Confirmation"
        case .clarifying: "Question"
        case .executing: "Executing"
        case .blocked: "Permission"
        case .failed: "Error"
        }
    }

    private func states(for mode: OrbMode) -> String {
        AgentState.allCases.filter { $0.orbMode == mode }.map(\.rawValue).joined(separator: ", ")
    }
}

private struct ControlsSpecimen: View {
    var body: some View {
        GallerySpecimen(title: "Controls") {
            group("Buttons") {
                Button {} label: { Text("Send") }.buttonStyle(.prominent)
                Button {} label: { Text("Cancel") }.buttonStyle(.secondary)
                Button {} label: { Text("Delete model") }.buttonStyle(.destructive)
                Button {} label: { Text("Unavailable") }.buttonStyle(.prominent).disabled(true)
                HStack {
                    Button {} label: { Text("Retry") }.buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    Button {} label: { Text("Allow") }.buttonStyle(.capsule(.tinted(Palette.clay), size: .small, fullWidth: false))
                    Button {} label: { Text("Not now") }.buttonStyle(.quiet)
                }
                HStack(spacing: Spacing.l) {
                    Button {} label: { Image(systemName: "keyboard") }.buttonStyle(.glassCircle(diameter: 50))
                    MicButton(isActive: false) {}
                    MicButton(isActive: true) {}
                    MicButton(isActive: true, tint: Palette.amber) {}
                    Button {} label: { Image(systemName: "gearshape") }.buttonStyle(.glassCircle(diameter: 42))
                }
            }
            group("Status") {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    PrivacyPill()
                    StatusPill("Installed", systemImage: "checkmark.seal.fill", tone: .clay)
                    StatusPill("Waiting", systemImage: "hand.raised.fill", tone: .amber)
                    StatusPill("Question", systemImage: "questionmark", tone: .sky)
                    StatusPill("Failed", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                    StatusPill("Paused", tone: .neutral)
                    StatusPill("Outline", tone: .clay, emphasis: .outline)
                }
                ProgressBar(value: 0.42)
                ProgressBar(value: 0.7, tint: Palette.mist)
                HStack(spacing: Spacing.m) {
                    ForEach(Tone.allCases, id: \.self) { tone in
                        IconTile(systemImage: "sparkle", tone: tone)
                    }
                }
            }
            group("Banners") {
                ResultBannerView(banner: GallerySamples.successBanner)
                ResultBannerView(banner: GallerySamples.cancelledBanner)
                ResultBannerView(banner: GallerySamples.failureBanner)
            }
            group("Choices") {
                ClarificationChoicesView(choices: GallerySamples.alexChoices + [
                    ClarificationChoice(id: "more", title: "Alexandra Petrova-Lindqvist", subtitle: "home"),
                ], onChoose: { _ in })
            }
            group("Card") {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Card").textStyle(.headline)
                        Text("A quiet surface with a hairline edge and continuous corners.")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title).textStyle(.title3).foregroundStyle(Palette.ink)
            content()
        }
    }
}

private struct TypeSpecimen: View {
    var body: some View {
        GallerySpecimen(title: "Type") {
            Text("DM Sans, every style anchored to a Dynamic Type text style.")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
            ForEach(TypeStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(String(describing: style)), \(Int(style.size)) pt")
                        .textStyle(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                    Text("Text Alex I\u{2019}ll be late")
                        .textStyle(style)
                        .foregroundStyle(Palette.ink)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("weights").textStyle(.caption).foregroundStyle(Palette.inkTertiary)
                ForEach(DMSans.allCases, id: \.self) { weight in
                    Text(weight.rawValue).textStyle(.title3, weight: weight).foregroundStyle(Palette.ink)
                }
            }
        }
    }
}

#Preview("Gallery") {
    DesignGalleryView()
}
