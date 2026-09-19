import Agent
import Core
import SwiftUI

extension AgentState {
    /// How the orb expresses this state.
    var orbMode: OrbMode {
        switch self {
        case .booting, .downloadingModels, .warmingModels: .preparing
        case .idle: .idle
        case .listening, .endpointing, .interrupted: .listening
        case .transcribing, .thinking: .understanding
        case .speaking, .reportingResult: .speaking
        case .waitingForClarification: .clarifying
        case .waitingForConfirmation: .confirming
        case .executing: .executing
        case .permissionRequired: .blocked
        case .error: .failed
        }
    }

    /// The models are not ready yet, so a session cannot start.
    var isPreparing: Bool {
        self == .booting || self == .downloadingModels || self == .warmingModels
    }

    /// States worth announcing to VoiceOver when they begin (the rest are audible anyway).
    var announcesToVoiceOver: Bool {
        switch self {
        case .waitingForConfirmation, .waitingForClarification, .permissionRequired, .error: true
        default: false
        }
    }
}

extension ResultBanner.Style {
    var tone: Tone {
        switch self {
        case .success: .jade
        case .cancelled: .neutral
        case .failure: .danger
        }
    }
}
