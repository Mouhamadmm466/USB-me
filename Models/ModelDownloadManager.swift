import Core
import Foundation
import Telemetry

// MARK: - Public value types

/// Exponential backoff for transient failures (timeouts, lost connections, HTTP 408/429/5xx).
public struct RetryPolicy: Sendable, Equatable {
    /// Retries allowed after consecutive failures that received no new bytes. An attempt that
    /// makes progress starts a new streak, so a flaky link can still finish a multi-GB file.
    public var maxRetries: Int
    /// Hard cap on attempts for one file, however much progress each makes.
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var multiplier: Double
    public var maxDelay: Duration
    /// Random ± fraction applied to each delay (0 disables jitter).
    public var jitter: Double

    public init(
        maxRetries: Int = 5,
        maxAttempts: Int = 50,
        initialDelay: Duration = .seconds(1),
        multiplier: Double = 2,
        maxDelay: Duration = .seconds(30),
        jitter: Double = 0.2
    ) {
        self.maxRetries = maxRetries
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let `default` = RetryPolicy()

    /// Delay before the retry that follows consecutive failure number `failure` (1-based).
    public func delay(afterFailure failure: Int) -> Duration {
        let base = initialDelay.inSeconds * pow(multiplier, Double(max(0, failure - 1)))
        let capped = min(base, maxDelay.inSeconds)
        let factor = jitter > 0 ? Double.random(in: (1 - jitter)...(1 + jitter)) : 1
        return .seconds(max(0, capped * factor))
    }
}

/// Progress of one pack's install, published on `ModelDownloadManager.progressUpdates()`.
public struct ModelDownloadProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case downloading
        case verifying
    }

    public let packID: String
    public let filename: String
    public let phase: Phase
    /// Downloaded bytes (downloading) or hashed bytes (verifying) of the current file.
    public let fileCompletedBytes: Int64
    public let fileTotalBytes: Int64
    /// Pack-level bytes downloaded so far.
    public let completedBytes: Int64
    public let totalBytes: Int64
    /// Recent transfer rate (download or hash), bytes per second.
    public let bytesPerSecond: Double

    public init(
        packID: String,
        filename: String,
        phase: Phase,
        fileCompletedBytes: Int64,
        fileTotalBytes: Int64,
        completedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double
    ) {
        self.packID = packID
        self.filename = filename
        self.phase = phase
        self.fileCompletedBytes = fileCompletedBytes
        self.fileTotalBytes = fileTotalBytes
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// Pack-level while downloading; the current file's hash progress while verifying.
    public var fractionCompleted: Double {
        let (done, total) = phase == .downloading ? (completedBytes, totalBytes) : (fileCompletedBytes, fileTotalBytes)
        return total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
    }

    static func starting(_ pack: ModelPack, completedBytes: Int64) -> ModelDownloadProgress {
        let file = pack.files.first
        return ModelDownloadProgress(
            packID: pack.id, filename: file?.filename ?? "", phase: .downloading,
            fileCompletedBytes: 0, fileTotalBytes: file?.bytes ?? 0,
            completedBytes: completedBytes, totalBytes: pack.totalBytes, bytesPerSecond: 0
        )
    }

    static func verificationStarting(_ pack: ModelPack) -> ModelDownloadProgress {
        let file = pack.files.first
        return ModelDownloadProgress(
            packID: pack.id, filename: file?.filename ?? "", phase: .verifying,
            fileCompletedBytes: 0, fileTotalBytes: file?.bytes ?? 0,
            completedBytes: pack.totalBytes, totalBytes: pack.totalBytes, bytesPerSecond: 0
        )
    }
}

public enum ModelDownloadError: Error, Sendable, Equatable {
    case invalidPack(ModelManifestError)
    /// `required` = bytes still to download + the safety margin; `available` = usable free space.
    case insufficientStorage(required: Int64, available: Int64)
    case checksumMismatch(filename: String, expected: String, actual: String)
    case sizeMismatch(filename: String, expected: Int64, actual: Int64)
    case httpStatus(Int)
    case rangeNotSatisfiable
    case invalidResponse
    case insecureSource
    case network(URLError.Code)
    /// Stopped by `pause(packID:)`; the partial download is kept.
    case paused
    /// Stopped by `cancel(packID:)` or task cancellation; the partial download is kept.
    case cancelled
    case alreadyInProgress(packID: String)
    /// The file is not one of the pack's pinned files.
    case unknownFile(packID: String, filename: String)
    /// An import source that is missing, a symbolic link, or not a regular file.
    case invalidImportSource(filename: String)
    case notInstalled(packID: String)
    case rollbackUnavailable(packID: String)
    case fileMissing(filename: String)
    case modifiedDuringVerification(filename: String)
    case fileSystem(String)

    /// Retrying later can succeed without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .network, .rangeNotSatisfiable, .invalidResponse, .modifiedDuringVerification: true
        case let .httpStatus(code): code == 408 || code == 429 || code >= 500
        default: false
        }
    }

    /// The bytes on disk are missing or are not the pinned bytes.
    public var isIntegrityFailure: Bool {
        switch self {
        case .checksumMismatch, .sizeMismatch, .fileMissing: true
        default: false
        }
    }
}

/// Health of the active revision of a pack, relative to the pins in a `ModelPack`.
public enum InstallationCheck: Sendable, Equatable {
    /// No activation record for exactly these pins.
    case notInstalled
    case healthy(revision: String)
    /// Plausible, but the integrity policy requires a full re-hash before use.
    case needsFullVerification(revision: String)
    /// At least one file is missing or does not match its pin.
    case corrupt(revision: String, filenames: [String])
}

/// Closed vocabulary for `TelemetryEvent.download` statuses.
enum DownloadLogStatus: String, SafeLabelConvertible {
    case queued
    case started
    case resumed
    case retrying
    case rangeIgnored
    case rangeRestart
    case verified
    case reverified
    case checksumMismatch
    case sizeMismatch
    case activated
    case installed
    case rolledBack
    case paused
    case cancelled
    case failed
    case insufficientStorage
    case deleted
    case corrupt
    case orphansRemoved
    case activationRecordInvalid
    case staleRevision
    case familyMismatch
    case storageUnavailable
    case imported
    case importRejected
    case importIgnored
}

