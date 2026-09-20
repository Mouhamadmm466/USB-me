import Intelligence
import SwiftUI

/// My Intelligence: everything the system holds about you, and the controls over it.
///
/// This screen exists because a personal intelligence you cannot inspect is just a database someone
/// else owns. Search it, see what it is made of, switch learning off, export it, delete it — all of
/// it local, all of it reversible except the deletion, which says so.
struct MemoryScreen: View {
    let state: IntelligenceViewState
    let intents: IntelligenceIntents

    @State private var searchText = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                if !state.memory.results.isEmpty || !searchText.isEmpty {
                    results
                } else {
                    summary
                    if !state.questions.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            Text("Waiting on you")
                                .textStyle(.title3)
                                .foregroundStyle(Palette.ink)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(state.questions) { question in
                                QuestionCard(question: question, intents: intents)
                            }
                        }
                    }
                    controls
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: Measure.content, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        .searchable(text: $searchText, prompt: "Search what I know")
        .onChange(of: searchText) { _, text in intents.search(text) }
        .refreshable { await intents.refresh() }
        .confirmationDialog(
            "Delete everything I know?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { intents.deleteEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every project, person, deadline and note is removed from this iPhone. This cannot be undone.")
        }
    }

    // MARK: Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Card(padding: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text.tabular("\(state.memory.facts)")
                            .textStyle(.largeTitle)
                            .foregroundStyle(Palette.ink)
                        Text(state.memory.facts == 1 ? "thing I know" : "things I know")
                            .textStyle(.callout)
                            .foregroundStyle(Palette.inkSecondary)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Spacing.s) {
                        StatusPill("On this iPhone", systemImage: "iphone", tone: .clay)
                        StatusPill(state.memory.sizeText, systemImage: "internaldrive", tone: .neutral)
                        if state.memory.inferred > 0 {
                            StatusPill("\(state.memory.inferred) worked out", systemImage: "wand.and.stars", tone: .sky)
                        }
                    }
                }
            }

            if !state.memory.kinds.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(state.memory.kinds.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline().padding(.leading, 56) }
                        HStack(spacing: Spacing.m) {
                            IconTile(systemImage: row.kind.systemImage, tone: .neutral, size: 32)
                            Text(row.kind.plural)
                                .textStyle(.body)
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            Text.tabular("\(row.count)")
                                .textStyle(.body, weight: .medium)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Palette.surface, in: .rounded(Radius.large))
                .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5))
            }
        }
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if state.memory.results.isEmpty {
                EmptyStateCard(
                    systemImage: "magnifyingglass",
                    title: "Nothing matches",
                    message: "I only know what you've told me and what you've shared with me."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.memory.results.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline().padding(.leading, 56) }
                        Button { intents.openEntity(item.id) } label: { ItemRow(item: item) }
                            .buttonStyle(RowButtonStyle())
                    }
                }
                .background(Palette.surface, in: .rounded(Radius.large))
                .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Controls")
                .textStyle(.title3)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)

            Card(padding: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Toggle(isOn: Binding(
                        get: { state.memory.learningEnabled },
                        set: { intents.setLearningEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Learn from our conversations")
                                .textStyle(.body, weight: .medium)
                                .foregroundStyle(Palette.ink)
                            Text("Off means I answer from what I already know and add nothing new.")
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Palette.clay)

                    Hairline()

                    Toggle(isOn: Binding(
                        get: { state.memory.confirmInferences },
                        set: { intents.setConfirmInferences($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask before keeping a guess")
                                .textStyle(.body, weight: .medium)
                                .foregroundStyle(Palette.ink)
                            Text("Anything I worked out rather than was told waits for your yes.")
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Palette.clay)
                    .disabled(!state.memory.learningEnabled)
                }
            }

            Card(padding: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Button { intents.exportEverything() } label: {
                        Label("Export everything", systemImage: "square.and.arrow.up")
                            .textStyle(.body, weight: .medium)
                    }
                    .buttonStyle(.capsule(.secondary, size: .medium))

                    Button(role: .destructive) { isConfirmingDelete = true } label: {
                        Label("Delete everything", systemImage: "trash")
                            .textStyle(.body, weight: .medium)
                    }
                    .buttonStyle(.capsule(.destructive, size: .medium))

                    Text("Nothing here has ever left this iPhone.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }
}

#Preview("My Intelligence") {
    NavigationStack { MemoryScreen(state: .preview, intents: .inert) }
}
