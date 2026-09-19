import Foundation
import Models

// Presentation mapping from the Models module's status snapshot to the download view state.
// Kept beside the view state so the composition root only has to call these initialisers.

extension ModelDownloadViewState.Pack {
    /// One row from `ModelManager.statuses()` / `statusUpdates()`.
    init(status: ModelPackStatus, detail: String? = nil) {
        let state: State
        var rate: Double?
        switch status.state {
        case .notInstalled:
            state = .notInstalled
        case .queued:
            state = .queued
        case let .downloading(progress):
            state = .downloading(progress: progress.fractionCompleted)
            rate = progress.bytesPerSecond
        case .paused:
            state = .paused
        case let .verifying(progress):
            state = .verifying(progress: progress.fractionCompleted)
        case .installed:
            state = .installed
        case let .failed(reason):
            state = .failed(message: reason.userMessage)
        case .corrupt:
            state = .corrupt
        }
        self.init(
            id: status.id,
            name: status.displayName,
            detail: detail ?? Self.modelName(for: status.role),
            systemImage: Self.systemImage(for: status.role),
            totalBytes: status.totalBytes,
            downloadedBytes: status.downloadedBytes,
            state: state,
            bytesPerSecond: rate
        )
    }

    static func systemImage(for role: ModelRole) -> String {
        switch role {
        case .asr: "waveform"
        case .llm: "brain"
        case .tts: "speaker.wave.2.fill"
        }
    }

    static func modelName(for role: ModelRole) -> String {
        switch role {
        case .asr: "Whisper base.en"
        case .llm: "NVIDIA Nemotron 3 Nano 4B"
        case .tts: "Kokoro 82M"
        }
    }
}

extension ModelDownloadViewState {
    /// Builds the whole state from `ModelManager` output plus the network path.
    init(statuses: [ModelPackStatus], freeSpaceBytes: Int64?, network: Network) {
        self.init(packs: statuses.map { Pack(status: $0) }, freeSpaceBytes: freeSpaceBytes, network: network)
    }
}
