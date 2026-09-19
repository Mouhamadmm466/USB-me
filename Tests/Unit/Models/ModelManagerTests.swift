import Core
import Foundation
import Models
import Telemetry
import Testing

private func state(_ snapshot: [ModelPackStatus], _ packID: String) -> ModelPackState? {
    snapshot.first { $0.id == packID }?.state
}

private func isDownloadingWithBytes(_ snapshot: [ModelPackStatus], _ packID: String) -> Bool {
    if case let .downloading(progress)? = snapshot.first(where: { $0.id == packID })?.state {
        return progress.completedBytes > 0
    }
    return false
}

@Suite("Model manager", .timeLimit(.minutes(3)))
struct ModelManagerTests {
    /// Two packs served by the stub: speech recognition (2 files) and a language model (1 file).
    struct Fixture {
        let directory: TemporaryDirectory
        let asrWeights: HostedFile
        let asrVAD: HostedFile
        let llm: HostedFile
        let manifest: ModelManifest

        var asrPack: ModelPack { manifest.packs[0] }
        var llmPack: ModelPack { manifest.packs[1] }

        init(llmChunkDelay: Duration = .zero, llmBody: Data? = nil) throws {
            let namespace = UUID().uuidString
            directory = try TemporaryDirectory()
            asrWeights = host("asr.bin", data: randomData(count: 300_000, seed: 41), namespace: namespace)
            asrVAD = host("vad.bin", data: randomData(count: 20_000, seed: 42), namespace: namespace)
            let llmData = randomData(count: 1_500_000, seed: 43)
            llm = host("llm.gguf", data: llmBody ?? llmData, namespace: namespace, pinnedData: llmData,
                       chunkSize: llmChunkDelay > .zero ? 8 * 1024 : 64 * 1024, chunkDelay: llmChunkDelay)
            manifest = ModelManifest(manifestVersion: 1, packs: [
                makePack("asr-\(namespace)", role: .asr, files: [asrWeights, asrVAD]),
                makePack("llm-\(namespace)", role: .llm, files: [llm]),
            ])
        }

        func manager(
            device: DeviceProfile = .iPhone8GB,
            appVersion: String = testAppVersion,
            capacity: Int64 = 1 << 50,
            clock: AgentClock = AgentClock(),
            logger: PrivacySafeLogger = .shared
        ) -> ModelManager {
            ModelManager(
                manifest: manifest,
                downloader: makeDownloader(root: directory.url, capacity: capacity, appVersion: appVersion, clock: clock, logger: logger),
                device: device,
                logger: logger
            )
        }
    }

    // MARK: Install

    @Test func installPublishesEveryLifecycleState() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager()
        let pack = fixture.asrPack
        let snapshots = Recorder<[ModelPackStatus]>()
        let recording = snapshots.start(await manager.statusUpdates(bufferingPolicy: .unbounded))
        defer { recording.cancel() }

        try await manager.install(packID: pack.id)

        let final = try #require(await manager.status(ofPack: pack.id))
        #expect(final.state == .installed(revision: pack.revision))
        #expect(final.downloadedBytes == pack.totalBytes && final.fractionCompleted == 1)
        #expect(final.errorMessage == nil && final.isReady)
        #expect(final.displayName == pack.displayName && final.totalBytes == 320_000 && final.role == .asr)

