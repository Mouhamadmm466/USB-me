import Core
import Foundation
import Models
import Testing

@Suite("Model download manager", .timeLimit(.minutes(3)))
struct ModelDownloadManagerTests {
    // MARK: Helpers

    private func installedURL(_ downloader: ModelDownloadManager, _ pack: ModelPack, _ filename: String) -> URL {
        downloader.layout.fileURL(packID: pack.id, revision: pack.revision, filename: filename)
    }

    private func seedPartial(_ downloader: ModelDownloadManager, _ file: ModelFile, with data: Data) throws {
        try FileManager.default.createDirectory(at: downloader.layout.partialDirectory, withIntermediateDirectories: true)
        try data.write(to: downloader.layout.partialURL(sha256: file.sha256))
    }

    /// A pack whose first request stalls after 500 KB (the connection stays open), so a transfer
    /// is deterministically still running when the test pauses, cancels or deletes it. Later
    /// requests are served normally.
    private func stalledPack(_ name: String, bytes: Int = 2_000_000, seed: UInt64) -> (HostedFile, ModelPack) {
        let hosted = host("model.bin", data: randomData(count: bytes, seed: seed))
        hosted.resource.setScript([.stallAfter(500_000)])
        return (hosted, makePack("\(name)-\(UUID().uuidString)", files: [hosted]))
    }

    // MARK: Happy path

    @Test func downloadsVerifiesAndActivatesAPack() async throws {
        let directory = try TemporaryDirectory()
        let weights = host("weights.bin", data: randomData(count: 700_000, seed: 1))
        let voice = host("voice.bin", data: randomData(count: 90_000, seed: 2))
        let pack = makePack("pack-\(UUID().uuidString)", role: .tts, files: [weights, voice])
        let downloader = makeDownloader(root: directory.url)
        let events = Recorder<ModelDownloadProgress>()
        let recording = events.start(downloader.progressUpdates())
        defer { recording.cancel() }

        let record = try await downloader.install(pack)

        #expect(record.matches(pack))
        #expect(record.previous == nil)
        #expect(record.appVersion == testAppVersion)
        let layout = downloader.layout
        for hosted in [weights, voice] {
            #expect(try Data(contentsOf: installedURL(downloader, pack, hosted.pin.filename)) == hosted.data)
            #expect(hosted.resource.requests == [.init(range: nil, acceptEncoding: "identity")])
        }
        #expect(try readActiveRecord(layout, packID: pack.id) == record)
        let ledger = try readLedger(layout, packID: pack.id, revision: pack.revision)
        #expect(Set(ledger.records.keys) == ["weights.bin", "voice.bin"])
        #expect(ledger.records["weights.bin"]?.sha256 == weights.pin.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.partialDirectory.path(percentEncoded: false)).isEmpty)
        #expect(await downloader.quickCheckInstallation(of: pack) == .healthy(revision: pack.revision))
        #expect(try await downloader.verifiedFileURL(for: pack, filename: "voice.bin") == installedURL(downloader, pack, "voice.bin"))

        let sawEverything = await eventually {
            let all = events.all.filter { $0.packID == pack.id }
            return all.contains { $0.phase == .downloading && $0.filename == "weights.bin" && $0.fileCompletedBytes == 700_000 }
                && all.contains { $0.phase == .downloading && $0.filename == "voice.bin" && $0.completedBytes == 790_000 }
                && all.contains { $0.phase == .verifying && $0.filename == "voice.bin" && $0.fileCompletedBytes == 90_000 }
        }
        #expect(sawEverything)
        #expect(events.all.filter { $0.packID == pack.id }.allSatisfy { $0.totalBytes == 790_000 && $0.bytesPerSecond >= 0 })

        // Installing again is a no-op: nothing is downloaded or rewritten.
        #expect(try await downloader.install(pack) == record)
        #expect(weights.resource.requests.count == 1)
    }

