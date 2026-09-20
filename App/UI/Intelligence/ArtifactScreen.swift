import Intelligence
import SwiftUI

/// Something the assistant wrote, as the user reads it.
///
/// Rendered from the stored Markdown rather than from a model call, so opening it twice shows the
/// same document — and the version and sources are stated, because a document whose provenance is
/// invisible is a document you cannot trust.
struct ArtifactScreen: View {
    let artifact: Artifact
    let sources: [String]
    let onShare: @MainActor () -> Void
    let onForget: @MainActor () -> Void

    @State private var isConfirmingForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                ForEach(Array(Self.blocks(of: artifact.markdown).enumerated()), id: \.offset) { _, block in
                    block.view
                }
                footer
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: Measure.text, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                    Button("Forget this", systemImage: "trash", role: .destructive) { isConfirmingForget = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Forget \(artifact.title)?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive, action: onForget)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document and its earlier versions are removed from this iPhone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                StatusPill(artifact.kind.displayName, systemImage: "doc.text", tone: .sky)
                if artifact.version > 1 {
                    StatusPill("version \(artifact.version)", tone: .neutral)
                }
                StatusPill("\(artifact.wordCount) words", tone: .neutral)
            }
        }
        .padding(.top, Spacing.s)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Hairline()
            if sources.isEmpty {
                Text("Written from what you've told me.")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                Text("Built from: " + sources.joined(separator: ", "))
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Spacing.m)
    }

    // MARK: Markdown

    /// The small subset of Markdown the writer produces: headings, paragraphs, list items and a
    /// rule. Rendering it directly keeps the document readable without pulling in a parser.
    struct Block {
        enum Kind { case title, heading, paragraph, item, rule }
        var kind: Kind
        var text: String

        @MainActor @ViewBuilder
        var view: some View {
            switch kind {
            case .title:
                Text(text)
                    .textStyle(.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            case .heading:
                Text(text)
                    .textStyle(.title3)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.s)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph:
                Text(Self.inline(text))
                    .textStyle(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            case .item:
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("•").foregroundStyle(Palette.inkTertiary)
                    Text(Self.inline(text))
                        .textStyle(.body)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .rule:
                Hairline().padding(.vertical, Spacing.s)
            }
        }

        /// Emphasis and bold, left as attributed text; anything else stays literal.
        static func inline(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text)) ?? AttributedString(text)
        }
    }

    static func blocks(of markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            if !text.isEmpty { blocks.append(Block(kind: .paragraph, text: text)) }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("# ") {
                flush()
                blocks.append(Block(kind: .title, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("## ") {
                flush()
                blocks.append(Block(kind: .heading, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(Block(kind: .item, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("---") {
                flush()
                blocks.append(Block(kind: .rule, text: ""))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

#Preview("Artifact") {
    NavigationStack {
        ArtifactScreen(
            artifact: Artifact(
                title: "Midterm study plan",
                kind: .plan,
                markdown: """
                # Midterm study plan

                ## The goal

                Be ready for eigenvalues and diagonalization by the fourth Friday.

                ## Steps

                - Two hours a day, starting with the practice set.
                - Re-read the diagonalization notes on Wednesday.

                ## Watch out for

                Don't leave the practice set to the last night.

                ## Sources

                - Syllabus

                ---

                Written on this iPhone, September 19, 2026.
                """,
                version: 2
            ),
            sources: ["Syllabus"],
            onShare: {}, onForget: {}
        )
    }
}