        #expect(await eventually { state(snapshots.all.last ?? [], pack.id)?.isInstalled == true })
        let states = snapshots.all.compactMap { state($0, pack.id) }
        func firstIndex(_ matches: (ModelPackState) -> Bool) -> Int? { states.firstIndex(where: matches) }
        let queued = try #require(firstIndex { $0 == .queued })
        let downloading = try #require(firstIndex { if case .downloading = $0 { true } else { false } })
        let verifying = try #require(firstIndex { if case .verifying = $0 { true } else { false } })
        let installed = try #require(firstIndex { $0.isInstalled })
        #expect(states.first == .notInstalled)
        #expect(queued < downloading && downloading < verifying && verifying < installed)
        #expect(await !manager.isReady, "the language model is still missing")
    }

    @Test func installAllRunsOnePackAtATime() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager()
        let snapshots = Recorder<[ModelPackStatus]>()
        let recording = snapshots.start(await manager.statusUpdates(bufferingPolicy: .unbounded))
        defer { recording.cancel() }

        try await manager.installAll()

        #expect(await manager.isReady)
        #expect(await eventually { (snapshots.all.last ?? []).allSatisfy(\.isReady) })
        for snapshot in snapshots.all {
            #expect(snapshot.filter { if case .downloading = $0.state { true } else if case .verifying = $0.state { true } else { false } }.count <= 1)
        }
        // Idempotent: nothing is downloaded again.
        try await manager.installAll()
        #expect(fixture.llm.resource.requests.count == 1)
    }

    @Test func pauseKeepsTheDownloadAndResumeContinuesIt() async throws {
        let fixture = try Fixture(llmChunkDelay: .milliseconds(3))
        let manager = fixture.manager()
        let pack = fixture.llmPack
        let updates = await manager.statusUpdates(bufferingPolicy: .unbounded)

        let job = try await manager.startInstall(packID: pack.id)
        _ = try await firstValue(of: updates) { isDownloadingWithBytes($0, pack.id) }
        await manager.pause(packID: pack.id)
        await #expect(throws: ModelDownloadError.paused) { try await job.value }

        let paused = try #require(await manager.status(ofPack: pack.id))
        guard case let .paused(bytes) = paused.state else {
            Issue.record("expected paused, got \(paused.state)")
            return
        }
        #expect(bytes > 0 && bytes < pack.totalBytes)
        #expect(paused.downloadedBytes == bytes)

        fixture.llm.resource.setChunkDelay(.zero)
        try await manager.resume(packID: pack.id).value
        #expect(await manager.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(fixture.llm.resource.requests.map(\.range) == [nil, "bytes=\(bytes)-"])
    }

    @Test func cancelKeepsThePartialAndReportsNotInstalled() async throws {
        let fixture = try Fixture(llmChunkDelay: .milliseconds(3))
        let manager = fixture.manager()
        let pack = fixture.llmPack
        let updates = await manager.statusUpdates(bufferingPolicy: .unbounded)

        let job = try await manager.startInstall(packID: pack.id)
        _ = try await firstValue(of: updates) { isDownloadingWithBytes($0, pack.id) }
        await manager.cancel(packID: pack.id)
        await #expect(throws: ModelDownloadError.cancelled) { try await job.value }

        let status = try #require(await manager.status(ofPack: pack.id))
        #expect(status.state == .notInstalled)
        #expect(status.downloadedBytes > 0 && status.downloadedBytes < pack.totalBytes)

        fixture.llm.resource.setChunkDelay(.zero)
        try await manager.install(packID: pack.id)
        #expect(fixture.llm.resource.requests.last?.range == "bytes=\(status.downloadedBytes)-")
    }

    @Test func deleteAndReDownload() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager()
        let pack = fixture.asrPack
        try await manager.install(packID: pack.id)

        try await manager.delete(packID: pack.id)
        let deleted = try #require(await manager.status(ofPack: pack.id))
        #expect(deleted.state == .notInstalled && deleted.downloadedBytes == 0)
        #expect(!fileExists(manager.downloader.layout.packDirectory(pack.id)))
        await #expect(throws: ModelManagerError.notInstalled(packID: pack.id)) {
            try await manager.verifiedFileURL(pack: pack.id, file: "asr.bin")
        }

        try await manager.redownload(packID: pack.id)
        #expect(await manager.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(fixture.asrWeights.resource.requests.count == 2)
    }

    // MARK: Launch reconciliation

    @Test func reconciliationCountsPartialDownloads() async throws {
        let fixture = try Fixture()
        let pack = fixture.llmPack
        let manager = fixture.manager()
        let layout = manager.downloader.layout
        try FileManager.default.createDirectory(at: layout.partialDirectory, withIntermediateDirectories: true)
        try fixture.llm.data.prefix(400_000).write(to: layout.partialURL(sha256: fixture.llm.pin.sha256))

        let statuses = await manager.reconcileOnLaunch(resumeInterruptedDownloads: false)

        let status = try #require(statuses.first { $0.id == pack.id })
        #expect(status.state == .notInstalled)
        #expect(status.downloadedBytes == 400_000)
        try await manager.install(packID: pack.id)
        #expect(fixture.llm.resource.requests.map(\.range) == ["bytes=400000-"])
    }

    @Test func reconciliationResumesDownloadsInterruptedByTermination() async throws {
        let fixture = try Fixture(llmChunkDelay: .milliseconds(3))
        let pack = fixture.llmPack
        let first = fixture.manager()
        let updates = await first.statusUpdates(bufferingPolicy: .unbounded)
        let job = try await first.startInstall(packID: pack.id)
        _ = try await firstValue(of: updates) { isDownloadingWithBytes($0, pack.id) }
        // The process "dies": the transfer stops without the user pausing or cancelling.
        await first.downloader.cancel(packID: pack.id)
        _ = await job.result

        fixture.llm.resource.setChunkDelay(.zero)
        let relaunched = fixture.manager()
        let statuses = await relaunched.reconcileOnLaunch()
        #expect(statuses.first { $0.id == pack.id }?.state == .queued)
        try await relaunched.install(packID: pack.id) // joins the resumed job
        #expect(await relaunched.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(fixture.llm.resource.requests.last?.range?.hasPrefix("bytes=") == true)
    }

    @Test func pausedDownloadsStayPausedAcrossLaunches() async throws {
        let fixture = try Fixture(llmChunkDelay: .milliseconds(3))
        let pack = fixture.llmPack
        let first = fixture.manager()
        let updates = await first.statusUpdates(bufferingPolicy: .unbounded)
        let job = try await first.startInstall(packID: pack.id)
        _ = try await firstValue(of: updates) { isDownloadingWithBytes($0, pack.id) }
        await first.pause(packID: pack.id)
        _ = await job.result

        let relaunched = fixture.manager()
        let statuses = await relaunched.reconcileOnLaunch()
        guard case let .paused(bytes)? = statuses.first(where: { $0.id == pack.id })?.state else {
            Issue.record("expected the pack to stay paused")
            return
        }
        #expect(bytes > 0)
        #expect(fixture.llm.resource.requests.count == 1, "nothing resumed on its own")
    }

    @Test func reconciliationReportsAMissingFileAsCorruptAndInstallRepairsIt() async throws {
        let fixture = try Fixture()
        let pack = fixture.asrPack
        try await fixture.manager().install(packID: pack.id)
        let layout = ModelStorageLayout(root: fixture.directory.url)
        try FileManager.default.removeItem(at: layout.fileURL(packID: pack.id, revision: pack.revision, filename: "vad.bin"))

        let relaunched = fixture.manager()
        let status = try #require(await relaunched.reconcileOnLaunch().first { $0.id == pack.id })
        #expect(status.state == .corrupt)
        #expect(status.errorMessage == "Model files are damaged or missing. Re-download to repair.")
        await #expect(throws: ModelManagerError.corrupt(packID: pack.id)) {
            try await relaunched.verifiedFileURL(pack: pack.id, file: "asr.bin")
        }

        try await relaunched.install(packID: pack.id)
        #expect(await relaunched.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(fixture.asrWeights.resource.requests.count == 1, "the intact file was kept")
        #expect(fixture.asrVAD.resource.requests.count == 2, "only the missing file was downloaded again")
    }

    @Test func reconciliationReportsACorruptedFile() async throws {
        let fixture = try Fixture()
        let pack = fixture.asrPack
        try await fixture.manager().install(packID: pack.id)
        let layout = ModelStorageLayout(root: fixture.directory.url)
        try corruptInPlace(layout.fileURL(packID: pack.id, revision: pack.revision, filename: "asr.bin"))

        let relaunched = fixture.manager()
        let snapshots = Recorder<[ModelPackStatus]>()
        let recording = snapshots.start(await relaunched.statusUpdates(bufferingPolicy: .unbounded))
        defer { recording.cancel() }
        let status = try #require(await relaunched.reconcileOnLaunch().first { $0.id == pack.id })

        #expect(status.state == .corrupt)
        #expect(await eventually { snapshots.all.contains { if case .verifying? = state($0, pack.id) { true } else { false } } })
        await #expect(throws: ModelManagerError.corrupt(packID: pack.id)) {
            try await relaunched.verifiedFileURL(pack: pack.id, file: "vad.bin")
        }
    }

    @Test func anAppUpdateTriggersAFullReHashBeforeUse() async throws {
        let fixture = try Fixture()
        let pack = fixture.asrPack
        try await fixture.manager(appVersion: "1.0.0 (1)").install(packID: pack.id)

        let updated = fixture.manager(appVersion: "1.0.1 (2)")
        let snapshots = Recorder<[ModelPackStatus]>()
        let recording = snapshots.start(await updated.statusUpdates(bufferingPolicy: .unbounded))
        defer { recording.cancel() }
        let status = try #require(await updated.reconcileOnLaunch().first { $0.id == pack.id })

        #expect(status.state == .installed(revision: pack.revision))
        #expect(await eventually { snapshots.all.contains { if case .verifying? = state($0, pack.id) { true } else { false } } })
        let ledger = try readLedger(updated.downloader.layout, packID: pack.id, revision: pack.revision)
        #expect(ledger.records.values.allSatisfy { $0.appVersion == "1.0.1 (2)" })
    }

    @Test func unknownFilesAreIgnoredAndOtherFamiliesAreNeverActivated() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager()
        let layout = manager.downloader.layout
        try await manager.install(packID: fixture.asrPack.id)

        // Unknown content in the store is left alone.
        let unknown = layout.root.appending(path: "some-other-model")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: unknown.appending(path: "weights.bin"))
        try Data("y".utf8).write(to: layout.root.appending(path: "README.txt"))

        // The ASR pack's activation record is rewritten to claim another role (model family).
        let record = try readActiveRecord(layout, packID: fixture.asrPack.id)
        let swapped = ActivationRecord(packID: record.packID, role: .llm, revision: record.revision, files: record.files,
                                       activatedAt: record.activatedAt, appVersion: record.appVersion, previous: nil)
        try JSONEncoder().encode(swapped).write(to: layout.activationRecordURL(packID: fixture.asrPack.id))

        // A different revision of the LLM pack (same family, other content) is active.
        let other = host("llm.gguf", data: randomData(count: 50_000, seed: 44))
        let otherRevision = makePack(fixture.llmPack.id, role: .llm, files: [other])
        try await manager.downloader.install(otherRevision)

        let relaunched = fixture.manager()
        let statuses = await relaunched.reconcileOnLaunch(resumeInterruptedDownloads: false)
        let asr = try #require(statuses.first { $0.id == fixture.asrPack.id })
        let llm = try #require(statuses.first { $0.id == fixture.llmPack.id })

        #expect(asr.state == .notInstalled && asr.staleRevision == nil)
        #expect(llm.state == .notInstalled && llm.staleRevision == otherRevision.revision)
        await #expect(throws: ModelManagerError.notInstalled(packID: fixture.asrPack.id)) {
            try await relaunched.verifiedFileURL(pack: fixture.asrPack.id, file: "asr.bin")
        }
        await #expect(throws: ModelManagerError.notInstalled(packID: fixture.llmPack.id)) {
            try await relaunched.verifiedFileURL(pack: fixture.llmPack.id, file: "llm.gguf")
        }
        #expect(fileExists(unknown.appending(path: "weights.bin")))
        #expect(fileExists(layout.root.appending(path: "README.txt")))
        #expect(fileExists(layout.fileURL(packID: fixture.asrPack.id, revision: fixture.asrPack.revision, filename: "asr.bin")))
    }

    @Test func thePinnedRevisionIsReactivatedWhenItIsTheRollbackTarget() async throws {
        let fixture = try Fixture()
        let pinned = fixture.llmPack
        let manager = fixture.manager()
        try await manager.install(packID: pinned.id)
        // A newer build activated another revision; this build pins the earlier one.
        let newer = makePack(pinned.id, role: .llm, files: [host("llm.gguf", data: randomData(count: 60_000, seed: 45))])
        try await manager.downloader.install(newer)

        let relaunched = fixture.manager()
        let status = try #require(await relaunched.reconcileOnLaunch().first { $0.id == pinned.id })

        #expect(status.state == .installed(revision: pinned.revision))
        let url = try await relaunched.verifiedFileURL(pack: pinned.id, file: "llm.gguf")
        #expect(try Data(contentsOf: url) == fixture.llm.data)
    }

    // MARK: Device, errors, runtime access

    @Test func unsupportedDevicesCannotInstall() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager(device: .iPhone6GB)
        let pack = fixture.llmPack

        #expect(!manager.deviceRequirements().isSupported)
        await #expect(throws: ModelManagerError.deviceNotSupported([.insufficientMemory(requiredGB: 7.5, installedGB: 5.9)])) {
            try await manager.install(packID: pack.id)
        }
        let status = try #require(await manager.status(ofPack: pack.id))
        #expect(status.state == .failed(.deviceNotSupported([.insufficientMemory(requiredGB: 7.5, installedGB: 5.9)])))
        #expect(status.errorMessage == "Needs an iPhone with at least 8 GB of memory.")
        #expect(fixture.llm.resource.requests.isEmpty)
    }

    @Test func failuresCarryShortUserMessages() async throws {
        let full = try Fixture()
        let noSpace = full.manager(capacity: 1_000)
        await #expect(throws: ModelDownloadError.self) { try await noSpace.install(packID: full.llmPack.id) }
        let storage = try #require(await noSpace.status(ofPack: full.llmPack.id))
        guard case .failed(.insufficientStorage) = storage.state else {
            Issue.record("expected an insufficient-storage failure, got \(storage.state)")
            return
        }
        #expect(storage.errorMessage?.hasPrefix("Not enough free space. Free up ") == true)

        let damaged = try Fixture(llmBody: randomData(count: 1_500_000, seed: 46))
        let manager = damaged.manager()
        await #expect(throws: ModelDownloadError.self) { try await manager.install(packID: damaged.llmPack.id) }
        let status = try #require(await manager.status(ofPack: damaged.llmPack.id))
        #expect(status.state == .failed(.integrity))
        #expect(status.errorMessage == "The download was damaged and has been discarded. Try again.")
    }

    @Test func runtimesGetVerifiedURLsOnly() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager()
        try await manager.install(packID: fixture.asrPack.id)

        let urls = try await manager.verifiedFileURLs(for: .asr)
        #expect(Set(urls.keys) == ["asr.bin", "vad.bin"])
        #expect(try Data(contentsOf: try #require(urls["vad.bin"])) == fixture.asrVAD.data)
        await #expect(throws: ModelManagerError.noPackForRole(.tts)) { try await manager.verifiedFileURLs(for: .tts) }
        await #expect(throws: ModelManagerError.notInstalled(packID: fixture.llmPack.id)) {
            try await manager.verifiedFileURL(pack: fixture.llmPack.id, file: "llm.gguf")
        }
        await #expect(throws: ModelManagerError.unknownPack("nope")) { try await manager.verifiedFileURL(pack: "nope", file: "x") }
        await #expect(throws: ModelManagerError.unknownFile(packID: fixture.asrPack.id, filename: "x")) {
            try await manager.verifiedFileURL(pack: fixture.asrPack.id, file: "x")
        }

        // A file modified after installation is refused and the pack is marked corrupt.
        try corruptInPlace(try #require(urls["asr.bin"]))
        await #expect(throws: ModelManagerError.corrupt(packID: fixture.asrPack.id)) {
            try await manager.verifiedFileURL(pack: fixture.asrPack.id, file: "asr.bin")
        }
        #expect(await manager.status(ofPack: fixture.asrPack.id)?.state == .corrupt)
    }

    @Test func storageUsageReportsBytesPerPackAndFreeSpace() async throws {
        let fixture = try Fixture()
        let manager = fixture.manager(capacity: 64_000_000_000)
        try await manager.install(packID: fixture.asrPack.id)

        let usage = await manager.storageUsage()
        #expect(usage.packs.map(\.id) == [fixture.asrPack.id, fixture.llmPack.id])
        #expect(usage.packs[0].activeBytes == 320_000 && usage.packs[0].inactiveBytes == 0 && usage.packs[0].partialBytes == 0)
        #expect(usage.packs[1].totalBytes == 0)
        #expect(usage.availableBytes == 64_000_000_000)
    }

    @Test func logsContainOnlyContentFreeDownloadEvents() async throws {
        let fixture = try Fixture()
        let logger = PrivacySafeLogger()
        let events = Recorder<TelemetryEvent>()
        logger.addSink { events.record($0.event) }
        let manager = fixture.manager(logger: logger)

        try await manager.install(packID: fixture.asrPack.id)
        try await manager.delete(packID: fixture.asrPack.id)

        let lines = events.all.map(\.renderedLine)
        #expect(lines.contains("download asr queued"))
        #expect(lines.contains("download asr started bytes=320000"))
        #expect(lines.contains("download asr activated bytes=320000"))
        #expect(lines.contains("download asr deleted"))
        for event in events.all {
            guard case .download = event else {
                Issue.record("unexpected event \(event.renderedLine)")
                continue
            }
        }
        #expect(lines.allSatisfy { !$0.contains("stub") && !$0.contains(".bin") && !$0.contains(fixture.asrPack.id) })
    }
}
