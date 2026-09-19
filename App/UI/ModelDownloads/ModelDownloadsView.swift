import SwiftUI

/// The reusable list of model packs: sizes, progress, and per-pack actions (download, pause,
/// resume, retry, verify, re-download, delete). Delete and re-download ask first.
///
/// `.list` emits one row per pack, for a `List`/`Form` section (Settings).
/// `.card` stacks the rows in a card with hairline separators (onboarding).
struct ModelDownloadsView: View {
    enum Style { case list, card }

    let state: ModelDownloadViewState
    let actions: ModelDownloadActions
    var style: Style = .list

    var body: some View {
        switch style {
        case .list:
            ForEach(state.packs) { pack in
                ModelPackRow(pack: pack, actions: actions)
                    .padding(.vertical, Spacing.xs)
            }
        case .card:
            Card(padding: 0, radius: Radius.card) {
                VStack(spacing: 0) {
                    ForEach(Array(state.packs.enumerated()), id: \.element.id) { index, pack in
                        // The onboarding page has one "Download" action for every pack.
                        ModelPackRow(pack: pack, actions: actions, showsDownloadButton: false)
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, Spacing.l - 2)
                        if index < state.packs.count - 1 {
                            Hairline().padding(.leading, Spacing.l + 48)
                        }
                    }
                }
            }
        }
    }
}

/// One pack: icon, name, model, size or progress, and the action that fits its state.
struct ModelPackRow: View {
    typealias Pack = ModelDownloadViewState.Pack

    let pack: Pack
    let actions: ModelDownloadActions
    /// Offer "Download" on a pack that is not installed (off where the screen has its own
    /// download-all action).
    var showsDownloadButton = true

