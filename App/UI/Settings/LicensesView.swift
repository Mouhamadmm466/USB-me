import SwiftUI

/// Third-party software and models, with their licenses.
struct LicensesView: View {
    let licenses: [SettingsViewState.License]

    var body: some View {
        List {
            Section {
                ForEach(licenses) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.name)
                                .textStyle(.body, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: Spacing.s)
                            if let url = entry.url {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Palette.inkSecondary)
                                        .frame(width: 30, height: 30)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Open the \(entry.name) project page")
                            }
                        }
                        Text(entry.role)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                        Text(entry.license)
                            .textStyle(.footnote, weight: .medium)
                            .foregroundStyle(Palette.jade)
                        if let notice = entry.notice {
                            Text(notice)
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                SettingsFooter("Voice Agent is built on these open projects and models. Thank you to their authors.")
            }
        }
        .listStyle(.insetGrouped)
        .font(.dm(.body))
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Licenses") {
    NavigationStack { LicensesView(licenses: SettingsViewState.License.bundled) }
}
