import Core
import Foundation

/// Thread-safe record of the text the assistant is speaking right now (plus a short tail after it
/// ends, while the room echo decays). Used for self-transcription detection.
public final class SpokenTextTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?
    private var lastEnded: Date?
    private var lastText: String?
    private let echoTail: TimeInterval

    public init(echoTail: TimeInterval = 0.6) {
        self.echoTail = echoTail
    }

    func begin(_ text: String) {
        lock.withLock {
            current = text
            lastText = text
            lastEnded = nil
        }
    }

    func end() {
        lock.withLock {
            current = nil
            lastEnded = Date()
        }
    }

    /// Text that may still be audible (being spoken, or ended within the echo tail).
    public func audibleText(at date: Date = Date()) -> String? {
        lock.withLock {
            if let current { return current }
            if let lastEnded, let lastText, date.timeIntervalSince(lastEnded) < echoTail { return lastText }
            return nil
        }
    }

    public var isSpeaking: Bool { lock.withLock { current != nil } }
}