    @State private var confirmsDelete = false
    @State private var confirmsRedownload = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            IconTile(systemImage: pack.systemImage, tone: iconTone, size: 36)
            VStack(alignment: .leading, spacing: Spacing.s) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.s))
                layout {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pack.name)
                            .textStyle(.headline)
                            .foregroundStyle(Palette.ink)
                        Text(pack.detail)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(accessibilityStatus)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                    trailingAction
                }
                statusArea
            }
        }
        .confirmationDialog("Delete \(pack.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { actions.delete(pack.id) }
        } message: {
            Text("Voice Agent can\u{2019}t work without it until it\u{2019}s downloaded again (\(Formatting.bytes(pack.totalBytes))).")
        }
        .confirmationDialog("Re-download \(pack.name)?", isPresented: $confirmsRedownload, titleVisibility: .visible) {
            Button("Re-download \(Formatting.bytes(pack.totalBytes))") { actions.redownload(pack.id) }
        } message: {
            Text("The current copy is removed and downloaded again. Use Wi-Fi if you can.")
        }
    }

    private var iconTone: Tone {
        switch pack.state {
        case .installed: .jade
        case .failed, .corrupt: .danger
        default: .neutral
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusArea: some View {
        switch pack.state {
        case .notInstalled:
            statusText(Formatting.bytes(pack.totalBytes))
        case .queued:
            statusText("Up next, \(Formatting.bytes(pack.totalBytes))")
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(value: progress)
                HStack {
                    statusText("\(Formatting.bytes(Int64(Double(pack.totalBytes) * progress), of: pack.totalBytes))")
                    Spacer(minLength: Spacing.s)
                    statusText(timeLeft ?? Formatting.percent(progress))
                }
            }
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(value: pack.fraction, tint: Palette.mist)
                statusText("Paused at \(Formatting.bytes(pack.downloadedBytes, of: pack.totalBytes))")
            }
        case let .verifying(progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(value: progress, tint: Palette.jade.opacity(0.55))
                statusText("Checking files\u{2026} \(Formatting.percent(progress))")
            }
        case .installed:
            HStack(spacing: Spacing.s) {
                StatusPill("Installed", systemImage: "checkmark.seal.fill", tone: .jade)
                statusText(Formatting.bytes(pack.totalBytes))
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                problemText(message)
                Button { actions.retry(pack.id) } label: { Text("Try again") }
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    .accessibilityLabel("Try downloading \(pack.name) again")
            }
        case .corrupt:
            VStack(alignment: .leading, spacing: Spacing.s) {
                problemText("Files are damaged or missing. Re-download to repair.")
                Button { confirmsRedownload = true } label: { Text("Re-download") }
                    .buttonStyle(.capsule(.destructive, size: .small, fullWidth: false))
                    .accessibilityLabel("Re-download \(pack.name)")
            }
        }
    }

    private var timeLeft: String? {
        guard let rate = pack.bytesPerSecond, case let .downloading(progress) = pack.state else { return nil }
        let remaining = Int64(Double(pack.totalBytes) * (1 - progress))
        return Formatting.timeRemaining(bytes: remaining, bytesPerSecond: rate)
    }

    private func statusText(_ text: String) -> some View {
        Text.tabular(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.inkSecondary)
    }

    private func problemText(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.footnote, weight: .medium)
        .foregroundStyle(Palette.danger)
    }

    private var accessibilityStatus: String {
        switch pack.state {
        case .notInstalled: "Not downloaded, \(Formatting.bytes(pack.totalBytes))"
        case .queued: "Waiting to download"
        case let .downloading(progress): "Downloading, \(Formatting.percent(progress))"
        case .paused: "Paused, \(Formatting.percent(pack.fraction))"
        case let .verifying(progress): "Checking files, \(Formatting.percent(progress))"
        case .installed: "Installed, \(Formatting.bytes(pack.totalBytes))"
        case let .failed(message): "Failed. \(message)"
        case .corrupt: "Damaged. Re-download to repair."
        }
    }

    // MARK: Action

    @ViewBuilder
    private var trailingAction: some View {
        switch pack.state {
        case .notInstalled:
            if showsDownloadButton {
                Button { actions.download(pack.id) } label: { Text("Download") }
                    .buttonStyle(.capsule(.secondary, size: .small, fullWidth: false))
                    .accessibilityLabel("Download \(pack.name)")
            }
        case .downloading:
            roundAction("pause.fill", label: "Pause downloads") { actions.pauseAll() }
        case .paused:
            roundAction("play.fill", label: "Resume downloads") { actions.resumeAll() }
        case .installed:
            Menu {
                Button { actions.verify(pack.id) } label: {
                    Label("Verify files", systemImage: "checkmark.shield")
                }
                Button { confirmsRedownload = true } label: {
                    Label("Re-download\u{2026}", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) { confirmsDelete = true } label: {
                    Label("Delete\u{2026}", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.fill))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Actions for \(pack.name)")
        case .queued, .verifying, .failed, .corrupt:
            EmptyView()
        }
    }

    private func roundAction(_ systemImage: String, label: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Network and free-space hints for a large download.
struct ModelDownloadHints: View {
    let state: ModelDownloadViewState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let network = networkHint {
                hint(network.text, systemImage: network.image, tone: network.tone)
            }
            if let free = state.freeSpaceBytes {
                if state.hasEnoughSpace {
                    hint("\(Formatting.bytes(free)) available on this iPhone", systemImage: "internaldrive", tone: .neutral)
                } else {
                    hint(
                        "Needs \(Formatting.bytes(state.remainingBytes)); \(Formatting.bytes(free)) available. Free up space to continue.",
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }
            }
        }
    }

    private var networkHint: (text: String, image: String, tone: Tone)? {
        guard !state.allInstalled else { return nil }
        switch state.network {
        case .wifi: return ("Connected to Wi-Fi", "wifi", .neutral)
        case .cellular: return ("You\u{2019}re on cellular. This download is \(Formatting.bytes(state.remainingBytes)); Wi-Fi is better.", "cellularbars", .amber)
        case .offline: return ("No internet connection. Connect to download.", "wifi.slash", .danger)
        case .unknown: return nil
        }
    }

    private func hint(_ text: String, systemImage: String, tone: Tone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.footnote, weight: .medium)
        .foregroundStyle(tone.textColor)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Downloads — card") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ModelDownloadsView(state: GallerySamples.downloadsInProgress, actions: .inert, style: .card)
            ModelDownloadHints(state: GallerySamples.downloadsInProgress)
            ModelDownloadsView(state: GallerySamples.downloadsProblems, actions: .inert, style: .card)
        }
        .padding(20)
    }
}

#Preview("Downloads — list") {
    List {
        Section("Models") {
            ModelDownloadsView(state: GallerySamples.downloadsInstalled, actions: .inert)
        }
    }
}
