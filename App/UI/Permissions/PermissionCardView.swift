import Agent
import Core
import SwiftUI

/// Explains a missing permission in place, with the one action that fixes it.
///
/// - `requiresSettings`: iOS will not ask again, so the card offers **Open Settings**.
/// - `.fileScope`: folders are chosen inside the app, so the card offers **Choose folder**.
/// - Otherwise the iOS prompt is on its way; the card only explains why.
struct PermissionCardView: View {
    let prompt: PermissionPrompt
    let onOpenSystemSettings: @MainActor () -> Void
    let onChooseFolder: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    IconTile(systemImage: prompt.kind.systemImage, tone: .neutral, size: 40)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(prompt.title)
                            .textStyle(.headline)
                            .foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(prompt.message)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let hint {
                            Text(hint)
                                .textStyle(.footnote, weight: .medium)
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(.top, Spacing.xs)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                actions
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var hint: String? {
        if prompt.requiresSettings && prompt.kind != .fileScope {
            return "In Settings, turn on \(prompt.kind.displayName)."
        }
        if prompt.kind == .fileScope { return nil }
        return "iOS will ask you next."
    }

    @ViewBuilder
    private var actions: some View {
        let primary: (title: String, action: @MainActor () -> Void)? =
            if prompt.kind == .fileScope {
                ("Choose folder", onChooseFolder)
            } else if prompt.requiresSettings {
                ("Open Settings", onOpenSystemSettings)
            } else {
                nil
            }

        let notNow = Button(action: onDismiss) { Text("Not now") }
            .buttonStyle(.capsule(.secondary, size: .medium))

        if let primary {
            let main = Button(action: primary.action) { Text(primary.title) }
                .buttonStyle(.capsule(.prominent, size: .medium))
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: Spacing.s) {
                    main
                    notNow
                }
            } else {
                HStack(spacing: Spacing.s + 2) {
                    notNow
                    main
                }
            }
        } else {
            notNow
        }
    }
}

#Preview("Permission cards") {
    ScrollView {
        VStack(spacing: 20) {
            ForEach(GallerySamples.permissionPrompts, id: \.kind) { prompt in
                PermissionCardView(prompt: prompt, onOpenSystemSettings: {}, onChooseFolder: {}, onDismiss: {})
            }
        }
        .padding(20)
    }
}
