import Core
import Foundation

/// Tracks successive partial hypotheses for one utterance and reports when the transcript has
/// stabilized — the "transcript stability" signal endpointing combines with VAD silence
/// (PRD §6.5). Stability only shortens the silence wait; it never finalizes by itself.
public struct TranscriptBuffer: Sendable, Equatable {
    public private(set) var partials: [PartialTranscript] = []
    /// Consecutive equal hypotheses (after normalization) needed to call the transcript stable.
    public let requiredAgreement: Int

    public init(requiredAgreement: Int = 2) {
        self.requiredAgreement = requiredAgreement
    }

    public var latest: PartialTranscript? { partials.last }
    public var nextRevision: Int { (partials.last?.revision ?? 0) + 1 }

    public mutating func append(_ partial: PartialTranscript) {
        // Ignore stale results that finished out of order.
        if let last = partials.last, partial.revision <= last.revision { return }
        partials.append(partial)
        if partials.count > 8 { partials.removeFirst(partials.count - 8) }
    }

    public mutating func reset() {
        partials.removeAll()
    }

    /// True when the last `requiredAgreement` non-empty hypotheses agree.
    public var isStable: Bool {
        let recent = partials.suffix(requiredAgreement)
        guard recent.count == requiredAgreement else { return false }
        let normalized = recent.map { Self.normalize($0.text) }
        guard let first = normalized.first, !first.isEmpty else { return false }
        return normalized.allSatisfy { $0 == first }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