    @Test func modelDirectoriesAreExcludedFromBackup() async throws {
        let directory = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 10_000, seed: 3))
        let pack = makePack("backup-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        try await downloader.install(pack)
        let layout = downloader.layout
        for url in [layout.root, layout.partialDirectory, layout.packDirectory(pack.id), layout.revisionDirectory(packID: pack.id, revision: pack.revision)] {
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "\(url.lastPathComponent)")
        }
    }

    // MARK: Resume, Range handling

    @Test func interruptedDownloadResumesToAnIdenticalVerifiedFile() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 1_000_000, seed: 4)
        let hosted = host("model.bin", data: data)
        hosted.resource.setScript([.truncateAfter(300_000)])
        let pack = makePack("resume-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)

        try await downloader.install(pack)

        #expect(hosted.resource.requests.map(\.range) == [nil, "bytes=300000-"])
        let installed = installedURL(downloader, pack, "model.bin")
        #expect(try Data(contentsOf: installed) == data)
        #expect(try await ModelIntegrity.sha256(of: installed) == hosted.pin.sha256)
    }

    @Test func serverIgnoringRangeRestartsFromZero() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 600_000, seed: 5)
        let hosted = host("model.bin", data: data)
        hosted.resource.setIgnoresRange(true)
        let pack = makePack("norange-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        // Not a prefix of the real file: appending the 200 response to it could never verify.
        try seedPartial(downloader, hosted.pin, with: randomData(count: 200_000, seed: 50))

        try await downloader.install(pack)

        #expect(hosted.resource.requests.map(\.range) == ["bytes=200000-"])
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == data)
    }

    @Test func rangeNotSatisfiableRevalidatesThenRestarts() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 400_000, seed: 6)
        let hosted = host("model.bin", data: data)
        hosted.resource.setScript([.rangeNotSatisfiable])
        let pack = makePack("416-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        try seedPartial(downloader, hosted.pin, with: data.prefix(100_000))

        try await downloader.install(pack)

        #expect(hosted.resource.requests.map(\.range) == ["bytes=100000-", nil])
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == data)
    }

    @Test func persistentRangeNotSatisfiableFailsWithoutLooping() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 400_000, seed: 7)
        let hosted = host("model.bin", data: data)
        hosted.resource.setScript(Array(repeating: .rangeNotSatisfiable, count: 5))
        let pack = makePack("416x-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        try seedPartial(downloader, hosted.pin, with: data.prefix(100_000))

        await #expect(throws: ModelDownloadError.rangeNotSatisfiable) { try await downloader.install(pack) }
        #expect(hosted.resource.requests.count == 2)
        #expect(await downloader.activeRecord(packID: pack.id) == nil)
    }

    @Test func aContentRangeThatStartsElsewhereRestartsFromZero() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 500_000, seed: 8)
        let hosted = host("model.bin", data: data)
        hosted.resource.setScript([.wrongRangeStart])
        let pack = makePack("badrange-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        try seedPartial(downloader, hosted.pin, with: data.prefix(150_000))

        try await downloader.install(pack)

        #expect(hosted.resource.requests.map(\.range) == ["bytes=150000-", nil])
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == data)
    }

    @Test func aCompletePartialIsVerifiedWithoutAnyRequest() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 300_000, seed: 9)
        let hosted = host("model.bin", data: data)
        let pack = makePack("complete-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        try seedPartial(downloader, hosted.pin, with: data)

        try await downloader.install(pack)

        #expect(hosted.resource.requests.isEmpty)
        #expect(await downloader.quickCheckInstallation(of: pack) == .healthy(revision: pack.revision))
    }

    // MARK: Integrity failures

    @Test func checksumMismatchDiscardsThePartialAndAllowsARetry() async throws {
        let directory = try TemporaryDirectory()
        let good = randomData(count: 300_000, seed: 10)
        let bad = randomData(count: 300_000, seed: 11)
        let hosted = host("model.bin", data: bad, pinnedData: good)
        let pack = makePack("mismatch-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)

        do {
            try await downloader.install(pack)
            Issue.record("a checksum mismatch must fail the install")
        } catch let error as ModelDownloadError {
            #expect(error == .checksumMismatch(filename: "model.bin", expected: sha256Hex(good), actual: sha256Hex(bad)))
            #expect(error.isIntegrityFailure && !error.isTransient)
        }
        #expect(!fileExists(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
        #expect(!fileExists(installedURL(downloader, pack, "model.bin")))
        #expect(!fileExists(downloader.layout.activationRecordURL(packID: pack.id)))

        hosted.resource.setBody(good)
        try await downloader.install(pack)
        #expect(hosted.resource.requests.map(\.range) == [nil, nil], "the retry starts from zero")
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == good)
    }

    @Test func responsesLargerThanThePinAreRejected() async throws {
        let directory = try TemporaryDirectory()
        let pinned = randomData(count: 100_000, seed: 12)
        let hosted = host("model.bin", data: pinned + Data(count: 10), pinnedData: pinned)
        let pack = makePack("oversize-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)

        await #expect(throws: ModelDownloadError.sizeMismatch(filename: "model.bin", expected: 100_000, actual: 100_010)) {
            try await downloader.install(pack)
        }
        #expect(!fileExists(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
    }

    // MARK: Cancel, pause, resume

    @Test func cancellingKeepsThePartialAndTheNextInstallResumes() async throws {
        let directory = try TemporaryDirectory()
        let (hosted, pack) = stalledPack("cancel", seed: 13)
        let downloader = makeDownloader(root: directory.url)
        let progress = downloader.progressUpdates()

        let install = Task { try await downloader.install(pack) }
        _ = try await firstValue(of: progress) { $0.packID == pack.id && $0.fileCompletedBytes > 0 }
        install.cancel()
        await #expect(throws: ModelDownloadError.cancelled) { try await install.value }

        let kept = try #require(fileSize(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
        #expect(kept > 0 && kept < 2_000_000)
        #expect(await downloader.activeRecord(packID: pack.id) == nil)
        #expect(await downloader.downloadedBytes(for: pack) == kept)

        try await downloader.install(pack)
        #expect(hosted.resource.requests.last?.range == "bytes=\(kept)-")
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == hosted.data)
    }

    @Test func pauseKeepsThePartialAndResumeContinuesIt() async throws {
        let directory = try TemporaryDirectory()
        let (hosted, pack) = stalledPack("pause", seed: 14)
        let downloader = makeDownloader(root: directory.url)
        let progress = downloader.progressUpdates()

        let install = Task { try await downloader.install(pack) }
        _ = try await firstValue(of: progress) { $0.packID == pack.id && $0.fileCompletedBytes > 0 }
        #expect(await downloader.isBusy(packID: pack.id))
        await downloader.pause(packID: pack.id)
        await #expect(throws: ModelDownloadError.paused) { try await install.value }
        #expect(await !downloader.isBusy(packID: pack.id))

        let kept = try #require(fileSize(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
        #expect(kept > 0 && kept < 2_000_000)

        let record = try await downloader.resume(pack)
        #expect(record.matches(pack))
        #expect(hosted.resource.requests.map(\.range) == [nil, "bytes=\(kept)-"])
    }

    @Test func aPackInstallsOnlyOnceAtATime() async throws {
        let directory = try TemporaryDirectory()
        let (_, pack) = stalledPack("single", seed: 15)
        let downloader = makeDownloader(root: directory.url)
        let progress = downloader.progressUpdates()

        let first = Task { try await downloader.install(pack) }
        _ = try await firstValue(of: progress) { $0.packID == pack.id && $0.fileCompletedBytes > 0 }
        await #expect(throws: ModelDownloadError.alreadyInProgress(packID: pack.id)) { try await downloader.install(pack) }
        await downloader.cancel(packID: pack.id)
        await #expect(throws: ModelDownloadError.cancelled) { try await first.value }
    }

    // MARK: Storage and retries

    @Test func insufficientStorageFailsBeforeAnyRequest() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 250_000, seed: 16)
        let hosted = host("model.bin", data: data)
        let pack = makePack("space-\(UUID().uuidString)", files: [hosted])
        let required = Int64(250_000) + testStorageMargin

        let tooSmall = makeDownloader(root: directory.url, capacity: required - 1)
        await #expect(throws: ModelDownloadError.insufficientStorage(required: required, available: required - 1)) {
            try await tooSmall.install(pack)
        }
        #expect(hosted.resource.requests.isEmpty)

        // Only the bytes still missing count: with half of the file on disk, half the space is enough.
        try seedPartial(tooSmall, hosted.pin, with: data.prefix(125_000))
        let enough = makeDownloader(root: directory.url, capacity: 125_000 + testStorageMargin)
        try await enough.install(pack)
        #expect(hosted.resource.requests.map(\.range) == ["bytes=125000-"])
    }

    @Test func transientFailuresAreRetriedWithBackoff() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 200_000, seed: 17)
        let hosted = host("model.bin", data: data)
        hosted.resource.setScript([.status(503), .failAfter(0), .truncateAfter(1_000), .status(429)])
        let pack = makePack("retry-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)

        try await downloader.install(pack)

        // 503 and a lost connection are retried from zero; the truncated body keeps its 1,000
        // bytes (which also resets the failure streak), so the 429 and the last attempt resume.
        #expect(hosted.resource.requests.map(\.range) == [nil, nil, nil, "bytes=1000-", "bytes=1000-"])
        #expect(try Data(contentsOf: installedURL(downloader, pack, "model.bin")) == data)
    }

    @Test func retriesStopAtTheLimit() async throws {
        let directory = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 10_000, seed: 18))
        hosted.resource.setScript(Array(repeating: .status(503), count: 10))
        let pack = makePack("limit-\(UUID().uuidString)", files: [hosted])
        let retry = RetryPolicy(maxRetries: 2, maxAttempts: 20, initialDelay: .milliseconds(2), multiplier: 2, maxDelay: .milliseconds(10), jitter: 0)
        let downloader = makeDownloader(root: directory.url, retry: retry)

        await #expect(throws: ModelDownloadError.httpStatus(503)) { try await downloader.install(pack) }
        #expect(hosted.resource.requests.count == 3)
    }

    @Test func permanentHTTPErrorsAreNotRetried() async throws {
        let directory = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 10_000, seed: 19))
        hosted.resource.setScript([.status(404)])
        let pack = makePack("404-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)

        await #expect(throws: ModelDownloadError.httpStatus(404)) { try await downloader.install(pack) }
        #expect(hosted.resource.requests.count == 1)
    }

    @Test func backoffGrowsExponentiallyUpToTheCap() {
        let policy = RetryPolicy(maxRetries: 5, initialDelay: .seconds(1), multiplier: 2, maxDelay: .seconds(30), jitter: 0)
        #expect((1...7).map { policy.delay(afterFailure: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
        let jittered = RetryPolicy(initialDelay: .seconds(10), jitter: 0.2).delay(afterFailure: 1)
        #expect(jittered >= .seconds(8) && jittered <= .seconds(12))
    }

    // MARK: Activation, rollback, delete

    @Test func activationIsAtomicForConcurrentReaders() async throws {
        let directory = try TemporaryDirectory()
        let id = "atomic-\(UUID().uuidString)"
        let r1 = makePack(id, files: [host("model.bin", data: randomData(count: 120_000, seed: 20))])
        let r2 = makePack(id, files: [host("model.bin", data: randomData(count: 130_000, seed: 21))])
        let downloader = makeDownloader(root: directory.url)
        try await downloader.install(r1)
        try await downloader.install(r2)
        let layout = downloader.layout
        let packs = [r1.revision: r1, r2.revision: r2]
        let done = Flag()
        let reads = Recorder<Bool>()

        // Reader: every observation of active.json must decode and name a complete revision.
        let reader = Task.detached { () -> Int in
            let decoder = JSONDecoder()
            var violations = 0
            while !done.isSet {
                let consistent: Bool = if let data = try? Data(contentsOf: layout.activationRecordURL(packID: id)),
                                          let record = try? decoder.decode(ActivationRecord.self, from: data),
                                          let pack = packs[record.revision], record.matches(pack) {
                    pack.files.allSatisfy { fileSize(layout.fileURL(packID: id, revision: record.revision, filename: $0.filename)) == $0.bytes }
                } else {
                    false
                }
                if !consistent { violations += 1 }
                reads.record(consistent)
                await Task.yield()
            }
            return violations
        }
        #expect(await eventually { !reads.all.isEmpty }, "the reader is running before activations start")
        for _ in 0..<40 {
            try await downloader.rollback(packID: id)
            await Task.yield()
        }
        done.set()
        let violations = await reader.value
        #expect(reads.all.count > 1)
        #expect(violations == 0)
        #expect(try readActiveRecord(layout, packID: id).revision == r2.revision)
        let names = try FileManager.default.contentsOfDirectory(atPath: layout.packDirectory(id).path(percentEncoded: false))
        #expect(names.allSatisfy { !$0.contains(".tmp-") }, "no temporary files are left behind")
    }

    @Test func anInterruptedActivationLeavesThePreviousRevisionActive() async throws {
        let directory = try TemporaryDirectory()
        let id = "crash-\(UUID().uuidString)"
        let r1 = makePack(id, files: [host("model.bin", data: randomData(count: 100_000, seed: 22))])
        let r2Hosted = host("model.bin", data: randomData(count: 110_000, seed: 23))
        let r2 = makePack(id, files: [r2Hosted])
        let downloader = makeDownloader(root: directory.url)
        let layout = downloader.layout
        try await downloader.install(r1)

        // Crash after r2's file was verified and moved into place, before active.json was replaced,
        // with a half-written temporary activation record left behind.
        try FileManager.default.createDirectory(at: layout.revisionDirectory(packID: id, revision: r2.revision), withIntermediateDirectories: true)
        try r2Hosted.data.write(to: layout.fileURL(packID: id, revision: r2.revision, filename: "model.bin"))
        try Data("{\"packID\": \"half".utf8).write(to: layout.packDirectory(id).appending(path: ".active.json.tmp-CRASHED"))

        #expect(try readActiveRecord(layout, packID: id).revision == r1.revision)
        #expect(await downloader.quickCheckInstallation(of: r1) == .healthy(revision: r1.revision))
        #expect(await downloader.quickCheckInstallation(of: r2) == .notInstalled)

        // Installing r2 verifies the file already in place instead of downloading it.
        let record = try await downloader.install(r2)
        #expect(r2Hosted.resource.requests.isEmpty)
        #expect(record.revision == r2.revision && record.previous?.revision == r1.revision)
        #expect(!fileExists(layout.packDirectory(id).appending(path: ".active.json.tmp-CRASHED")))
    }

    @Test func rollbackRestoresThePreviousRevisionAndOlderOnesArePruned() async throws {
        let directory = try TemporaryDirectory()
        let id = "rollback-\(UUID().uuidString)"
        let r1 = makePack(id, files: [host("model.bin", data: randomData(count: 100_000, seed: 24))])
        let r2 = makePack(id, files: [host("model.bin", data: randomData(count: 101_000, seed: 25))])
        let r3 = makePack(id, files: [host("model.bin", data: randomData(count: 102_000, seed: 26))])
        let downloader = makeDownloader(root: directory.url)
        let layout = downloader.layout

        try await downloader.install(r1)
        let second = try await downloader.install(r2)
        #expect(second.previous?.revision == r1.revision)
        #expect(fileExists(layout.revisionDirectory(packID: id, revision: r1.revision)), "the previous revision is kept")

        let rolledBack = try await downloader.rollback(packID: id)
        #expect(rolledBack.matches(r1))
        #expect(rolledBack.previous?.revision == r2.revision, "a rollback can itself be undone")
        #expect(try await downloader.verifiedFileURL(for: r1, filename: "model.bin") == layout.fileURL(packID: id, revision: r1.revision, filename: "model.bin"))
        await #expect(throws: ModelDownloadError.notInstalled(packID: id)) {
            try await downloader.verifiedFileURL(for: r2, filename: "model.bin")
        }

        let third = try await downloader.install(r3)
        #expect(third.revision == r3.revision && third.previous?.revision == r1.revision)
        #expect(fileExists(layout.revisionDirectory(packID: id, revision: r1.revision)))
        #expect(!fileExists(layout.revisionDirectory(packID: id, revision: r2.revision)), "older revisions are removed after activation")
    }

    @Test func rollbackRefusesAMissingOrDamagedPreviousRevision() async throws {
        let directory = try TemporaryDirectory()
        let id = "norollback-\(UUID().uuidString)"
        let r1 = makePack(id, files: [host("model.bin", data: randomData(count: 90_000, seed: 27))])
        let r2 = makePack(id, files: [host("model.bin", data: randomData(count: 91_000, seed: 28))])
        let downloader = makeDownloader(root: directory.url)

        try await downloader.install(r1)
        await #expect(throws: ModelDownloadError.rollbackUnavailable(packID: id)) { try await downloader.rollback(packID: id) }

        try await downloader.install(r2)
        try corruptInPlace(downloader.layout.fileURL(packID: id, revision: r1.revision, filename: "model.bin"))
        await #expect(throws: ModelDownloadError.rollbackUnavailable(packID: id)) { try await downloader.rollback(packID: id) }
        #expect(try readActiveRecord(downloader.layout, packID: id).revision == r2.revision)
    }

    @Test func deleteRemovesEverythingAndReDownloadWorks() async throws {
        let directory = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 150_000, seed: 29))
        let pack = makePack("delete-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url)
        let layout = downloader.layout
        try await downloader.install(pack)
        try seedPartial(downloader, hosted.pin, with: Data(count: 10))

        try await downloader.delete(pack)

        #expect(!fileExists(layout.packDirectory(pack.id)))
        #expect(!fileExists(layout.partialURL(sha256: hosted.pin.sha256)))
        #expect(await downloader.activeRecord(packID: pack.id) == nil)
        #expect(await downloader.quickCheckInstallation(of: pack) == .notInstalled)
        #expect(await downloader.downloadedBytes(for: pack) == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: layout.trashDirectory.path(percentEncoded: false)))?.isEmpty ?? true)

        try await downloader.install(pack)
        #expect(hosted.resource.requests.map(\.range) == [nil, nil])
        #expect(await downloader.quickCheckInstallation(of: pack) == .healthy(revision: pack.revision))
    }

    @Test func deleteStopsARunningDownload() async throws {
        let directory = try TemporaryDirectory()
        let (hosted, pack) = stalledPack("delete-running", seed: 30)
        let downloader = makeDownloader(root: directory.url)
        let progress = downloader.progressUpdates()

        let install = Task { try await downloader.install(pack) }
        _ = try await firstValue(of: progress) { $0.packID == pack.id && $0.fileCompletedBytes > 0 }
        try await downloader.delete(pack)

        await #expect(throws: ModelDownloadError.cancelled) { try await install.value }
        #expect(!fileExists(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
        #expect(!fileExists(downloader.layout.packDirectory(pack.id)))
    }

    // MARK: Load-time integrity, housekeeping

    @Test func verifiedFileURLAppliesTheIntegrityPolicy() async throws {
        let directory = try TemporaryDirectory()
        let clock = TestClock()
        let hosted = host("model.bin", data: randomData(count: 120_000, seed: 31))
        let pack = makePack("policy-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: directory.url, clock: clock.agentClock)
        let layout = downloader.layout
        try await downloader.install(pack)
        let installedAt = try #require(try readLedger(layout, packID: pack.id, revision: pack.revision).records["model.bin"])

        _ = try await downloader.verifiedFileURL(for: pack, filename: "model.bin")
        #expect(try readLedger(layout, packID: pack.id, revision: pack.revision).records["model.bin"] == installedAt, "quick check only")

        clock.advance(by: 8 * 86_400)
        _ = try await downloader.verifiedFileURL(for: pack, filename: "model.bin")
        #expect(try readLedger(layout, packID: pack.id, revision: pack.revision).records["model.bin"]?.verifiedAt == clock.now, "re-hashed after 7 days")

        try corruptInPlace(installedURL(downloader, pack, "model.bin"))
        do {
            _ = try await downloader.verifiedFileURL(for: pack, filename: "model.bin")
            Issue.record("a modified file must not be handed out")
        } catch let error as ModelDownloadError {
            #expect(error.isIntegrityFailure)
        }
        #expect(await downloader.quickCheckInstallation(of: pack) == .needsFullVerification(revision: pack.revision))
        #expect(await downloader.verifyInstallation(of: pack) == .corrupt(revision: pack.revision, filenames: ["model.bin"]))
    }

    @Test func orphanedPartialsAreRemovedAndUnknownFilesAreLeftAlone() async throws {
        let directory = try TemporaryDirectory()
        let downloader = makeDownloader(root: directory.url)
        let layout = downloader.layout
        try await downloader.prepareStorage()
        let orphan = layout.partialURL(sha256: String(repeating: "a", count: 64))
        let referenced = layout.partialURL(sha256: String(repeating: "b", count: 64))
        try Data(count: 1_234).write(to: orphan)
        try Data(count: 10).write(to: referenced)
        let unknownDirectory = layout.root.appending(path: "someone-else")
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unknownDirectory.appending(path: "notes.txt"))
        try Data("x".utf8).write(to: unknownDirectory.appending(path: ".active.json.tmp-OLD"))

        let removed = await downloader.removeOrphanedFiles(keepingPartialsFor: [String(repeating: "b", count: 64)])

        #expect(removed == 1_234)
        #expect(!fileExists(orphan))
        #expect(fileExists(referenced))
        #expect(fileExists(unknownDirectory.appending(path: "notes.txt")))
        #expect(!fileExists(unknownDirectory.appending(path: ".active.json.tmp-OLD")))
    }

    @Test func storageUsageSeparatesActiveInactiveAndPartialBytes() async throws {
        let directory = try TemporaryDirectory()
        let id = "usage-\(UUID().uuidString)"
        let r1 = makePack(id, files: [host("model.bin", data: randomData(count: 120_000, seed: 32))])
        let r2Hosted = host("model.bin", data: randomData(count: 130_000, seed: 33))
        let r2 = makePack(id, files: [r2Hosted])
        let downloader = makeDownloader(root: directory.url, capacity: 9_000_000_000)
        try await downloader.install(r1)
        try await downloader.install(r2)
        try seedPartial(downloader, r2Hosted.pin, with: Data(count: 5_000))

        let usage = await downloader.storageUsage(for: [r2])

        #expect(usage.packs == [ModelStorageUsage.Pack(id: id, displayName: r2.displayName, activeBytes: 130_000, inactiveBytes: 120_000, partialBytes: 5_000)])
        #expect(usage.totalBytes == 255_000)
        #expect(usage.availableBytes == 9_000_000_000)
    }

    @Test func freeSpaceProbeReadsTheVolume() throws {
        let directory = try TemporaryDirectory()
        #expect(try StorageSpace.availableCapacity(for: directory.url.appending(path: "not/created/yet")) > 0)
    }
}
