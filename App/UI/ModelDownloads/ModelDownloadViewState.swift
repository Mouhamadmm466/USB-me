import Foundation

/// Everything the model download UI renders (onboarding page and Settings → Models).
/// A plain value: the app maps `ModelManager` status into it (see
/// `ModelDownloadViewState+Models.swift` for a ready-made mapping).
struct ModelDownloadViewState: Equatable, Sendable {
    struct Pack: Equatable, Sendable, Identifiable {
        enum State: Equatable, Sendable {
            case notInstalled
            /// Waiting for the pack ahead of it (installs run one at a time).
            case queued
            /// 0...1.
            case downloading(progress: Double)
            /// Stopped by the person; resumes where it stopped.
            case paused
            /// Checking the SHA-256 of the downloaded files; 0...1.
            case verifying(progress: Double)
            case installed
            /// One short sentence explaining what went wrong and what to do.
            case failed(message: String)
            /// Installed files are damaged or missing; re-download to repair.
            case corrupt
        }

        /// Pack id (`ModelPack.id`).
        let id: String
        /// "Language model".
        var name: String
        /// "NVIDIA Nemotron 3 Nano 4B".
        var detail: String
        var systemImage: String
        var totalBytes: Int64
        /// Bytes on disk for this pack (downloaded or resumable).
        var downloadedBytes: Int64
        var state: State
        /// Recent transfer rate while downloading, for a time-remaining estimate.
        var bytesPerSecond: Double?

        init(
            id: String,
            name: String,
            detail: String,
            systemImage: String = "shippingbox.fill",
            totalBytes: Int64,
            downloadedBytes: Int64 = 0,
            state: State,
            bytesPerSecond: Double? = nil
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.systemImage = systemImage
            self.totalBytes = totalBytes
            self.downloadedBytes = downloadedBytes
            self.state = state
            self.bytesPerSecond = bytesPerSecond
        }

        var isInstalled: Bool { state == .installed }

        var isBusy: Bool {
            switch state {
            case .queued, .downloading, .verifying: true
            default: false
            }
        }

        var needsAttention: Bool {
            switch state {
            case .failed, .corrupt: true
            default: false
            }
        }

        /// 0...1 for the progress bar.
        var fraction: Double {
            switch state {
            case .installed: 1
            case let .downloading(progress): progress
            case let .verifying(progress): progress
            default: totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0
            }
        }
    }

    enum Network: Equatable, Sendable {
        case wifi
        case cellular
        case offline
        case unknown
    }

    var packs: [Pack]
    /// Free space on the device; nil when it could not be read.
    var freeSpaceBytes: Int64?
    var network: Network

    init(packs: [Pack], freeSpaceBytes: Int64? = nil, network: Network = .unknown) {
        self.packs = packs
        self.freeSpaceBytes = freeSpaceBytes
        self.network = network
    }

    // MARK: Derived

    /// Size of every pack together.
    var totalBytes: Int64 { packs.reduce(0) { $0 + $1.totalBytes } }

    var downloadedBytes: Int64 {
        packs.reduce(0) { $0 + ($1.isInstalled ? $1.totalBytes : min($1.downloadedBytes, $1.totalBytes)) }
    }

    /// Bytes still to download.
    var remainingBytes: Int64 { max(0, totalBytes - downloadedBytes) }

    var overallFraction: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }

    var allInstalled: Bool { !packs.isEmpty && packs.allSatisfy(\.isInstalled) }

    /// Something is queued, downloading or verifying.
    var isInProgress: Bool { packs.contains(where: \.isBusy) }

    /// Nothing is running and at least one pack is paused.
    var isPaused: Bool { !isInProgress && packs.contains { $0.state == .paused } }

    var hasFailure: Bool { packs.contains(where: \.needsAttention) }

    /// False only when free space is known and smaller than what is left to download.
    var hasEnoughSpace: Bool {
        guard let freeSpaceBytes else { return true }
        return freeSpaceBytes >= remainingBytes
    }

    /// Combined transfer rate of the packs downloading now.
    var bytesPerSecond: Double? {
        let rates = packs.compactMap { pack -> Double? in
            if case .downloading = pack.state { return pack.bytesPerSecond }
            return nil
        }
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }
}

/// What the person can do with model packs. Onboarding uses the bulk actions; Settings also
/// uses the per-pack ones.
struct ModelDownloadActions {
    /// Download every pack that is not installed (queues them).
    var downloadAll: @MainActor () -> Void
    var pauseAll: @MainActor () -> Void
    var resumeAll: @MainActor () -> Void
    /// Download one pack that is not installed.
    var download: @MainActor (_ packID: String) -> Void
    /// Try a failed pack again.
    var retry: @MainActor (_ packID: String) -> Void
    /// Re-hash an installed pack against its pinned checksums.
    var verify: @MainActor (_ packID: String) -> Void
    /// Remove an installed pack (after a confirmation dialog).
    var delete: @MainActor (_ packID: String) -> Void
    /// Remove and download again (after a confirmation dialog). Also repairs a corrupt pack.
    var redownload: @MainActor (_ packID: String) -> Void

    init(
        downloadAll: @escaping @MainActor () -> Void,
        pauseAll: @escaping @MainActor () -> Void,
        resumeAll: @escaping @MainActor () -> Void,
        download: @escaping @MainActor (_ packID: String) -> Void,
        retry: @escaping @MainActor (_ packID: String) -> Void,
        verify: @escaping @MainActor (_ packID: String) -> Void,
        delete: @escaping @MainActor (_ packID: String) -> Void,
        redownload: @escaping @MainActor (_ packID: String) -> Void
    ) {
        self.downloadAll = downloadAll
        self.pauseAll = pauseAll
        self.resumeAll = resumeAll
        self.download = download
        self.retry = retry
        self.verify = verify
        self.delete = delete
        self.redownload = redownload
    }

    static var inert: ModelDownloadActions {
        ModelDownloadActions(
            downloadAll: {}, pauseAll: {}, resumeAll: {}, download: { _ in }, retry: { _ in },
            verify: { _ in }, delete: { _ in }, redownload: { _ in }
        )
    }
}
