import Foundation

/// Unstable, revisable ASR hypothesis. UI-only: no API in the agent accepts this type
/// (PRD §6.2 — partial ASR can never create or confirm an action).
public struct PartialTranscript: Sendable, Equatable {
    public let text: String
    public let revision: Int
    public let audioDurationSeconds: Double

    public init(text: String, revision: Int, audioDurationSeconds: Double) {
        self.text = text
        self.revision = revision
        self.audioDurationSeconds = audioDurationSeconds
    }
}

/// A finalized, endpointed utterance. Only ASR finalization (or the eval/test harness inside this
/// package) can construct one; the app target cannot fabricate it from a partial result.
public struct FinalTranscript: Sendable, Equatable {
    public let text: String
    public let audioDurationSeconds: Double
    public let utteranceID: UUID

    package init(text: String, audioDurationSeconds: Double, utteranceID: UUID = UUID()) {
        self.text = text
        self.audioDurationSeconds = audioDurationSeconds
        self.utteranceID = utteranceID
    }
}

/// The only input type the agent coordinator accepts.
public enum UserUtterance: Sendable, Equatable {
    /// Endpointed speech after final transcription.
    case speech(FinalTranscript)
    /// Text the user typed and submitted (committed input, not a partial).
    case typed(String)

    public var text: String {
        switch self {
        case let .speech(transcript): transcript.text
        case let .typed(text): text
        }
    }

    public var isSpeech: Bool {
        if case .speech = self { return true }
        return false
    }
}
