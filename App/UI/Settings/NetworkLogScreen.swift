import Intelligence
import SwiftUI

/// Everything that tried to leave the phone, including what was refused.
///
/// A log of successes only could not be used to check that a refusal actually refused, so every
/// attempt is here, with the exact payload rather than a description of it. This screen is the
/// receipt for the promise the rest of the app makes.
struct NetworkLogScreen: View {
    let network: SettingsViewState.Network
    let onClear: @MainActor () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: Spacing.m) {
                    IconTile(systemImage: network.sent == 0 ? "lock.shield.fill" : "globe",
                             tone: network.sent == 0 ? .jade : .sky, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.sent == 0 ? "Nothing has left this iPhone" : "\(network.sent) requests have left")
                            .textStyle(.headline)
                        Text(summary)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .combine)
            }

            if network.log.isEmpty {
                Section {
                    Text("When something needs the internet, it will be listed here — what was sent, to whom, and why — whether it went or not.")
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    ForEach(network.log) { row in
                        NetworkLogRow(row: row)
                    }
                } header: {
                    SettingsHeader("Every request")
                }

                Section {
                    Button(role: .destructive) { isConfirmingClear = true } label: {
                        Text("Clear this record…")
                            .textStyle(.body, weight: .medium)
                            .foregroundStyle(Palette.danger)
                    }
                } footer: {
                    Text("Clearing removes the record, not anything that was already sent.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .font(.dm(.body))
        .navigationTitle("What left this iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear this record?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive, action: onClear)
        } message: {
            Text("The list is erased. What was already sent cannot be taken back.")
        }
    }

    private var summary: String {
        if network.sent == 0, network.refused == 0 {
            return "Nothing has needed the internet yet."
        }
        var parts: [String] = []
        if network.sent > 0 { parts.append("\(network.bytesText) in total") }
        if network.refused > 0 {
            parts.append(network.refused == 1 ? "1 request was refused" : "\(network.refused) requests were refused")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NetworkLogRow: View {
    let row: SettingsViewState.Network.LogRow

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            IconTile(systemImage: icon, tone: tone, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.payload)
                    .textStyle(.body, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(row.categories) → \(row.provider)")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                if let detail = row.detail {
                    Text(detail)
                        .textStyle(.footnote)
                        .foregroundStyle(tone == .danger ? Palette.danger : Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.xs) {
                    Text(row.outcome.displayName)
                        .foregroundStyle(tone.textColor)
                    Text("·")
                    Text(row.timeText)
                    if !row.reason.isEmpty {
                        Text("·")
                        Text(row.reason).lineLimit(1)
                    }
                }
                .textStyle(.caption)
                .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch row.outcome {
        case .sent: "arrow.up.forward"
        case .refused: "hand.raised"
        case .declined: "xmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tone: Tone {
        switch row.outcome {
        case .sent: .sky
        case .refused, .declined: .neutral
        case .failed: .danger
        }
    }
}

#Preview("What left") {
    NavigationStack {
        NetworkLogScreen(
            network: SettingsViewState.Network(
                mode: .ask, sent: 2, refused: 1, bytesText: "14 KB",
                log: [
                    .init(id: UUID(), provider: "Wikipedia", payload: "eigenvalues",
                          categories: "search terms", reason: "Look up what the midterm covers",
                          outcome: .sent, detail: nil, timeText: "2 min ago"),
                    .init(id: UUID(), provider: "Wikipedia", payload: "Beta launch checklist",
                          categories: "search terms", reason: "Find a checklist",
                          outcome: .refused,
                          detail: "That would have sent something about you that you didn't ask to send.",
                          timeText: "yesterday"),
                ]
            ),
            onClear: {}
        )
    }
}
