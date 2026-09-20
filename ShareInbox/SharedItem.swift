import Foundation

/// One thing the user sent to the app from somewhere else, waiting in the App Group container for
/// the app to pick it up.
///
/// Deliberately small and dependency-free: this type crosses the boundary between the share
/// extension and the app, and both sides have to agree on it without either pulling in the other's
/// world. It carries *about* the payload — never the payload itself — so a manifest stays a few
/// hundred bytes however big the thing shared was.
public struct SharedItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A file with its own bytes: a PDF, a Word file, a note exported as text.
        case document
        /// Selected text, sent as a note.
        case text
        /// A web address. Kept as an address, not fetched — reading it is a network request, and
        /// network requests go through the policy the user set, not through a share sheet.
        case link
    }

    public var id: UUID
    public var kind: Kind
    /// What to call it. From the file name, the first line of the text, or the address.
    public var title: String
    /// The payload's name inside the inbox directory. Every item has one, including notes and
    /// links, so the app has a single path to read.
    public var payloadName: String
    public var mediaType: String?
    public var byteCount: Int
    public var receivedAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        payloadName: String,
        mediaType: String? = nil,
        byteCount: Int = 0,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.payloadName = payloadName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.receivedAt = receivedAt
    }
}

/// Why something could not be taken in. Each case is a sentence the extension can show as-is: a
/// share sheet that fails silently teaches people not to trust the feature.
public enum ShareInboxError: Error, Equatable, CustomStringConvertible {
    case unavailable
    case tooLarge(limitBytes: Int)
    case inboxFull(limit: Int)
    case unreadable

    public var description: String {
        switch self {
        case .unavailable:
            "Voice Agent isn't set up on this iPhone yet. Open it once, then try again."
        case let .tooLarge(limit):
            "That's larger than \(limit / 1_000_000) MB, which is more than I can read on the phone."
        case let .inboxFull(limit):
            "There are already \(limit) things waiting. Open Voice Agent so it can read them first."
        case .unreadable:
            "I couldn't read that one."
        }
    }
}
