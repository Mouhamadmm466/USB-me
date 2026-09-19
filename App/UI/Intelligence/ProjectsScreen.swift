import Intelligence
import SwiftUI

/// Projects: the containers everything else hangs off.
///
/// A project card answers the two questions a person actually has — what is next, and who else is
/// involved — without opening anything.
struct ProjectsScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.m) {
                if state.projects.isEmpty, state.isLoaded {
                    EmptyStateCard(
                        systemImage: "folder",
                        title: "No projects yet",
                        message: "Mention something you're working on and it becomes a project here, with its goals, people and deadlines.",
                        actionTitle: "Talk to it",
                        action: intents.ask
                    )
                }
                ForEach(state.projects) { project in
                    Button { intents.openEntity(project.id) } label: {
                        ProjectCard(project: project)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: Measure.content, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        .refreshable { await intents.refresh() }
    }
}

struct ProjectCard: View {
    let project: IntelligenceViewState.ProjectRow

    var body: some View {
        Card(padding: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    IconTile(systemImage: "folder", tone: project.tone, size: 36)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(project.title)
                            .textStyle(.headline)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if project.status != "active" {
                            Text(project.status)
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .textStyle(.footnote, weight: .semibold)
                        .foregroundStyle(Palette.inkTertiary)
                }

                if let nextDue = project.nextDue, let title = project.nextDueTitle {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: project.isLate ? "exclamationmark.circle.fill" : "arrow.right.circle.fill")
                            .foregroundStyle(project.isLate ? Palette.danger : project.tone.color)
                            .imageScale(.small)
                        Text("\(title) — \(nextDue)")
                            .textStyle(.subheadline)
                            .foregroundStyle(project.isLate ? Palette.danger : Palette.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.well, in: .rounded(Radius.medium))
                }

                HStack(spacing: Spacing.s) {
                    if project.openWork > 0 {
                        StatusPill("\(project.openWork) open", systemImage: "checkmark.circle", tone: .neutral)
                    }
                    if project.commitments > 0 {
                        StatusPill(
                            project.commitments == 1 ? "1 promise" : "\(project.commitments) promises",
                            systemImage: "hand.raised", tone: .amber
                        )
                    }
                    if !project.people.isEmpty {
                        StatusPill(project.people.prefix(2).joined(separator: ", "), systemImage: "person", tone: .sky)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Projects") {
    ProjectsScreen(state: .preview, intents: .inert)
}
