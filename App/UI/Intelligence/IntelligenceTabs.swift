import Agent
import Core
import Intelligence
import SwiftUI

/// The five places the app can be.
enum AppTab: String, Hashable, CaseIterable {
    case home, projects, ask, intelligence, activity

    var title: String {
        switch self {
        case .home: "Home"
        case .projects: "Projects"
        case .ask: "Ask"
        case .intelligence: "Memory"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .projects: "folder"
        case .ask: "waveform"
        case .intelligence: "brain"
        case .activity: "clock"
        }
    }
}

/// The V2 shell.
///
/// Ask stays exactly what it was in V1 — the orb, one screen, nothing between the user and
/// speaking. The other four tabs are the same intelligence read four ways: what today needs, what
/// the work is, what is known, what happened. Every one of them is a view of the same local store,
/// so nothing here can disagree with what the assistant says out loud.
struct IntelligenceTabs: View {
    @Binding var selection: AppTab
    let state: IntelligenceViewState
    let intents: IntelligenceIntents
    let assistant: AssistantScreenProvider
    /// Pushed detail, driven by `intents.openEntity`.
    @Binding var path: [UUID]
    let detail: @MainActor (UUID) -> EntityDetailViewState
    let detailIntents: EntityDetailIntents

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
                // Home writes its own headline from today's counts, so a navigation title would
                // just repeat the word above it.
                navigation { HomeScreen(state: state, intents: intents).toolbar(.hidden, for: .navigationBar) }
            }
            Tab(AppTab.projects.title, systemImage: AppTab.projects.systemImage, value: AppTab.projects) {
                navigation { ProjectsScreen(state: state, intents: intents).navigationTitle("Projects") }
            }
            Tab(AppTab.ask.title, systemImage: AppTab.ask.systemImage, value: AppTab.ask) {
                assistant.screen()
            }
            Tab(AppTab.intelligence.title, systemImage: AppTab.intelligence.systemImage, value: AppTab.intelligence) {
                navigation { MemoryScreen(state: state, intents: intents).navigationTitle("What I know") }
            }
            Tab(AppTab.activity.title, systemImage: AppTab.activity.systemImage, value: AppTab.activity) {
                navigation { ActivityScreen(state: state, intents: intents).navigationTitle("Activity") }
            }
        }
        .tint(Palette.jade)
    }

    /// Every tab shares one detail stack, so opening "Sarah" from Home, Projects or Activity lands
    /// in the same place and the back button means what it says.
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: UUID.self) { id in
                    EntityDetailScreen(state: detail(id), intents: detailIntents)
                }
        }
    }
}

/// Lets the shell present the assistant screen without knowing how it is built.
struct AssistantScreenProvider {
    var screen: @MainActor () -> AnyView

    init(screen: @escaping @MainActor () -> some View) {
        self.screen = { AnyView(screen()) }
    }
}

#Preview("Tabs") {
    struct Harness: View {
        @State private var tab = AppTab.home
        @State private var path: [UUID] = []

        var body: some View {
            IntelligenceTabs(
                selection: $tab,
                state: .preview,
                intents: .inert,
                assistant: AssistantScreenProvider {
                    AssistantScreen(presentation: AssistantPresentation(state: .idle), intents: .inert)
                },
                path: $path,
                detail: { id in EntityDetailViewState(id: id, title: "Beta launch", kind: .project, status: "active") },
                detailIntents: .inert
            )
        }
    }
    return Harness()
}
