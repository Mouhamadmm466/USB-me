import Core
import Foundation
import Telemetry

/// What MessageUI reported after the compose sheet closed.
public enum MessageComposeOutcome: String, Codable, Sendable, Hashable, CaseIterable, SafeLabelConvertible {
    /// MessageUI returned `.sent` (the message was handed to Messages for delivery).
    case sent
    /// The user dismissed the sheet.
    case cancelled
    /// MessageUI returned `.failed`.
    case failed
    /// The device cannot send texts or there is nothing to present from.
    case unavailable
}

/// Presents Apple's message composer. The user reviews and sends in Apple's UI; implementations
/// must never report `.sent` unless MessageUI did.
public protocol MessageComposing: Sendable {
    func canSendText() async -> Bool
    func compose(recipients: [String], body: String) async -> MessageComposeOutcome
}
