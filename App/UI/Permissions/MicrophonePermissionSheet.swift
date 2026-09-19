import SwiftUI

/// Shown once, right before iOS asks for the microphone (on the first tap of the mic
/// button). "Continue" should trigger the system prompt; "Not now" returns to the screen.
struct MicrophonePermissionSheet: View {
    let onContinue: @MainActor () -> Void
    let onNotNow: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                OrbView(mode: .listening, inputLevel: 0.35)
                    .frame(width: 112, height: 112)
                    .padding(.top, Spacing.xxl)

                VStack(spacing: Spacing.s) {
                    Text("Voice Agent listens only when you ask")
                        .textStyle(.title2, weight: .bold)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Next, iOS asks for access to the microphone.")
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: Spacing.l + 2) {
                    PromiseRow(
                        systemImage: "hand.tap.fill",
                        title: "You turn it on",
                        detail: "The microphone opens when you tap it and closes when the conversation ends."
                    )
                    PromiseRow(
                        systemImage: "iphone",
                        title: "Understood on this iPhone",
                        detail: "Speech becomes text right here. There is no server."
                    )
                    PromiseRow(
                        systemImage: "icloud.slash",
                        title: "Never uploaded",
                        detail: "Your voice doesn\u{2019}t leave this iPhone."
                    )
                }
                .frame(maxWidth: Measure.text, alignment: .leading)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.bottom, Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .edgeBar(.bottom) {
            VStack(spacing: Spacing.xs) {
                Button(action: onContinue) { Text("Continue") }
                    .buttonStyle(.prominent)
                Button(action: onNotNow) { Text("Not now") }
                    .buttonStyle(.quiet)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.s)
        }
        .background(Palette.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// An icon, a short promise and one sentence of detail.
struct PromiseRow: View {
    let systemImage: String
    let title: String
    let detail: String
    var tone: Tone = .jade

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tone.color)
                .frame(width: 28, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.headline)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Microphone explainer") {
    Color.clear.sheet(isPresented: .constant(true)) {
        MicrophonePermissionSheet(onContinue: {}, onNotNow: {})
    }
}
