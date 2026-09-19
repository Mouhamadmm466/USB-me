import Intelligence
import SwiftUI

/// Activity: everything the system did, in order, with undo.
///
/// The point of the screen is accountability rather than history. Each row says what changed, why
/// it is held, and — where it applies — offers to take it back. An undone row stays, struck through,
/// because hiding it would be its own kind of silent change.
struct ActivityScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents

    @State private var filter: ActivityKind?

    private var rows: [IntelligenceViewState.ActivityRow] {
        guard let filter else { return state.activity }
        return state.activity.filter { $0.kind == filter }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.m) {
                if state.activity.isEmpty, state.isLoaded {
                    EmptyStateCard(
                        systemImage: "clock",
                        title: "Nothing has happened yet",
                        message: "When I learn something or do something for you, it shows up here — with a way to undo it."
                    )
                } else {
                    filters
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Hairline().padding(.leading, 56) }
                            ActivityRowView(row: row, undo: intents.undo, open: intents.openEntity)
                        }
                    }
                    .background(Palette.surface, in: .rounded(Radius.large))
                    .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 0.5))
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

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                FilterChip(title: "All", isSelected: filter == nil) { filter = nil }
                ForEach(availableKinds, id: \.self) { kind in
                    FilterChip(title: kind.displayName, isSelected: filter == kind) {
                        filter = filter == kind ? nil : kind
                    }
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -Spacing.screenMargin)
    }

    private var availableKinds: [ActivityKind] {
        ActivityKind.allCases.filter { kind in state.activity.contains { $0.kind == kind } }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .textStyle(.footnote, weight: .semibold)
                .foregroundStyle(isSelected ? Palette.inkInverse : Palette.ink)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? Palette.ink : Palette.fill)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct ActivityRowView: View {
    let row: IntelligenceViewState.ActivityRow
    let undo: @MainActor (UUID) -> Void
    let open: @MainActor (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            IconTile(systemImage: row.kind.systemImage, tone: row.isUndone ? .neutral : row.kind.tone, size: 32)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(row.headline)
                    .textStyle(.body, weight: .medium)
                    .foregroundStyle(row.isUndone ? Palette.inkTertiary : Palette.ink)
                    .strikethrough(row.isUndone, color: Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Spacing.xs) {
                    Text(row.kind.displayName)
                        .foregroundStyle(row.kind.tone.textColor)
                    Text("·")
                    Text(row.timeText)
                    if let detail = row.detail, !row.isUndone {
                        Text("·")
                        Text(detail).lineLimit(1)
                    }
                    if row.isUndone {
                        Text("·")
                        Text("undone")
                    }
                }
                .textStyle(.footnote)
                .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: Spacing.s)
            if row.canUndo {
                Button("Undo") { undo(row.id) }
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .contentShape(.rect)
        .onTapGesture { if let entityID = row.entityID { open(entityID) } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo") { if row.canUndo { undo(row.id) } }
    }
}

#Preview("Activity") {
    ActivityScreen(state: .preview, intents: .inert)
}
