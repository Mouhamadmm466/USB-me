import Foundation

/// The handoff between the share extension and the app: a directory in the App Group container
/// where the extension leaves things and the app collects them.
///
/// Three decisions worth stating, because they are what keep a share sheet from becoming a second
/// place your documents live:
///
/// 1. **The extension parses nothing.** It copies bytes and writes a manifest. Share extensions run
///    under a hard memory limit and are killed without ceremony when they exceed it; a PDF parser is
///    exactly the wrong thing to run there. The app does the reading, where a failure is visible and
///    recoverable.
/// 2. **The inbox is a queue, not a library.** Everything in it is on its way somewhere. The app
///    deletes each item the moment it has read it, so the group container never accumulates a second
///    copy of the user's documents.
/// 3. **Nothing leaves the device, and nothing is opened on the way.** A link is kept as an address;
///    fetching it is a network request, and network requests go through the policy the user set.
public struct ShareInbox: Sendable {
    /// Both targets must carry this in their entitlements; it is the only thing they share.
    public static let defaultGroupID = "group.com.mouhamadmamane.voiceagent"

    /// Bigger than a long report, smaller than anything that would push an extension over its
    /// memory limit while being copied.
    public static let maximumBytes = 32_000_000
    /// Enough that a burst of sharing works, few enough that a forgotten inbox cannot grow without
    /// bound while the app goes unopened.
    public static let maximumPending = 32

    private let directory: URL

    /// `FileManager` is not `Sendable`, and the shared instance is documented as safe for exactly
    /// these calls, so the inbox reaches for it rather than holding one.
    private var files: FileManager { .default }

    /// Fails when the App Group is not available — the app has never run, or the entitlement is
    /// missing. Both are the user's cue to open the app once.
    public init?(groupID: String = ShareInbox.defaultGroupID) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        self.init(directory: container.appending(path: "Inbox", directoryHint: .isDirectory))
    }

    /// Directly on a directory. Used by the tests, which have no App Group.
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Writing (the extension's side)

    /// Takes a file in by copying its bytes, then writing the manifest. That order matters: a
    /// manifest is the app's signal that an item is complete, so it is written last and an
    /// interrupted share leaves an orphan payload rather than a promise of one.
    @discardableResult
    public func accept(
        fileAt url: URL, title: String, mediaType: String?, now: Date = Date()
    ) throws -> SharedItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumBytes else { throw ShareInboxError.tooLarge(limitBytes: Self.maximumBytes) }
        try prepare()

        let id = UUID()
        let payload = "\(id.uuidString).\(Self.extensionOf(url))"
        do {
            try files.copyItem(at: url, to: directory.appending(path: payload))
        } catch {
            throw ShareInboxError.unreadable
        }
        let item = SharedItem(
            id: id, kind: .document, title: title, payloadName: payload,
            mediaType: mediaType, byteCount: size, receivedAt: now
        )
        try writeManifest(item)
        return item
    }

    /// Takes text or a link in. Both become a payload file of their own so the app has one way to
    /// read an item rather than two.
    @discardableResult
    public func accept(
        text: String, kind: SharedItem.Kind, title: String, now: Date = Date()
    ) throws -> SharedItem {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumBytes else {
            throw ShareInboxError.tooLarge(limitBytes: Self.maximumBytes)
        }
        try prepare()

        let id = UUID()
        let payload = "\(id.uuidString).txt"
        do {
            try data.write(to: directory.appending(path: payload), options: [.atomic, .completeFileProtection])
        } catch {
            throw ShareInboxError.unreadable
        }
        let item = SharedItem(
            id: id, kind: kind, title: title, payloadName: payload,
            mediaType: "text/plain", byteCount: data.count, receivedAt: now
        )
        try writeManifest(item)
        return item
    }

    // MARK: Reading (the app's side)

    /// What is waiting, oldest first, and only what is whole: a manifest whose payload is missing is
    /// an interrupted share, and is swept rather than reported.
    public func pending() -> [SharedItem] {
        let names = (try? files.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var items: [SharedItem] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let item = try? decoder.decode(SharedItem.self, from: data) else {
                try? files.removeItem(at: directory.appending(path: name))
                continue
            }
            guard files.fileExists(atPath: payload(of: item).path(percentEncoded: false)) else {
                try? files.removeItem(at: directory.appending(path: name))
                continue
            }
            items.append(item)
        }
        return items.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func payload(of item: SharedItem) -> URL {
        directory.appending(path: item.payloadName)
    }

    public func data(of item: SharedItem) throws -> Data {
        do { return try Data(contentsOf: payload(of: item)) } catch { throw ShareInboxError.unreadable }
    }

    /// Both halves, gone. Called once the app has read the item — kept separate from reading so a
    /// crash mid-import leaves the item to be tried again rather than losing it.
    public func remove(_ item: SharedItem) {
        try? files.removeItem(at: payload(of: item))
        try? files.removeItem(at: manifest(of: item))
    }

    /// Everything, gone. The user's "forget what's waiting".
    public func empty() {
        for item in pending() { remove(item) }
    }

    // MARK: Plumbing

    private func prepare() throws {
        try? files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.complete,
        ])
        guard files.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw ShareInboxError.unavailable
        }
        guard pending().count < Self.maximumPending else {
            throw ShareInboxError.inboxFull(limit: Self.maximumPending)
        }
    }

    private func manifest(of item: SharedItem) -> URL {
        directory.appending(path: "\(item.id.uuidString).json")
    }

    private func writeManifest(_ item: SharedItem) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(item)
                .write(to: manifest(of: item), options: [.atomic, .completeFileProtection])
        } catch {
            try? files.removeItem(at: payload(of: item))
            throw ShareInboxError.unreadable
        }
    }

    /// A file's extension, kept only when it is short and alphanumeric. The name comes from another
    /// app, and it is about to become part of a path.
    static func extensionOf(_ url: URL) -> String {
        let candidate = url.pathExtension.lowercased()
        let allowed = candidate.count <= 8 && !candidate.isEmpty
            && candidate.allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber }
        return allowed ? candidate : "dat"
    }
}
