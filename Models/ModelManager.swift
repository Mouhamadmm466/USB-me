import Core
import Foundation
import Telemetry

/// App-facing model lifecycle: per-pack state, install queue, pause/cancel/delete/re-download,
/// storage usage, device requirements, launch reconciliation, and the only door through which
/// runtimes obtain model files (`verifiedFileURL(pack:file:)`).
///
/// **UI binding.** `ModelManager` is an actor; the UI observes it through `statusUpdates()`, an
/// `AsyncStream` of complete `[ModelPackStatus]` snapshots (the current one first, then one per
/// change, newest-only buffering). A main-actor `@Observable` view model in the app assigns each
/// snapshot to a property. This keeps all lifecycle state serialized in one actor and keeps the
/// Models module free of UI frameworks.
///
/// **Manifest policy.** Only packs in `manifest` are installed, and runtimes only receive files of
/// the revision the manifest pins. An activation record for any other revision, or for another
/// model family (pack id or role), is never used: it is reported as `staleRevision` or ignored.
/// The single exception is automatic: if the pinned revision is still on disk as the rollback
/// target (an older build was reinstalled), it is re-activated after verification.
public actor ModelManager {
    public nonisolated let manifest: ModelManifest
    public nonisolated let device: DeviceProfile
    public nonisolated let downloader: ModelDownloadManager
    private let logger: PrivacySafeLogger

    private var states: [String: ModelPackState] = [:]
    private var downloaded: [String: Int64] = [:]
    private var staleRevisions: [String: String] = [:]
    private var jobs: [String: Job] = [:]
    private var queueTail: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[ModelPackStatus]>.Continuation] = [:]
    private var intents: [String: InstallIntent]?

    private enum StopReason: Sendable {
        case pause
        case cancel
        case delete
    }

    private struct Job {
        let token: UUID
        let task: Task<Void, Error>
        var started = false
        var stopReason: StopReason?
    }

    /// Persisted so that launch reconciliation resumes interrupted downloads, and only those.
    enum InstallIntent: String, Codable, Sendable {
        case install
        case paused
    }

    public init(
        manifest: ModelManifest = .v1,
        downloader: ModelDownloadManager,
        device: DeviceProfile = .current,
        logger: PrivacySafeLogger = .shared
    ) {
        self.manifest = manifest
        self.downloader = downloader
        self.device = device
        self.logger = logger
        for pack in manifest.packs {
            states[pack.id] = .notInstalled
        }
    }

    /// Production wiring: a store under `root` (Application Support/Models by default).
    public init(
        manifest: ModelManifest = .v1,
        root: URL = ModelStorageLayout.defaultRoot,
        configuration: ModelDownloadManager.Configuration = ModelDownloadManager.Configuration(),
        device: DeviceProfile = .current,
        logger: PrivacySafeLogger = .shared
    ) {
        self.init(
            manifest: manifest,
            downloader: ModelDownloadManager(root: root, configuration: configuration, logger: logger),
            device: device,
            logger: logger
        )
    }

    // MARK: Snapshots

    public func statuses() -> [ModelPackStatus] {
        manifest.packs.map(status(of:))
    }

    public func status(ofPack packID: String) -> ModelPackStatus? {
        manifest.pack(id: packID).map(status(of:))
    }

    /// True when every pack's pinned revision is installed and verified.
    public var isReady: Bool {
        manifest.packs.allSatisfy { states[$0.id]?.isInstalled == true }
    }

    /// The current snapshot immediately, then a new one after every change. The default keeps only
    /// the newest undelivered snapshot (right for UI); pass `.unbounded` to observe every transition.
    public func statusUpdates(
        bufferingPolicy: AsyncStream<[ModelPackStatus]>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<[ModelPackStatus]> {
        let (stream, continuation) = AsyncStream<[ModelPackStatus]>.makeStream(bufferingPolicy: bufferingPolicy)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(statuses())
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Whether this device can run every pack (memory in decimal GB, iOS version, app version).
    public nonisolated func deviceRequirements() -> DeviceRequirementResult {
        manifest.checkRequirements(on: device)
    }

    public func storageUsage() async -> ModelStorageUsage {
        await downloader.storageUsage(for: manifest.packs)
    }

    // MARK: Install queue

    /// Installs one pack and waits for the outcome. Installs run one at a time in request order.
    /// Cancelling the awaiting task does not stop the download; use `pause` or `cancel`.
    public func install(packID: String) async throws {
        try await startInstall(packID: packID).value
    }

    /// Queues every pack that is not installed and waits for all of them. Throws the first error.
    public func installAll() async throws {
        var tasks: [Task<Void, Error>] = []
        for pack in manifest.packs where states[pack.id]?.isInstalled != true {
            tasks.append(try startInstall(packID: pack.id))
        }
        var firstError: Error?
        for task in tasks {
            do {
                try await task.value
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Queues an install without waiting (the UI observes `statusUpdates()`). Returns the job.
    @discardableResult
    public func startInstall(packID: String) throws -> Task<Void, Error> {
        guard let pack = manifest.pack(id: packID) else { throw ModelManagerError.unknownPack(packID) }
        if let job = jobs[packID], job.stopReason == nil { return job.task }
        if states[packID]?.isInstalled == true { return Task { () throws in } }
        let requirements = pack.checkRequirements(on: device)
        guard requirements.isSupported else {
            setState(.failed(.deviceNotSupported(requirements.issues)), for: packID)
            throw ModelManagerError.deviceNotSupported(requirements.issues)
        }
        let token = UUID()
        let previous = queueTail
        let task = Task { () throws in
            await previous?.value
            try await self.runJob(pack, token: token)
        }
        jobs[packID] = Job(token: token, task: task)
        queueTail = Task { _ = await task.result }
        setIntent(.install, for: packID)
        setState(.queued, for: packID)
        log(pack.role, .queued, bytes: nil)
        return task
    }

    /// Continues a paused, cancelled, failed or interrupted install from its partial files.
    @discardableResult
    public func resume(packID: String) throws -> Task<Void, Error> {
        try startInstall(packID: packID)
    }

    /// Stops a queued or running install and keeps the partial download (state `.paused`).
    public func pause(packID: String) {
        guard stopJob(packID, reason: .pause) else { return }
        setIntent(.paused, for: packID)
        setState(.paused(downloadedBytes: currentDownloadedBytes(packID)), for: packID)
    }

    /// Stops a queued or running install and keeps the partial download (state `.notInstalled`;
    /// a later install resumes from the partial).
    public func cancel(packID: String) {
        guard stopJob(packID, reason: .cancel) else { return }
        setIntent(nil, for: packID)
        downloaded[packID] = currentDownloadedBytes(packID)
        setState(.notInstalled, for: packID)
    }

    private func stopJob(_ packID: String, reason: StopReason) -> Bool {
        guard var job = jobs[packID], job.stopReason == nil else { return false }
        job.stopReason = reason
        jobs[packID] = job
        job.task.cancel()
        return true
    }

    private func runJob(_ pack: ModelPack, token: UUID) async throws {
        guard var job = jobs[pack.id], job.token == token else {
            throw ModelDownloadError.cancelled // superseded by a newer request for this pack
        }
        if let reason = job.stopReason {
            jobs[pack.id] = nil
            throw reason == .pause ? ModelDownloadError.paused : ModelDownloadError.cancelled
        }
        job.started = true
        jobs[pack.id] = job
        let alreadyDownloaded = await downloader.downloadedBytes(for: pack)
        downloaded[pack.id] = alreadyDownloaded
        if jobs[pack.id]?.stopReason == nil {
            setState(.downloading(.starting(pack, completedBytes: alreadyDownloaded)), for: pack.id)
        }
        // Progress is applied in order by one consumer, which is drained before the outcome is
        // applied, so no state from this install can land after its terminal state.
        let (events, sink) = AsyncStream<ModelDownloadProgress>.makeStream(bufferingPolicy: .unbounded)
        let consumer = Task {
            for await progress in events {
                self.applyInstallProgress(progress, token: token)
            }
        }
        do {
            let record = try await downloader.install(pack) { sink.yield($0) }
            sink.finish()
            await consumer.value
            if jobs[pack.id]?.token == token { jobs[pack.id] = nil }
            staleRevisions[pack.id] = nil
            downloaded[pack.id] = pack.totalBytes
            setIntent(nil, for: pack.id)
            setState(.installed(revision: record.revision), for: pack.id)
            log(pack.role, .installed, bytes: pack.totalBytes)
        } catch {
            sink.finish()
            await consumer.value
            let bytes = await downloader.downloadedBytes(for: pack)
            let isCurrent = jobs[pack.id]?.token == token
            var reason = isCurrent ? jobs[pack.id]?.stopReason : nil
            if isCurrent { jobs[pack.id] = nil }
            if reason == nil, let downloadError = error as? ModelDownloadError {
                if downloadError == .paused { reason = .pause }
                if downloadError == .cancelled { reason = .cancel }
            }
            downloaded[pack.id] = bytes
            if jobs[pack.id] == nil { // no newer request has taken over this pack
                switch reason {
                case .pause:
                    setState(.paused(downloadedBytes: bytes), for: pack.id)
                case .cancel:
                    setState(.notInstalled, for: pack.id)
                case .delete:
                    break // delete(packID:) sets the final state
                case nil:
                    let failure = ModelFailureReason(error)
                    if !failure.isTransient { setIntent(nil, for: pack.id) }
                    setState(.failed(failure), for: pack.id)
                }
            }
            switch reason {
            case .pause: throw ModelDownloadError.paused
            case .cancel, .delete: throw ModelDownloadError.cancelled
            case nil: throw error
            }
        }
    }

    private func currentDownloadedBytes(_ packID: String) -> Int64 {
        switch states[packID] {
        case let .downloading(progress)?, let .verifying(progress)?: progress.completedBytes
        case let .paused(bytes)?: bytes
        default: downloaded[packID] ?? 0
        }
    }

    // MARK: Delete and re-download

    /// Stops any install of the pack and removes all of its files and records.
    public func delete(packID: String) async throws {
        guard let pack = manifest.pack(id: packID) else { throw ModelManagerError.unknownPack(packID) }
        if var job = jobs[packID] {
            job.stopReason = .delete
            jobs[packID] = job
            job.task.cancel()
            if job.started { _ = await job.task.result }
            if jobs[packID]?.token == job.token { jobs[packID] = nil }
        }
        try await downloader.delete(pack)
        downloaded[packID] = 0
        staleRevisions[packID] = nil
        setIntent(nil, for: packID)
        setState(.notInstalled, for: packID)
    }

    /// Deletes the pack and downloads it again from scratch.
    public func redownload(packID: String) async throws {
        try await delete(packID: packID)
        try await install(packID: packID)
    }

    // MARK: Runtime access

    /// The only way a runtime obtains a model file. Returns the URL of `file` in the manifest-pinned
    /// revision of `pack` after the integrity policy passed (quick metadata check; full SHA-256 when
    /// metadata changed, the app build changed, or the last full check is older than 7 days).
    /// A failure marks the pack `.corrupt` and throws `ModelManagerError.corrupt`.
    public func verifiedFileURL(pack packID: String, file filename: String) async throws -> URL {
        guard let pack = manifest.pack(id: packID) else { throw ModelManagerError.unknownPack(packID) }
        guard pack.file(named: filename) != nil else {
            throw ModelManagerError.unknownFile(packID: packID, filename: filename)
        }
        if states[packID] == .corrupt { throw ModelManagerError.corrupt(packID: packID) }
        do {
            return try await downloader.verifiedFileURL(for: pack, filename: filename)
        } catch let error as ModelDownloadError {
            if case .notInstalled = error { throw ModelManagerError.notInstalled(packID: packID) }
            if error.isIntegrityFailure {
                if jobs[packID] == nil { setState(.corrupt, for: packID) }
                throw ModelManagerError.corrupt(packID: packID)
            }
            throw error
        }
    }

    /// Verified URLs of every file of the pack that fills `role`, keyed by filename.
    public func verifiedFileURLs(for role: ModelRole) async throws -> [String: URL] {
        guard let pack = manifest.pack(for: role) else { throw ModelManagerError.noPackForRole(role) }
        var urls: [String: URL] = [:]
        for file in pack.files {
            urls[file.filename] = try await verifiedFileURL(pack: pack.id, file: file.filename)
        }
        return urls
    }

    // MARK: Offline import

    /// Where developers and provisioning tools drop model files for `importPendingFiles(from:)`:
    /// `Documents/ModelImport/` (e.g. `xcrun devicectl device copy to … --destination
    /// Documents/ModelImport/<file>`; see docs/setup/models.md, "Offline import").
    public static var defaultImportDirectory: URL {
        URL.documentsDirectory.appending(path: "ModelImport", directoryHint: .isDirectory)
    }

    /// Imports one pinned file of a manifest pack from local storage, without the network. It takes
    /// the same verified path as a download (see `ModelDownloadManager.importLocalFile`); the pack is
    /// activated once all of its files are present and verified, and the activation record is then
    /// returned (nil while files are still missing). A mismatch throws and leaves the source untouched.
    @discardableResult
    public func importLocalFile(
        _ sourceURL: URL,
        pack packID: String,
        file filename: String,
        removeSource: Bool = true,
        progress: ModelDownloadManager.ProgressHandler? = nil
    ) async throws -> ActivationRecord? {
        guard let pack = manifest.pack(id: packID) else { throw ModelManagerError.unknownPack(packID) }
        guard pack.file(named: filename) != nil else {
            throw ModelManagerError.unknownFile(packID: packID, filename: filename)
        }
        let requirements = pack.checkRequirements(on: device)
        guard requirements.isSupported else { throw ModelManagerError.deviceNotSupported(requirements.issues) }
        if let job = jobs[packID], job.stopReason == nil { throw ModelDownloadError.alreadyInProgress(packID: packID) }
        do {
            let record = try await downloader.importLocalFile(sourceURL, pack: pack, file: filename, removeSource: removeSource, progress: progress)
            await refreshState(of: pack)
            return record
        } catch {
            await refreshState(of: pack)
            throw error
        }
    }

    /// Imports every file in `directory` whose name is a pinned file of a manifest pack, then
    /// refreshes pack states. Other files (and hidden files and folders) are ignored: they are never
    /// imported, activated or deleted. Results are keyed by filename; a successfully imported file
    /// is moved out of `directory` when `removeSources` is true.
    @discardableResult
    public func importPendingFiles(
        from directory: URL = ModelManager.defaultImportDirectory,
        removeSources: Bool = true
    ) async -> [String: Result<ModelImportOutcome, any Error>] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        var results: [String: Result<ModelImportOutcome, any Error>] = [:]
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = item.lastPathComponent
            let candidates = manifest.packs.filter { $0.file(named: filename) != nil }
            guard !candidates.isEmpty,
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue // not a manifest file: ignored
            }
            // A filename shared by several packs is resolved by its size (the hash then decides).
            let size = ModelFileSystem.fileSize(item)
            let pack = candidates.first { $0.file(named: filename)?.bytes == size } ?? candidates[0]
            do {
                let record = try await importLocalFile(item, pack: pack.id, file: filename, removeSource: removeSources)
                results[filename] = .success(ModelImportOutcome(packID: pack.id, filename: filename, activated: record))
            } catch {
                results[filename] = .failure(error)
            }
        }
        return results
    }

    /// Recomputes a pack's state from disk (metadata checks only) after an out-of-band change.
    private func refreshState(of pack: ModelPack) async {
        guard jobs[pack.id] == nil else { return }
        switch await downloader.quickCheckInstallation(of: pack) {
        case let .healthy(revision), let .needsFullVerification(revision):
            staleRevisions[pack.id] = nil
            downloaded[pack.id] = pack.totalBytes
            setIntent(nil, for: pack.id)
            setState(.installed(revision: revision), for: pack.id)
        case .corrupt:
            downloaded[pack.id] = await downloader.downloadedBytes(for: pack)
            setState(.corrupt, for: pack.id)
        case .notInstalled:
            let bytes = await downloader.downloadedBytes(for: pack)
            downloaded[pack.id] = bytes
            let paused = loadIntents()[pack.id] == .paused && bytes > 0
            setState(paused ? .paused(downloadedBytes: bytes) : .notInstalled, for: pack.id)
        }
    }

    // MARK: Launch reconciliation

    /// Brings in-memory state in line with the disk after launch:
    /// - empties `.trash`, deletes partials the manifest no longer references and stale temp files;
    /// - for each pack: an active revision matching the pins is quick-checked (full re-hash when
    ///   the policy requires it) → `.installed` or `.corrupt` (missing or damaged files);
    /// - an active revision that is not pinned is never used (`staleRevision`), except that a
    ///   pinned rollback target is re-activated; unknown directories and files are ignored;
    /// - partial downloads are counted (`downloadedBytes`), and installs that were running when the
    ///   app stopped are queued again when `resumeInterruptedDownloads` is true (paused ones stay
    ///   paused).
    @discardableResult
    public func reconcileOnLaunch(resumeInterruptedDownloads: Bool = true) async -> [ModelPackStatus] {
        do {
            try await downloader.prepareStorage()
        } catch {
            log(nil, .storageUnavailable, bytes: nil)
        }
        let referenced = Set(manifest.allFiles.map { $0.sha256.lowercased() })
        await downloader.removeOrphanedFiles(keepingPartialsFor: referenced)
        let intents = loadIntents()
        for pack in manifest.packs where jobs[pack.id] == nil {
            await reconcile(pack, intent: intents[pack.id])
        }
        if resumeInterruptedDownloads {
            for pack in manifest.packs where intents[pack.id] == .install && jobs[pack.id] == nil && states[pack.id]?.isInstalled != true {
                _ = try? startInstall(packID: pack.id)
            }
        }
        return statuses()
    }

    private func reconcile(_ pack: ModelPack, intent: InstallIntent?) async {
        staleRevisions[pack.id] = nil
        var record = await downloader.activeRecord(packID: pack.id)
        if let current = record, !current.matches(pack) {
            if current.previousMatches(pack), (try? await downloader.rollback(packID: pack.id)) != nil {
                log(pack.role, .rolledBack, bytes: pack.totalBytes)
                record = await downloader.activeRecord(packID: pack.id)
            } else if current.packID == pack.id, current.role == pack.role {
                staleRevisions[pack.id] = current.revision
                log(pack.role, .staleRevision, bytes: nil)
            } else {
                log(pack.role, .familyMismatch, bytes: nil)
            }
        }

        if let record, record.matches(pack) {
            var check = await downloader.quickCheckInstallation(of: pack)
            if case .needsFullVerification = check {
                setState(.verifying(.verificationStarting(pack)), for: pack.id)
                let (events, sink) = AsyncStream<ModelDownloadProgress>.makeStream(bufferingPolicy: .unbounded)
                let consumer = Task {
                    for await progress in events where progress.phase == .verifying {
                        self.setState(.verifying(progress), for: pack.id)
                    }
                }
                check = await downloader.verifyInstallation(of: pack) { sink.yield($0) }
                sink.finish()
                await consumer.value
            }
            switch check {
            case let .healthy(revision):
                downloaded[pack.id] = pack.totalBytes
                setState(.installed(revision: revision), for: pack.id)
                return
            case .corrupt:
                downloaded[pack.id] = await downloader.downloadedBytes(for: pack)
                log(pack.role, .corrupt, bytes: nil)
                setState(.corrupt, for: pack.id)
                return
            case .notInstalled, .needsFullVerification:
                break
            }
        }

        let bytes = await downloader.downloadedBytes(for: pack)
        downloaded[pack.id] = bytes
        setState(intent == .paused && bytes > 0 ? .paused(downloadedBytes: bytes) : .notInstalled, for: pack.id)
    }

    // MARK: Progress and publishing

    private func applyInstallProgress(_ progress: ModelDownloadProgress, token: UUID) {
        let packID = progress.packID
        // Ignore events once the user paused, cancelled or deleted this install.
        guard let job = jobs[packID], job.token == token, job.stopReason == nil else { return }
        downloaded[packID] = progress.completedBytes
        switch progress.phase {
        case .downloading: setState(.downloading(progress), for: packID)
        case .verifying: setState(.verifying(progress), for: packID)
        }
    }

    private func setState(_ state: ModelPackState, for packID: String) {
        guard states[packID] != state else { return }
        states[packID] = state
        guard !subscribers.isEmpty else { return }
        let snapshot = statuses()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func status(of pack: ModelPack) -> ModelPackStatus {
        let state = states[pack.id] ?? .notInstalled
        let bytes: Int64 = switch state {
        case .installed: pack.totalBytes
        case let .downloading(progress), let .verifying(progress): progress.completedBytes
        case let .paused(downloadedBytes): downloadedBytes
        default: downloaded[pack.id] ?? 0
        }
        return ModelPackStatus(
            id: pack.id,
            role: pack.role,
            displayName: pack.displayName,
            license: pack.license,
            totalBytes: pack.totalBytes,
            downloadedBytes: min(max(0, bytes), pack.totalBytes),
            state: state,
            staleRevision: staleRevisions[pack.id]
        )
    }

    // MARK: Install intents

    private var intentsURL: URL {
        downloader.layout.root.appending(path: ".intents.json", directoryHint: .notDirectory)
    }

    private func loadIntents() -> [String: InstallIntent] {
        if let intents { return intents }
        var loaded: [String: InstallIntent] = [:]
        if let data = try? Data(contentsOf: intentsURL),
           let decoded = try? ModelJSON.decode([String: InstallIntent].self, from: data) {
            loaded = decoded.filter { manifest.pack(id: $0.key) != nil }
        }
        for item in ModelFileSystem.contents(of: downloader.layout.root)
        where item.lastPathComponent.hasPrefix(".intents.json.tmp-") {
            try? FileManager.default.removeItem(at: item) // left by an interrupted write
        }
        intents = loaded
        return loaded
    }

    private func setIntent(_ intent: InstallIntent?, for packID: String) {
        var current = loadIntents()
        guard current[packID] != intent else { return }
        current[packID] = intent
        intents = current
        do {
            try ModelFileSystem.ensureDirectory(downloader.layout.root)
            try ModelFileSystem.atomicWrite(ModelJSON.encode(current), to: intentsURL)
        } catch {
            log(nil, .storageUnavailable, bytes: nil)
        }
    }

    private func log(_ role: ModelRole?, _ status: DownloadLogStatus, bytes: Int64?) {
        logger.log(.download(model: role.map { SafeLabel($0) } ?? "store", status: SafeLabel(status), bytes: bytes))
    }
}
