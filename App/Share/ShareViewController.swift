import ShareInbox
import SwiftUI
import UniformTypeIdentifiers

/// The share sheet's view of Voice Agent.
///
/// It does as little as an extension can: it names what it is about to keep, waits for the user to
/// say yes, copies the bytes into the app's own container, and gets out of the way. No parsing, no
/// network, no model — the app does all of that later, where a failure is visible and a long read
/// is not fatal. An extension that tries to be clever is an extension the system kills.
final class ShareViewController: UIViewController {
    private var attachments: [NSItemProvider] = []
    private var isKeeping = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let attachments = attachments
        let host = UIHostingController(
            rootView: SharePrompt(
                summary: Self.describe(attachments),
                // The name usually arrives a moment later than the sheet does, so the card starts
                // honest ("this page") and gets specific rather than waiting to say anything.
                resolve: { [weak self] in await self?.name(of: attachments) },
                keep: { [weak self] in self?.keep() },
                cancel: { [weak self] in self?.cancel() }
            )
        )
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: Doing it

    private func keep() {
        // Copying takes a moment on a big file, and the sheet stays up until it is done. Two taps
        // must not become two copies.
        guard !isKeeping else { return }
        guard let inbox = ShareInbox() else { return finish(with: ShareInboxError.unavailable) }
        isKeeping = true
        let attachments = attachments
        Task { @MainActor in
            do {
                var kept = 0
                for provider in attachments where try await self.take(provider, into: inbox) { kept += 1 }
                guard kept > 0 else {
                    self.isKeeping = false
                    return self.finish(with: ShareInboxError.unreadable)
                }
                self.extensionContext?.completeRequest(returningItems: nil)
            } catch {
                self.isKeeping = false
                self.finish(with: error)
            }
        }
    }

    /// One attachment. File first: a file URL also answers to `public.url`, and keeping a PDF as the
    /// string "file:///…" would be a note about a document rather than the document.
    private func take(_ provider: NSItemProvider, into inbox: ShareInbox) async throws -> Bool {
        if let type = Self.fileType(of: provider) {
            try await keepFile(provider, type: type, into: inbox)
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await loadURL(provider) {
            // Kept as an address. Reading the page is a network request, and those go through the
            // policy the user set — not through a share sheet.
            try inbox.accept(text: url.absoluteString, kind: .link,
                             title: url.host() ?? url.absoluteString)
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await loadText(provider), !text.isEmpty {
            try inbox.accept(text: text, kind: .text, title: Self.title(of: text))
            return true
        }
        return false
    }

    private func keepFile(_ provider: NSItemProvider, type: UTType, into inbox: ShareInbox) async throws {
        let name = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The URL is only valid inside this callback, so the copy happens here.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareInboxError.unreadable)
                    return
                }
                do {
                    try inbox.accept(
                        fileAt: url,
                        title: name ?? url.deletingPathExtension().lastPathComponent,
                        mediaType: type.preferredMIMEType
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: text) }
            }
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func finish(with error: Error) {
        let message = (error as? ShareInboxError)?.description ?? "I couldn't keep that one."
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.cancel() })
        present(alert, animated: true)
    }

    // MARK: Reading the attachments

    /// The type to ask for when an attachment is a file. `public.url` is excluded deliberately: a
    /// web address is not a file, even though a file URL is a URL.
    private static func fileType(of provider: NSItemProvider) -> UTType? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return .fileURL }
        let carried = provider.registeredTypeIdentifiers.compactMap(UTType.init(_:))
        let preferred: [UTType] = [.pdf, .rtf, .plainText, .image]
        if let match = preferred.first(where: { type in carried.contains { $0.conforms(to: type) } }) {
            return carried.first { $0.conforms(to: match) }
        }
        // Word files and anything else that carries its own bytes.
        return carried.first { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }
    }

    /// A better name than the sheet could give synchronously: the address of a page, the first line
    /// of a note. Nil when there is nothing better to say.
    private func name(of attachments: [NSItemProvider]) async -> String? {
        guard attachments.count == 1, let only = attachments.first, only.suggestedName == nil else {
            return nil
        }
        if only.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !only.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await loadURL(only) {
            return url.host() ?? url.absoluteString
        }
        if only.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await loadText(only), !text.isEmpty {
            return Self.title(of: text)
        }
        return nil
    }

    private static func describe(_ attachments: [NSItemProvider]) -> String {
        guard let first = attachments.first else { return "this" }
        if let name = first.suggestedName, !name.isEmpty {
            return attachments.count > 1 ? "\(name) and \(attachments.count - 1) more" : name
        }
        if first.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !first.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return "this page"
        }
        return attachments.count > 1 ? "these \(attachments.count) things" : "this"
    }

    /// A note's name is its first line, trimmed to something that fits on one.
    private static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Note"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…"
    }
}

/// What the user sees: what will be kept, where it goes, and that it goes nowhere else.
///
/// One question, two answers, no options. Everything that could be configured here — which project
/// it belongs to, whether to read it now — is a better question to ask inside the app, where the
/// user can see what they already have.
private struct SharePrompt: View {
    let summary: String
    let resolve: () async -> String?
    let keep: () -> Void
    let cancel: () -> Void

    @State private var named: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Self.jade.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Self.jade)
                }
                .padding(.bottom, 4)

                Text("Keep this?")
                    .font(Self.font("DMSans-Bold", 30))
                    .multilineTextAlignment(.center)

                Text(named ?? summary)
                    .font(Self.font("DMSans-Medium", 18))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .animation(.easeOut(duration: 0.2), value: named)

                Text("I'll read it when you next open me, and answer from it — quoting the page it came from. It stays on this iPhone.")
                    .font(Self.font("DMSans-Regular", 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Button(action: cancel) {
                        Text("Not now")
                            .font(Self.font("DMSans-SemiBold", 17))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .background(Color(.secondarySystemFill), in: .capsule)

                    Button(action: keep) {
                        Text("Keep it")
                            .font(Self.font("DMSans-SemiBold", 17))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .background(Color(.label), in: .capsule)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task { named = await resolve() }
    }

    /// The app's typeface, with the system's as the fallback: a share sheet that renders in the
    /// wrong font is worse than one that renders in the right default.
    private static func font(_ name: String, _ size: CGFloat) -> Font {
        UIFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: .semibold)
    }

    /// The app's own green, both ways round. The extension cannot reach the design system — that
    /// lives in the app target — so the two values are repeated here rather than approximated.
    private static let jade = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x3F / 255, green: 0xD1 / 255, blue: 0xAE / 255, alpha: 1)
            : UIColor(red: 0x0B / 255, green: 0x7F / 255, blue: 0x68 / 255, alpha: 1)
    })
}