// MARK: - Download manager

/// Owns the on-device model store: resumable downloads, SHA-256 verification, atomic activation,
/// rollback and deletion. `ModelManager` layers manifest policy, queueing and UI state on top.
///
/// Install pipeline for one file: free-space check → `<root>/.partial/<sha256>.part` via HTTP
/// Range → size check → SHA-256 → atomic rename into `<root>/<packID>/<revision>/<filename>`.
/// When every file of the pack is in place, `<root>/<packID>/active.json` is rewritten atomically;
/// the previously active revision is kept as the rollback target and older ones are removed.
public actor ModelDownloadManager {
    public struct Configuration: Sendable {
        /// `AppVersionInfo.integrityStamp` of the running build.
        public var appVersion: String
        /// Full re-hash interval (`IntegrityPolicy.maximumAge`).
        public var integrityMaximumAge: TimeInterval
        /// Free space kept in reserve on top of the bytes still to download.
        public var storageMargin: Int64
        public var retryPolicy: RetryPolicy
        /// Minimum spacing between progress events.
        public var progressInterval: Duration
        public var clock: AgentClock

        public init(
            appVersion: String = AppVersionInfo.current.integrityStamp,
            integrityMaximumAge: TimeInterval = IntegrityPolicy.defaultMaximumAge,
            storageMargin: Int64 = 512 * 1024 * 1024,
            retryPolicy: RetryPolicy = .default,
            progressInterval: Duration = .milliseconds(250),
            clock: AgentClock = AgentClock()
        ) {
            self.appVersion = appVersion
            self.integrityMaximumAge = integrityMaximumAge
            self.storageMargin = storageMargin
            self.retryPolicy = retryPolicy
            self.progressInterval = progressInterval
            self.clock = clock
        }

        public var integrityPolicy: IntegrityPolicy {
            IntegrityPolicy(appVersion: appVersion, maximumAge: integrityMaximumAge)
        }
    }

    /// Receives the progress of one call, synchronously and in order, from the thread producing it.
    public typealias ProgressHandler = @Sendable (ModelDownloadProgress) -> Void

    public nonisolated let layout: ModelStorageLayout
    public nonisolated let configuration: Configuration
    private let makeSessionConfiguration: @Sendable () -> URLSessionConfiguration
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let logger: PrivacySafeLogger
    private nonisolated let progress = Broadcaster<ModelDownloadProgress>()
    /// Per-call handlers of running installs, by pack id.
    private var progressHandlers: [String: ProgressHandler] = [:]

    private enum StopReason: Sendable {
        case paused
        case cancelled
    }

    private struct Operation {
        enum Kind {
            case install(Task<ActivationRecord, Error>)
            /// Rollback or local import: not cancellable, finishes promptly.
            case maintenance
        }

        let token: UUID
        let kind: Kind
        var stopReason: StopReason?
    }

    /// At most one mutating operation per pack.
    private var operations: [String: Operation] = [:]
    /// Bytes each running install still needs, so concurrent installs do not double-count space.
    private var reservations: [String: Int64] = [:]
    /// SHA-256 of files being downloaded (partials are content-addressed).
    private var filesInFlight: Set<String> = []
    /// Full re-hashes in progress, by path, so concurrent loads share one hash.
    private var verifications: [String: Task<IntegrityRecord, Error>] = [:]

    /// - Parameters:
    ///   - sessionConfiguration: factory for the `URLSessionConfiguration` of each HTTP attempt.
    ///     Tests inject one whose `protocolClasses` serve canned responses.
    ///   - availableCapacity: free-space probe (defaults to `StorageSpace.availableCapacity(for:)`).
    public init(
        root: URL = ModelStorageLayout.defaultRoot,
        configuration: Configuration = Configuration(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = ModelDownloadManager.defaultSessionConfiguration,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64 = StorageSpace.availableCapacity(for:),
        logger: PrivacySafeLogger = .shared
    ) {
        layout = ModelStorageLayout(root: root)
        self.configuration = configuration
        makeSessionConfiguration = sessionConfiguration
        self.availableCapacity = availableCapacity
        self.logger = logger
    }

    /// Foreground session tuned for multi-GB transfers: no URL cache, a per-request idle timeout,
    /// and no waiting for connectivity (the retry policy decides when to give up).
    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }

    public nonisolated var root: URL { layout.root }

    /// Progress of every install (downloading and verifying phases), for all packs.
    public nonisolated func progressUpdates() -> AsyncStream<ModelDownloadProgress> {
        progress.subscribe(bufferingNewest: 64)
    }

    public func isBusy(packID: String) -> Bool { operations[packID] != nil }

    // MARK: Install, pause, resume, cancel

    /// Downloads (resuming any partial), verifies and activates `pack`. Idempotent: files that are
    /// already installed and pass the integrity policy are not downloaded again. Cancelling the
    /// calling task stops the transfer and keeps the partial file (throws `.cancelled`).
    ///
    /// - Parameter handler: receives this install's progress (every event is also published on
    ///   `progressUpdates()`); every call happens before this method returns.
    @discardableResult
    public func install(_ pack: ModelPack, progress handler: ProgressHandler? = nil) async throws -> ActivationRecord {
        do {
            try pack.validate()
        } catch let error as ModelManifestError {
            throw ModelDownloadError.invalidPack(error)
        }
        guard operations[pack.id] == nil else { throw ModelDownloadError.alreadyInProgress(packID: pack.id) }
        let token = UUID()
        let job = Task { () throws -> ActivationRecord in
            do {
                let record = try await self.performInstall(pack)
                self.endOperation(pack.id, token: token)
                return record
            } catch {
                let mapped = self.stopError(for: error, pack: pack, token: token)
                self.endOperation(pack.id, token: token)
                throw mapped
            }
        }
        operations[pack.id] = Operation(token: token, kind: .install(job))
        progressHandlers[pack.id] = handler
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Continues an interrupted or paused install from its partial files.
    @discardableResult
    public func resume(_ pack: ModelPack, progress handler: ProgressHandler? = nil) async throws -> ActivationRecord {
        try await install(pack, progress: handler)
    }

    /// Stops the running install of `packID`, keeping the partial download; `install` throws `.paused`.
    public func pause(packID: String) {
        stop(packID, reason: .paused)
    }

    /// Stops the running install of `packID`, keeping the partial download; `install` throws `.cancelled`.
    public func cancel(packID: String) {
        stop(packID, reason: .cancelled)
    }

    private func stop(_ packID: String, reason: StopReason) {
        guard var operation = operations[packID], case let .install(job) = operation.kind else { return }
        operation.stopReason = reason
        operations[packID] = operation
        job.cancel()
    }

    private func endOperation(_ packID: String, token: UUID) {
        guard operations[packID]?.token == token else { return }
        operations[packID] = nil
        progressHandlers[packID] = nil
    }

    /// Publishes to every `progressUpdates()` subscriber and to `handler`.
    private func progressSink(_ handler: ProgressHandler?) -> ProgressHandler {
        let broadcaster = progress
        return { event in
            broadcaster.yield(event)
            handler?(event)
        }
    }

    private func stopError(for error: Error, pack: ModelPack, token: UUID) -> Error {
        let isCancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
        guard isCancellation else {
            if !(error is ModelDownloadError) || (error as? ModelDownloadError)?.isTransient == false {
                log(pack.role, .failed, bytes: downloadedBytes(for: pack))
            }
            return error
        }
        let reason = operations[pack.id].flatMap { $0.token == token ? $0.stopReason : nil }
        if reason == .paused {
            log(pack.role, .paused, bytes: downloadedBytes(for: pack))
            return ModelDownloadError.paused
        }
        log(pack.role, .cancelled, bytes: downloadedBytes(for: pack))
        return ModelDownloadError.cancelled
    }

    private func performInstall(_ pack: ModelPack) async throws -> ActivationRecord {
        try prepareStorage()
        let revision = pack.revision
        try ModelFileSystem.ensureDirectory(layout.packDirectory(pack.id))
        try ModelFileSystem.ensureDirectory(layout.revisionDirectory(packID: pack.id, revision: revision))

        let policy = configuration.integrityPolicy
        let ledger = readLedger(packID: pack.id, revision: revision)
        let now = configuration.clock.now()
        let pending = pack.files.filter { file in
            let url = layout.fileURL(packID: pack.id, revision: revision, filename: file.filename)
            return ModelIntegrity.quickCheck(file: url, record: ledger.records[file.filename], expected: file, policy: policy, now: now) != .valid
        }
        if pending.isEmpty, let current = readActivationRecord(packID: pack.id), current.matches(pack) {
            return current // already installed and healthy
        }

        let remaining = pending.reduce(Int64(0)) { $0 + bytesStillToDownload($1, packID: pack.id, revision: revision) }
        try reserveStorage(remaining, for: pack)
        defer { reservations[pack.id] = nil }
        if remaining > 0 {
            let pendingBytes = pending.reduce(Int64(0)) { $0 + $1.bytes }
            log(pack.role, remaining < pendingBytes ? .resumed : .started, bytes: remaining)
        }

        var completedBytes = pack.totalBytes - pending.reduce(Int64(0)) { $0 + $1.bytes }
        for file in pending {
            try await installFile(file, of: pack, revision: revision, completedBefore: completedBytes)
            completedBytes += file.bytes
        }
        return try activate(pack, revision: revision)
    }

    private func bytesStillToDownload(_ file: ModelFile, packID: String, revision: String) -> Int64 {
        let destination = layout.fileURL(packID: packID, revision: revision, filename: file.filename)
        if ModelFileSystem.fileSize(destination) == file.bytes { return 0 } // needs verification only
        let partial = ModelFileSystem.fileSize(layout.partialURL(sha256: file.sha256)) ?? 0
        return file.bytes - min(max(0, partial), file.bytes)
    }

    private func reserveStorage(_ bytes: Int64, for pack: ModelPack) throws {
        guard bytes > 0 else { return }
        let required = bytes + configuration.storageMargin
        let reservedByOthers = reservations.filter { $0.key != pack.id }.values.reduce(0, +)
        let free: Int64
        do {
            free = try availableCapacity(layout.root)
        } catch {
            log(pack.role, .storageUnavailable, bytes: nil)
            throw ModelDownloadError.fileSystem("free space could not be determined")
        }
        let available = max(0, free - reservedByOthers)
        guard available >= required else {
            log(pack.role, .insufficientStorage, bytes: required)
            throw ModelDownloadError.insufficientStorage(required: required, available: available)
        }
        reservations[pack.id] = bytes
    }

    private func installFile(_ file: ModelFile, of pack: ModelPack, revision: String, completedBefore: Int64) async throws {
        let destination = layout.fileURL(packID: pack.id, revision: revision, filename: file.filename)

        // A complete copy is already in place (activation was interrupted, or its record is stale
        // or missing): verify it where it is instead of downloading it again.
        if ModelFileSystem.fileSize(destination) == file.bytes {
            do {
                let record = try await verify(destination, as: file, of: pack, completedBefore: completedBefore)
                try storeIntegrityRecord(record, filename: file.filename, packID: pack.id, revision: revision)
                return
            } catch let error as ModelIntegrityError where error.isContentMismatch {
                log(pack.role, .corrupt, bytes: file.bytes)
            }
        }
        try ModelFileSystem.removeItemIfExists(destination)

        guard filesInFlight.insert(file.sha256).inserted else {
            throw ModelDownloadError.alreadyInProgress(packID: pack.id)
        }
        defer { filesInFlight.remove(file.sha256) }

        let partial = layout.partialURL(sha256: file.sha256)
        try await fetch(file, of: pack, into: partial, completedBefore: completedBefore)

        let size = ModelFileSystem.fileSize(partial) ?? 0
        guard size == file.bytes else {
            try? ModelFileSystem.removeItemIfExists(partial)
            log(pack.role, .sizeMismatch, bytes: size)
            throw ModelDownloadError.sizeMismatch(filename: file.filename, expected: file.bytes, actual: size)
        }

        let record: IntegrityRecord
        do {
            record = try await verify(partial, as: file, of: pack, completedBefore: completedBefore)
        } catch let error as ModelIntegrityError {
            if error.isContentMismatch {
                // Bytes that failed verification are never kept: the next attempt starts over.
                try? ModelFileSystem.removeItemIfExists(partial)
                log(pack.role, .checksumMismatch, bytes: file.bytes)
            }
            throw Self.map(error, filename: file.filename)
        }

        // Atomic move into the (not yet active) revision directory. rename(2) preserves size,
        // inode and mtime, so the record just computed stays valid for the new path.
        try ModelFileSystem.renameReplacing(from: partial, to: destination)
        try storeIntegrityRecord(record, filename: file.filename, packID: pack.id, revision: revision)
        log(pack.role, .verified, bytes: file.bytes)
    }

    /// Resumable transfer of one file into its partial, with retries. Returns once the partial
    /// holds `file.bytes` bytes (content is checked by the caller).
    private func fetch(_ file: ModelFile, of pack: ModelPack, into partial: URL, completedBefore: Int64) async throws {
        try ModelFileSystem.ensureDirectory(layout.partialDirectory)
        let retry = configuration.retryPolicy
        var consecutiveFailures = 0
        var attempts = 0
        var restartedFromZero = false

        while true {
            try Task.checkCancellation()
            var offset = ModelFileSystem.fileSize(partial) ?? 0
            if offset > file.bytes {
                try ModelFileSystem.removeItemIfExists(partial) // longer than the pin: cannot be ours
                offset = 0
            }
            if offset == file.bytes { return }
            try ModelFileSystem.createFileIfNeeded(partial)
            attempts += 1

            let transfer = HTTPRangeTransfer(
                sourceURL: file.sourceURL,
                resumeOffset: offset,
                expectedBytes: file.bytes,
                fileURL: partial,
                makeConfiguration: makeSessionConfiguration,
                progressInterval: configuration.progressInterval,
                onProgress: downloadProgressHandler(for: file, of: pack, completedBefore: completedBefore)
            )

            let transientError: ModelDownloadError
            do {
                let outcome = try await transfer.run()
                if outcome.restartedFromZero { log(pack.role, .rangeIgnored, bytes: offset) }
                if outcome.fileBytes == file.bytes { return }
                // The body ended early without a transport error: resume from what arrived.
                transientError = .network(.networkConnectionLost)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as TransferFailure {
                switch failure {
                case let .rangeNotSatisfiable(serverTotal):
                    // 416: re-validate. A partial of exactly the pinned size is complete (the hash
                    // decides); anything else cannot be trusted, so restart from byte 0 once.
                    if ModelFileSystem.fileSize(partial) == file.bytes { return }
                    guard !restartedFromZero else { throw ModelDownloadError.rangeNotSatisfiable }
                    restartedFromZero = true
                    log(pack.role, .rangeRestart, bytes: serverTotal ?? offset)
                    try ModelFileSystem.removeItemIfExists(partial)
                    continue
                case .invalidContentRange:
                    guard !restartedFromZero else { throw ModelDownloadError.invalidResponse }
                    restartedFromZero = true
                    log(pack.role, .rangeRestart, bytes: offset)
                    try ModelFileSystem.removeItemIfExists(partial)
                    continue
                case let .sizeMismatch(expected, reported):
                    try? ModelFileSystem.removeItemIfExists(partial)
                    log(pack.role, .sizeMismatch, bytes: reported)
                    throw ModelDownloadError.sizeMismatch(filename: file.filename, expected: expected, actual: reported)
                case let .httpStatus(code):
                    let error = ModelDownloadError.httpStatus(code)
                    guard error.isTransient else { throw error }
                    transientError = error
                case .insecureRedirect:
                    throw ModelDownloadError.insecureSource
                case .notHTTP:
                    throw ModelDownloadError.invalidResponse
                case let .writeFailed(outOfSpace):
                    guard outOfSpace else { throw ModelDownloadError.fileSystem("could not write the partial download") }
                    let missing = file.bytes - (ModelFileSystem.fileSize(partial) ?? 0)
                    let free = (try? availableCapacity(layout.root)) ?? 0
                    log(pack.role, .insufficientStorage, bytes: missing)
                    throw ModelDownloadError.insufficientStorage(required: missing + configuration.storageMargin, available: free)
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard Self.isTransient(error.code) else { throw ModelDownloadError.network(error.code) }
                transientError = .network(error.code)
            }

            let size = ModelFileSystem.fileSize(partial) ?? 0
            consecutiveFailures = size > offset ? 1 : consecutiveFailures + 1
            guard consecutiveFailures <= retry.maxRetries, attempts < retry.maxAttempts else {
                throw transientError
            }
            log(pack.role, .retrying, bytes: size)
            try await Task.sleep(for: retry.delay(afterFailure: consecutiveFailures))
        }
    }

    static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .callIsActive, .badServerResponse, .resourceUnavailable:
            true
        default:
            false
        }
    }

    private func downloadProgressHandler(for file: ModelFile, of pack: ModelPack, completedBefore: Int64) -> HTTPRangeTransfer.ProgressHandler {
        let sink = progressSink(progressHandlers[pack.id])
        let packID = pack.id
        let packTotal = pack.totalBytes
        return { bytes, rate in
            sink(ModelDownloadProgress(
                packID: packID, filename: file.filename, phase: .downloading,
                fileCompletedBytes: bytes, fileTotalBytes: file.bytes,
                completedBytes: completedBefore + bytes, totalBytes: packTotal, bytesPerSecond: rate
            ))
        }
    }

    /// Full SHA-256 verification with `.verifying` progress events.
    private func verify(_ url: URL, as file: ModelFile, of pack: ModelPack, completedBefore: Int64) async throws -> IntegrityRecord {
        try await verify(url, as: file, packID: pack.id, packTotalBytes: pack.totalBytes,
                         completedBytes: completedBefore + file.bytes, sink: progressSink(progressHandlers[pack.id]))
    }

    private func verify(_ url: URL, as file: ModelFile, packID: String, packTotalBytes: Int64, completedBytes: Int64, sink: @escaping ProgressHandler) async throws -> IntegrityRecord {
        let throttle = ProgressThrottle(interval: configuration.progressInterval)
        let emit: @Sendable (Int64, Double) -> Void = { hashed, rate in
            sink(ModelDownloadProgress(
                packID: packID, filename: file.filename, phase: .verifying,
                fileCompletedBytes: hashed, fileTotalBytes: file.bytes,
                completedBytes: completedBytes, totalBytes: packTotalBytes, bytesPerSecond: rate
            ))
        }
        emit(0, 0)
        return try await ModelIntegrity.verify(
            file: url, expected: file, appVersion: configuration.appVersion, clock: configuration.clock
        ) { hashed, _ in
            if let rate = throttle.update(bytes: hashed, force: hashed >= file.bytes) {
                emit(hashed, rate)
            }
        }
    }

    // MARK: Activation and rollback

    private func activate(_ pack: ModelPack, revision: String) throws -> ActivationRecord {
        // Last line of defence: never point active.json at an incomplete directory.
        for file in pack.files {
            let url = layout.fileURL(packID: pack.id, revision: revision, filename: file.filename)
            guard ModelFileSystem.fileSize(url) == file.bytes else {
                throw ModelDownloadError.fileMissing(filename: file.filename)
            }
        }
        let current = readActivationRecord(packID: pack.id)
        var previous: RevisionPointer?
        if let current, current.role == pack.role {
            // Re-activating the same revision (a repair) keeps the existing rollback target.
            previous = current.revision == revision ? current.previous : current.pointer
        }
        if let candidate = previous,
           !ModelFileSystem.isDirectory(layout.revisionDirectory(packID: pack.id, revision: candidate.revision)) {
            previous = nil
        }
        let record = ActivationRecord(
            packID: pack.id,
            role: pack.role,
            revision: revision,
            files: pack.files,
            activatedAt: configuration.clock.now(),
            appVersion: configuration.appVersion,
            previous: previous
        )
        try writeActivationRecord(record)
        log(pack.role, .activated, bytes: pack.totalBytes)
        removeRevisions(of: pack.id, keeping: [revision] + (previous.map { [$0.revision] } ?? []))
        return record
    }

    /// Re-activates the previously active revision after re-checking its files with the integrity
    /// policy. The current revision becomes the new rollback target, so a rollback can be undone.
    @discardableResult
    public func rollback(packID: String) async throws -> ActivationRecord {
        guard operations[packID] == nil else { throw ModelDownloadError.alreadyInProgress(packID: packID) }
        guard let current = readActivationRecord(packID: packID), let previous = current.previous else {
            throw ModelDownloadError.rollbackUnavailable(packID: packID)
        }
        let token = UUID()
        operations[packID] = Operation(token: token, kind: .maintenance)
        defer { endOperation(packID, token: token) }

        let total = previous.files.reduce(Int64(0)) { $0 + $1.bytes }
        for file in previous.files {
            do {
                _ = try await validateInstalledFile(file, packID: packID, revision: previous.revision, role: current.role, packTotalBytes: total, handler: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelDownloadError.rollbackUnavailable(packID: packID)
            }
        }
        let record = ActivationRecord(
            packID: packID,
            role: current.role,
            revision: previous.revision,
            files: previous.files,
            activatedAt: configuration.clock.now(),
            appVersion: configuration.appVersion,
            previous: current.pointer
        )
        try writeActivationRecord(record)
        log(current.role, .rolledBack, bytes: total)
        return record
    }

    /// Deletes every revision directory of a pack except `keep`, plus leftover temporary files.
    private func removeRevisions(of packID: String, keeping keep: [String]) {
        for item in ModelFileSystem.contents(of: layout.packDirectory(packID)) {
            let name = item.lastPathComponent
            if ModelFileSystem.isTemporaryWriteName(name) {
                try? FileManager.default.removeItem(at: item)
            } else if ModelFileSystem.isDirectory(item), !keep.contains(name) {
                try? moveToTrashAndRemove(item)
            }
        }
    }

    // MARK: Delete

    /// Removes a pack completely: every revision, its activation and integrity records, and its
    /// partial downloads. A running install is cancelled first. The pack directory is detached
    /// with a single rename, so it disappears atomically.
    public func delete(_ pack: ModelPack) async throws {
        if let operation = operations[pack.id] {
            guard case let .install(job) = operation.kind else {
                throw ModelDownloadError.alreadyInProgress(packID: pack.id)
            }
            stop(pack.id, reason: .cancelled)
            _ = await job.result
        }
        guard operations[pack.id] == nil else { throw ModelDownloadError.alreadyInProgress(packID: pack.id) }
        // No suspension points below.
        let directory = layout.packDirectory(pack.id)
        if ModelFileSystem.exists(directory) {
            do {
                try moveToTrashAndRemove(directory)
            } catch {
                throw ModelDownloadError.fileSystem("could not delete the model files")
            }
        }
        for file in pack.files where !filesInFlight.contains(file.sha256) {
            try? ModelFileSystem.removeItemIfExists(layout.partialURL(sha256: file.sha256))
        }
        log(pack.role, .deleted, bytes: nil)
    }

    private func moveToTrashAndRemove(_ item: URL) throws {
        try ModelFileSystem.ensureDirectory(layout.trashDirectory)
        let trashed = layout.trashDirectory.appending(path: "\(item.lastPathComponent)-\(UUID().uuidString)", directoryHint: .notDirectory)
        try ModelFileSystem.renameReplacing(from: item, to: trashed)
        try? FileManager.default.removeItem(at: trashed)
    }

    // MARK: Offline import

    /// Imports one pinned file from local storage — a developer sideload
    /// (`xcrun devicectl device copy to …` into Documents/ModelImport/), Finder file sharing or
    /// enterprise provisioning — through the same path as a download: `.partial/<sha256>.part` →
    /// size + SHA-256 → atomic rename into the revision directory → integrity record. Once every
    /// file of `pack` is present and verified, the pack is activated exactly like an install and the
    /// record is returned; until then the result is nil.
    ///
    /// With `removeSource` (default) on the same volume the file is moved, never copied, so a 2.8 GB
    /// model is not duplicated: it is hashed where it is, then renamed (rename keeps its inode, size
    /// and mtime, so the fresh integrity record stays valid). Otherwise it is copied (an APFS clone
    /// when possible) and the copy is verified. On any mismatch the source is left untouched and a
    /// typed error is thrown: `.unknownFile`, `.invalidImportSource`, `.sizeMismatch`,
    /// `.checksumMismatch`.
    @discardableResult
    public func importLocalFile(
        _ sourceURL: URL,
        pack: ModelPack,
        file filename: String,
        removeSource: Bool = true,
        progress handler: ProgressHandler? = nil
    ) async throws -> ActivationRecord? {
        do {
            try pack.validate()
        } catch let error as ModelManifestError {
            throw ModelDownloadError.invalidPack(error)
        }
        guard let file = pack.file(named: filename) else {
            log(pack.role, .importIgnored, bytes: nil)
            throw ModelDownloadError.unknownFile(packID: pack.id, filename: filename)
        }
        let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink == false, values?.isRegularFile == true,
              let size = ModelFileSystem.fileSize(sourceURL) else {
            throw ModelDownloadError.invalidImportSource(filename: filename)
        }
        guard size == file.bytes else {
            log(pack.role, .importRejected, bytes: size)
            throw ModelDownloadError.sizeMismatch(filename: filename, expected: file.bytes, actual: size)
        }
        guard operations[pack.id] == nil, !filesInFlight.contains(file.sha256) else {
            throw ModelDownloadError.alreadyInProgress(packID: pack.id)
        }
        let token = UUID()
        operations[pack.id] = Operation(token: token, kind: .maintenance)
        filesInFlight.insert(file.sha256)
        defer {
            filesInFlight.remove(file.sha256)
            endOperation(pack.id, token: token)
        }

        try prepareStorage()
        let revision = pack.revision
        try ModelFileSystem.ensureDirectory(layout.packDirectory(pack.id))
        try ModelFileSystem.ensureDirectory(layout.revisionDirectory(packID: pack.id, revision: revision))
        let partial = layout.partialURL(sha256: file.sha256)
        let destination = layout.fileURL(packID: pack.id, revision: revision, filename: filename)
        let sink = progressSink(handler)
        let alreadyInstalled = pack.files.filter { $0.filename != filename }.reduce(Int64(0)) { total, other in
            ModelFileSystem.fileSize(layout.fileURL(packID: pack.id, revision: revision, filename: other.filename)) == other.bytes
                ? total + other.bytes : total
        }
        let completedBytes = alreadyInstalled + file.bytes

        var record: IntegrityRecord
        if removeSource {
            // Hash in place first: a mismatch must leave the source untouched.
            record = try await verifyImport(sourceURL, as: file, of: pack, completedBytes: completedBytes, sink: sink, discardOnMismatch: false)
            do {
                try ModelFileSystem.renameReplacing(from: sourceURL, to: partial)
            } catch let error as POSIXError where error.code == .EXDEV {
                // Another volume: copy, verify the copy, then remove the source.
                record = try await copyForImport(sourceURL, to: partial, as: file, of: pack, completedBytes: completedBytes, sink: sink)
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if let metadata = try? FileMetadata.read(partial), !metadata.matches(record) {
                // Changed between the hash and the move: verify what was actually moved.
                record = try await verifyImport(partial, as: file, of: pack, completedBytes: completedBytes, sink: sink, discardOnMismatch: true)
            }
        } else {
            record = try await copyForImport(sourceURL, to: partial, as: file, of: pack, completedBytes: completedBytes, sink: sink)
        }

        try ModelFileSystem.renameReplacing(from: partial, to: destination)
        ModelFileSystem.applyProtection(destination)
        try storeIntegrityRecord(record, filename: filename, packID: pack.id, revision: revision)
        log(pack.role, .imported, bytes: file.bytes)

        // Activate once every file of the pack is present and verified (same record as an install).
        let ledger = readLedger(packID: pack.id, revision: revision)
        let policy = configuration.integrityPolicy
        let now = configuration.clock.now()
        let complete = pack.files.allSatisfy { other in
            let url = layout.fileURL(packID: pack.id, revision: revision, filename: other.filename)
            return ModelIntegrity.quickCheck(file: url, record: ledger.records[other.filename], expected: other, policy: policy, now: now) == .valid
        }
        guard complete else { return nil }
        return try activate(pack, revision: revision)
    }

    private func verifyImport(
        _ url: URL, as file: ModelFile, of pack: ModelPack, completedBytes: Int64, sink: @escaping ProgressHandler, discardOnMismatch: Bool
    ) async throws -> IntegrityRecord {
        do {
            return try await verify(url, as: file, packID: pack.id, packTotalBytes: pack.totalBytes, completedBytes: completedBytes, sink: sink)
        } catch let error as ModelIntegrityError {
            if discardOnMismatch { try? ModelFileSystem.removeItemIfExists(url) }
            log(pack.role, .importRejected, bytes: file.bytes)
            throw Self.map(error, filename: file.filename)
        }
    }

    private func copyForImport(
        _ source: URL, to partial: URL, as file: ModelFile, of pack: ModelPack, completedBytes: Int64, sink: @escaping ProgressHandler
    ) async throws -> IntegrityRecord {
        try ModelFileSystem.removeItemIfExists(partial)
        do {
            try FileManager.default.copyItem(at: source, to: partial) // clonefile(2) on APFS
        } catch {
            try? ModelFileSystem.removeItemIfExists(partial)
            if HTTPRangeTransfer.isOutOfSpace(error) {
                let free = (try? availableCapacity(layout.root)) ?? 0
                throw ModelDownloadError.insufficientStorage(required: file.bytes + configuration.storageMargin, available: free)
            }
            throw ModelDownloadError.fileSystem("could not copy the imported file")
        }
        ModelFileSystem.applyProtection(partial)
        return try await verifyImport(partial, as: file, of: pack, completedBytes: completedBytes, sink: sink, discardOnMismatch: true)
    }

    // MARK: Inspection and load-time verification

    /// The activation record of a pack, if present and readable.
    public func activeRecord(packID: String) -> ActivationRecord? {
        readActivationRecord(packID: packID)
    }

    /// URL of a file of the active revision, returned only if the active revision is exactly
    /// `pack`'s pins and the file passes the integrity policy (quick check, full re-hash when due).
    public func verifiedFileURL(for pack: ModelPack, filename: String) async throws -> URL {
        guard let file = pack.file(named: filename) else { throw ModelDownloadError.fileMissing(filename: filename) }
        guard let record = readActivationRecord(packID: pack.id), record.matches(pack) else {
            throw ModelDownloadError.notInstalled(packID: pack.id)
        }
        _ = try await validateInstalledFile(file, packID: pack.id, revision: record.revision, role: pack.role, packTotalBytes: pack.totalBytes, handler: nil)
        return layout.fileURL(packID: pack.id, revision: record.revision, filename: filename)
    }

    /// Metadata-only health check of the active revision (a `stat` per file, no hashing).
    public func quickCheckInstallation(of pack: ModelPack) -> InstallationCheck {
        guard let record = readActivationRecord(packID: pack.id), record.matches(pack) else { return .notInstalled }
        let ledger = readLedger(packID: pack.id, revision: record.revision)
        let policy = configuration.integrityPolicy
        let now = configuration.clock.now()
        var corrupt: [String] = []
        var needsFullVerification = false
        for file in pack.files {
            let url = layout.fileURL(packID: pack.id, revision: record.revision, filename: file.filename)
            switch ModelIntegrity.quickCheck(file: url, record: ledger.records[file.filename], expected: file, policy: policy, now: now) {
            case .valid: continue
            case .needsFullVerification: needsFullVerification = true
            case .invalid: corrupt.append(file.filename)
            }
        }
        if !corrupt.isEmpty { return .corrupt(revision: record.revision, filenames: corrupt) }
        return needsFullVerification ? .needsFullVerification(revision: record.revision) : .healthy(revision: record.revision)
    }

    /// Full integrity policy over the active revision: re-hashes whatever the policy requires and
    /// records the result. Emits `.verifying` progress for the pack (also to `handler`).
    public func verifyInstallation(of pack: ModelPack, progress handler: ProgressHandler? = nil) async -> InstallationCheck {
        guard let record = readActivationRecord(packID: pack.id), record.matches(pack) else { return .notInstalled }
        var corrupt: [String] = []
        for file in pack.files {
            do {
                _ = try await validateInstalledFile(file, packID: pack.id, revision: record.revision, role: pack.role, packTotalBytes: pack.totalBytes, handler: handler)
            } catch is CancellationError {
                return .needsFullVerification(revision: record.revision)
            } catch {
                corrupt.append(file.filename)
            }
        }
        return corrupt.isEmpty ? .healthy(revision: record.revision) : .corrupt(revision: record.revision, filenames: corrupt)
    }

    private func validateInstalledFile(_ file: ModelFile, packID: String, revision: String, role: ModelRole, packTotalBytes: Int64, handler: ProgressHandler?) async throws -> IntegrityRecord {
        let url = layout.fileURL(packID: packID, revision: revision, filename: file.filename)
        let policy = configuration.integrityPolicy
        let stored = readLedger(packID: packID, revision: revision).records[file.filename]
        switch ModelIntegrity.quickCheck(file: url, record: stored, expected: file, policy: policy, now: configuration.clock.now()) {
        case .valid:
            if let stored { return stored }
        case let .invalid(error):
            log(role, .corrupt, bytes: nil)
            throw Self.map(error, filename: file.filename)
        case .needsFullVerification:
            break
        }

        let key = ModelFileSystem.path(url)
        let task: Task<IntegrityRecord, Error>
        if let running = verifications[key] {
            task = running
        } else {
            let sink = progressSink(handler)
            task = Task { try await self.verify(url, as: file, packID: packID, packTotalBytes: packTotalBytes, completedBytes: packTotalBytes, sink: sink) }
            verifications[key] = task
        }
        do {
            let record = try await task.value
            if verifications[key] == task {
                verifications[key] = nil
                try storeIntegrityRecord(record, filename: file.filename, packID: packID, revision: revision)
                log(role, .reverified, bytes: file.bytes)
            }
            return record
        } catch let error as ModelIntegrityError {
            if verifications[key] == task { verifications[key] = nil }
            log(role, .corrupt, bytes: file.bytes)
            throw Self.map(error, filename: file.filename)
        } catch {
            if verifications[key] == task { verifications[key] = nil }
            throw error
        }
    }

    /// Bytes of `pack`'s pinned revision already on disk: installed files plus resumable partials.
    public func downloadedBytes(for pack: ModelPack) -> Int64 {
        pack.files.reduce(Int64(0)) { total, file in
            let installed = layout.fileURL(packID: pack.id, revision: pack.revision, filename: file.filename)
            if ModelFileSystem.fileSize(installed) == file.bytes { return total + file.bytes }
            let partial = ModelFileSystem.fileSize(layout.partialURL(sha256: file.sha256)) ?? 0
            return total + min(max(0, partial), file.bytes)
        }
    }

    public func storageUsage(for packs: [ModelPack]) -> ModelStorageUsage {
        let usage = packs.map { pack -> ModelStorageUsage.Pack in
            let activeRevision = readActivationRecord(packID: pack.id)?.revision
            var active: Int64 = 0
            var inactive: Int64 = 0
            for item in ModelFileSystem.contents(of: layout.packDirectory(pack.id)) where ModelFileSystem.isDirectory(item) {
                let size = ModelFileSystem.logicalSize(of: item)
                if item.lastPathComponent == activeRevision { active += size } else { inactive += size }
            }
            let partial = Set(pack.files.map { $0.sha256.lowercased() }).reduce(Int64(0)) { total, sha in
                total + (ModelFileSystem.fileSize(layout.partialURL(sha256: sha)) ?? 0)
            }
            return ModelStorageUsage.Pack(id: pack.id, displayName: pack.displayName, activeBytes: active, inactiveBytes: inactive, partialBytes: partial)
        }
        return ModelStorageUsage(packs: usage, availableBytes: try? availableCapacity(layout.root))
    }

    // MARK: Housekeeping

    /// Creates the store (excluded from backup, iOS protection class) and empties `.trash`.
    public func prepareStorage() throws {
        try ModelFileSystem.ensureDirectory(layout.root)
        try ModelFileSystem.ensureDirectory(layout.partialDirectory)
        for item in ModelFileSystem.contents(of: layout.trashDirectory) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Deletes partial downloads whose SHA-256 is not referenced (they can never complete) and
    /// temporary files left in pack directories by interrupted atomic writes. Unknown pack
    /// directories and files are left alone. Returns the number of bytes removed.
    @discardableResult
    public func removeOrphanedFiles(keepingPartialsFor referencedSHA256: Set<String>) -> Int64 {
        var removedBytes: Int64 = 0
        for item in ModelFileSystem.contents(of: layout.partialDirectory) {
            let name = item.lastPathComponent
            let sha = name.hasSuffix(".part") ? String(name.dropLast(".part".count)) : ""
            guard !referencedSHA256.contains(sha), !filesInFlight.contains(sha) else { continue }
            let size = ModelFileSystem.logicalSize(of: item)
            if (try? FileManager.default.removeItem(at: item)) != nil { removedBytes += size }
        }
        for packDirectory in ModelFileSystem.contents(of: layout.root) where ModelFileSystem.isDirectory(packDirectory) {
            let packID = packDirectory.lastPathComponent
            guard !packID.hasPrefix("."), operations[packID] == nil else { continue }
            let candidates = [packDirectory] + ModelFileSystem.contents(of: packDirectory).filter(ModelFileSystem.isDirectory)
            for directory in candidates {
                for item in ModelFileSystem.contents(of: directory) where ModelFileSystem.isTemporaryWriteName(item.lastPathComponent) {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
        if removedBytes > 0 { log(nil, .orphansRemoved, bytes: removedBytes) }
        return removedBytes
    }

    // MARK: Records

    private func readActivationRecord(packID: String) -> ActivationRecord? {
        let url = layout.activationRecordURL(packID: packID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? ModelJSON.decode(ActivationRecord.self, from: data),
              record.formatVersion <= ActivationRecord.currentFormatVersion,
              record.packID == packID,
              Self.isSafe(record) else {
            log(nil, .activationRecordInvalid, bytes: nil)
            return nil
        }
        return record
    }

    /// Paths are built from record contents, so a tampered record must not escape the pack.
    private static func isSafe(_ record: ActivationRecord) -> Bool {
        let revisions = [record.revision] + (record.previous.map { [$0.revision] } ?? [])
        let files = record.files + (record.previous?.files ?? [])
        return revisions.allSatisfy(ModelPack.isSafePathComponent)
            && files.allSatisfy { ModelPack.isSafePathComponent($0.filename) && HexEncoding.isSHA256($0.sha256.lowercased()) }
    }

    private func writeActivationRecord(_ record: ActivationRecord) throws {
        try ModelFileSystem.atomicWrite(ModelJSON.encode(record), to: layout.activationRecordURL(packID: record.packID))
    }

    private func readLedger(packID: String, revision: String) -> IntegrityLedger {
        let url = layout.integrityLedgerURL(packID: packID, revision: revision)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? ModelJSON.decode(IntegrityLedger.self, from: data) else {
            return IntegrityLedger()
        }
        return ledger
    }

    /// Read-modify-write in one actor turn (no suspension), so concurrent updates are not lost.
    private func storeIntegrityRecord(_ record: IntegrityRecord, filename: String, packID: String, revision: String) throws {
        var ledger = readLedger(packID: packID, revision: revision)
        ledger.records[filename] = record
        try ModelFileSystem.atomicWrite(ModelJSON.encode(ledger), to: layout.integrityLedgerURL(packID: packID, revision: revision))
    }

    static func map(_ error: ModelIntegrityError, filename: String) -> ModelDownloadError {
        switch error {
        case .fileMissing: .fileMissing(filename: filename)
        case let .sizeMismatch(expected, actual): .sizeMismatch(filename: filename, expected: expected, actual: actual)
        case let .checksumMismatch(expected, actual): .checksumMismatch(filename: filename, expected: expected, actual: actual)
        case .modifiedDuringVerification: .modifiedDuringVerification(filename: filename)
        case let .unreadable(code): .fileSystem("unreadable model file (errno \(code))")
        }
    }

    private func log(_ role: ModelRole?, _ status: DownloadLogStatus, bytes: Int64?) {
        logger.log(.download(model: role.map { SafeLabel($0) } ?? "store", status: SafeLabel(status), bytes: bytes))
    }
}

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
