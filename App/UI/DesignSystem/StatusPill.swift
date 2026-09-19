import SwiftUI

/// A compact capsule that names a status ("On-device", "Installed", "Paused").
struct StatusPill: View {
    let title: String
    var systemImage: String?
    var tone: Tone = .neutral
    var emphasis: Emphasis = .soft

    enum Emphasis {
        /// Tinted background, coloured text.
        case soft
        /// Outline only, for use on busy or translucent backgrounds.
        case outline
    }

    init(_ title: String, systemImage: String? = nil, tone: Tone = .neutral, emphasis: Emphasis = .soft) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.emphasis = emphasis
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            Text(title)
                .lineLimit(1)
        }
        .textStyle(.footnote, weight: .semibold)
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            switch emphasis {
            case .soft:
                Capsule(style: .continuous).fill(tone.fill)
            case .outline:
                Capsule(style: .continuous).strokeBorder(tone.color.opacity(0.45), lineWidth: 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
