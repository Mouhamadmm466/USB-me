import Foundation

/// Lifecycle state of one pack, as shown to the user.
public enum ModelPackState: Sendable, Equatable {
    case notInstalled
    /// Waiting for earlier packs (installs run one at a time).
    case queued
    case downloading(ModelDownloadProgress)
    /// Stopped by the user; the partial download is kept and resumes where it stopped.
    case paused(downloadedBytes: Int64)
    /// SHA-256 verification (after download, or a policy-driven re-hash at launch).
    case verifying(ModelDownloadProgress)
    /// The manifest-pinned revision is active and passed the integrity policy.
    case installed(revision: String)
    case failed(ModelFailureReason)
    /// Installed files are missing or no longer match their pins. Re-download to repair.
    case corrupt

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// Queued, downloading or verifying.
    public var isInProgress: Bool {
        switch self {
        case .queued, .downloading, .verifying: true
        default: false
        }
    }
}

/// Why an install failed, with a short message for the UI.
public enum ModelFailureReason: Sendable, Equatable {
    case insufficientStorage(required: Int64, available: Int64)
    /// Offline, timed out, or the connection kept dropping (after retries).
    case network
    case server(statusCode: Int)
    /// The downloaded bytes did not match the pinned size or SHA-256 (they were discarded).
    case integrity
    case deviceNotSupported([DeviceRequirementIssue])
    case storage
    case unknown

    public init(_ error: Error) {
        switch error {
        case let error as ModelDownloadError:
            switch error {
            case let .insufficientStorage(required, available):
                self = .insufficientStorage(required: required, available: available)
            case .network, .rangeNotSatisfiable, .invalidResponse, .insecureSource:
                self = .network
            case let .httpStatus(code):
                self = .server(statusCode: code)
            case .checksumMismatch, .sizeMismatch, .fileMissing, .modifiedDuringVerification:
                self = .integrity
            case .fileSystem, .invalidPack, .invalidImportSource:
                self = .storage
            case .paused, .cancelled, .alreadyInProgress, .notInstalled, .rollbackUnavailable, .unknownFile:
                self = .unknown
            }
        case let error as ModelManagerError:
            if case let .deviceNotSupported(issues) = error {
                self = .deviceNotSupported(issues)
            } else {
                self = .unknown
            }
        case is URLError:
            self = .network
        default:
            self = .unknown
        }
    }

    /// Trying again later (for example on the next launch) can succeed without user action.
    public var isTransient: Bool {
        switch self {
        case .network: true
        case let .server(code): code == 408 || code == 429 || code >= 500
        default: false
        }
    }

    /// One short sentence for the UI.
    public var userMessage: String {
        switch self {
        case let .insufficientStorage(required, available):
            let shortfall = ByteCountFormatter.string(fromByteCount: max(0, required - available), countStyle: .file)
            return "Not enough free space. Free up \(shortfall) and try again."
        case .network:
            return "Download interrupted. Check your internet connection and try again."
        case let .server(code):
            return "The download server isn't responding (error \(code)). Try again later."
        case .integrity:
            return "The download was damaged and has been discarded. Try again."
        case let .deviceNotSupported(issues):
            return issues.first?.userMessage ?? "This iPhone can't run the on-device models."
        case .storage:
            return "Couldn't save the model files. Check your free space and try again."
        case .unknown:
            return "The download didn't finish. Try again."
        }
    }
}

/// UI-ready snapshot of one pack.
public struct ModelPackStatus: Sendable, Equatable, Identifiable {
    /// Pack id.
    public let id: String
    public let role: ModelRole
    public let displayName: String
    public let license: String
    public let totalBytes: Int64
    /// Bytes already on disk for the pinned revision (downloaded or resumable).
    public let downloadedBytes: Int64
    public let state: ModelPackState
    /// A previously installed revision this app version no longer uses (kept until the pinned
    /// revision is active); nil otherwise.
    public let staleRevision: String?

    public init(
        id: String,
        role: ModelRole,
        displayName: String,
        license: String,
        totalBytes: Int64,
        downloadedBytes: Int64,
        state: ModelPackState,
        staleRevision: String?
    ) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.license = license
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.state = state
        self.staleRevision = staleRevision
    }

    public var isReady: Bool { state.isInstalled }

    /// Download progress 0...1 (verification progress while verifying).
    public var fractionCompleted: Double {
        switch state {
        case .installed: return 1
        case let .verifying(progress): return progress.fractionCompleted
        default: return totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0
        }
    }

    /// Short, user-facing error text; nil unless failed or corrupt.
    public var errorMessage: String? {
        switch state {
        case let .failed(reason): reason.userMessage
        case .corrupt: "Model files are damaged or missing. Re-download to repair."
        default: nil
        }
    }
}

/// One file handled by `ModelManager.importPendingFiles(from:removeSources:)`.
public struct ModelImportOutcome: Sendable, Equatable {
    public let packID: String
    public let filename: String
    /// The activation record when this file completed its pack; nil while other files are missing.
    public let activated: ActivationRecord?

    public init(packID: String, filename: String, activated: ActivationRecord?) {
        self.packID = packID
        self.filename = filename
        self.activated = activated
    }
}

public enum ModelManagerError: Error, Sendable, Equatable {
    case unknownPack(String)
    case unknownFile(packID: String, filename: String)
    case noPackForRole(ModelRole)
    case deviceNotSupported([DeviceRequirementIssue])
    /// The manifest-pinned revision of the pack is not installed.
    case notInstalled(packID: String)
    /// Installed files are missing or failed verification; the pack must be re-downloaded.
    case corrupt(packID: String)
}
