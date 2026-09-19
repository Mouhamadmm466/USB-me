import Agent
import SwiftUI

/// Candidates offered when a request is ambiguous ("Alex Kim" / "Alex Chen"). Tapping one is
/// the same as saying it.
struct ClarificationChoicesView: View {
    let choices: [ClarificationChoice]
    let onChoose: @MainActor (String) -> Void

    @State private var lastChoice: String?

    var body: some View {
        VStack(spacing: Spacing.m) {
            FlowLayout(spacing: 10, lineSpacing: 10, alignment: .center) {
                ForEach(choices) { choice in
                    Button {
                        lastChoice = choice.id
                        onChoose(choice.id)
                    } label: {
                        ChoiceChipLabel(choice: choice)
                    }
                    .buttonStyle(ChoiceChipStyle())
                    .accessibilityLabel([choice.title, choice.subtitle].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint("Chooses this option.")
                }
            }
            Text("Tap one, or say it.")
                .textStyle(.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .haptic(.selection, trigger: lastChoice)
    }
}

private struct ChoiceChipLabel: View {
    let choice: ClarificationChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(choice.title)
                .textStyle(.callout, weight: .semibold)
                .foregroundStyle(Palette.ink)
            if let subtitle = choice.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChoiceChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChoiceChipBody(configuration: configuration)
    }
}

private struct ChoiceChipBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        configuration.label
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 11)
            .frame(minHeight: 48)
            .background(shape.fill(configuration.isPressed ? Tone.sky.fill : Palette.surface))
            .overlay(shape.strokeBorder(Palette.sky.opacity(0.45), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

#Preview("Clarification") {
    ClarificationChoicesView(choices: GallerySamples.alexChoices, onChoose: { _ in })
        .padding()
}
