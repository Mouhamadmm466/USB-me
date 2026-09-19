import Agent
import Core
import SwiftUI

/// The visible safety surface for a consequential action (PRD §19): every field exactly as it
/// will run, an expiry countdown, and Confirm / Cancel. Voice confirmation stays available;
/// the card says so.
struct ActionCardView: View {
    let card: ActionCard
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpired = false
    @State private var confirmTaps = 0
    @State private var cancelTaps = 0

    var body: some View {
        Card(tone: .amber) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                Hairline()
                VStack(alignment: .leading, spacing: Spacing.m + 2) {
                    ForEach(Array(card.fields.enumerated()), id: \.offset) { _, field in
                        ActionFieldRow(field: field)
                    }
                }
                if let footnote = card.footnote {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                            .accessibilityHidden(true)
                        Text(footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                }
                buttons
                    .padding(.top, Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.title), waiting for your confirmation")
        .task(id: card.expiresAt) { await watchExpiry() }
        .haptic(.impact(weight: .medium), trigger: confirmTaps)
        .haptic(.impact(weight: .light), trigger: cancelTaps)
    }

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        return layout {
            IconTile(systemImage: card.systemImage, tone: .amber, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .textStyle(.headline)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(isExpired ? "This request expired. Ask again." : "Say \u{201C}yes\u{201D} or tap \(card.confirmLabel).")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            ExpiryCountdown(expiresAt: card.expiresAt)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let confirm = Button {
            confirmTaps += 1
            onConfirm()
        } label: {
            Text(card.confirmLabel)
        }
        .buttonStyle(.capsule(.prominent))
        .disabled(isExpired)
        .accessibilityHint("Confirms: \(card.title).")

        let cancel = Button {
            cancelTaps += 1
            onCancel()
        } label: {
            Text("Cancel")
        }
        .buttonStyle(.capsule(.secondary))
        .accessibilityHint("Nothing will be done.")

        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Spacing.s + 2) {
                confirm
                cancel
            }
        } else {
            HStack(spacing: Spacing.s + 2) {
                cancel
                confirm
            }
        }
    }

    private func watchExpiry() async {
        isExpired = card.expiresAt <= .now
        let delay = card.expiresAt.timeIntervalSinceNow
        guard delay > 0 else { return }
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        isExpired = true
    }
}

/// One label/value pair. Values are selectable and never truncated; long-form values (the
/// message body) sit in their own well.
private struct ActionFieldRow: View {
    let field: ActionCard.Field

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 74

    private var isLongForm: Bool {
        field.label == "Message" || field.value.count > 34 || field.value.contains("\n")
    }

    var body: some View {
        Group {
            if isLongForm {
                VStack(alignment: .leading, spacing: 6) {
                    label
                    value
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.well, in: .rounded(Radius.medium))
                        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    label
                    value
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    label.frame(width: labelWidth, alignment: .leading)
                    value
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(field.label)
            .textStyle(.subheadline)
            .foregroundStyle(Palette.inkSecondary)
    }

    private var value: some View {
        Text(field.value)
            .textStyle(.body)
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "0:42" ticking down to "Expired".
struct ExpiryCountdown: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            let expired = remaining <= 0
            let urgent = remaining < 10
            HStack(spacing: 4) {
                Image(systemName: expired ? "xmark.circle" : "timer")
                    .imageScale(.small)
                Text(expired ? "Expired" : Formatting.countdown(remaining))
                    .monospacedDigit()
            }
            .textStyle(.footnote, weight: .semibold)
            .foregroundStyle(expired || urgent ? Palette.danger : Palette.amberText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(expired || urgent ? Tone.danger.fill : Tone.amber.fill))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(expired ? "Expired" : "Expires in \(Formatting.spokenDuration(remaining))")
        }
    }
}

#Preview("Action card") {
    ScrollView {
        VStack(spacing: 20) {
            ActionCardView(card: GallerySamples.messageCard, onConfirm: {}, onCancel: {})
            ActionCardView(card: GallerySamples.eventCard, onConfirm: {}, onCancel: {})
        }
        .padding(20)
    }
}
