import Intelligence
import SwiftUI

/// The moment something would leave the phone.
///
/// It shows the payload itself, not a description of it: the words that would be sent, who they go
/// to, and why the job wants them. Saying no is the default position — dismissing this sheet is a
/// no, and nothing is sent on an ambiguity.
struct NetworkRequestSheet: View {
    let descriptor: NetworkRequestDescriptor
    let onAnswer: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(spacing: Spacing.m) {
                IconTile(systemImage: "globe", tone: .sky, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send this to \(descriptor.provider)?")
                        .textStyle(.title3)
                        .foregroundStyle(Palette.ink)
                    Text(descriptor.host)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("What would be sent")
                    .textStyle(.footnote, weight: .semibold)
                    .foregroundStyle(Palette.inkSecondary)
                    .textCase(.uppercase)
                Text(descriptor.payload)
                    .textStyle(.body, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.well, in: .rounded(Radius.medium))
                StatusPill(descriptor.categories.map(\.displayName).joined(separator: ", "),
                           systemImage: "tag", tone: .neutral)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Why")
                    .textStyle(.footnote, weight: .semibold)
                    .foregroundStyle(Palette.inkSecondary)
                    .textCase(.uppercase)
                Text(descriptor.reason)
                    .textStyle(.callout)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Nothing about your projects, people or documents is included unless you asked for it by name.")
                .textStyle(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: Spacing.s) {
                Button("Send it") { onAnswer(true) }
                    .buttonStyle(.capsule(.prominent, size: .large))
                Button("Don't send") { onAnswer(false) }
                    .buttonStyle(.capsule(.secondary, size: .large))
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: Measure.content)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Send this?") {
    NetworkRequestSheet(
        descriptor: NetworkRequestDescriptor(
            capability: "search_web", provider: "Wikipedia", host: "en.wikipedia.org",
            categories: [.searchTerms], reason: "Find what the midterm covers", payload: "eigenvalues"
        ),
        onAnswer: { _ in }
    )
}
