import Core
import Foundation
import Models
import Testing

@Suite("Offline model import", .timeLimit(.minutes(3)))
struct ModelImportTests {
    private func stage(_ data: Data, named name: String, in directory: TemporaryDirectory) throws -> URL {
        let url = directory.url.appending(path: name)
        try data.write(to: url)
        return url
    }

    // MARK: ModelDownloadManager

    @Test func importMovesTheVerifiedFileAndActivatesTheCompletePack() async throws {
        let root = try TemporaryDirectory()
        let inbox = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 400_000, seed: 61))
        let pack = makePack("import-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: root.url)
        let source = try stage(hosted.data, named: "model.bin", in: inbox)
        let sourceInode = try FileMetadata.read(source).fileNumber
        let events = Recorder<ModelDownloadProgress>()

        let record = try await downloader.importLocalFile(source, pack: pack, file: "model.bin") { events.record($0) }

        let activated = try #require(record)
        #expect(activated.matches(pack))
        let installed = downloader.layout.fileURL(packID: pack.id, revision: pack.revision, filename: "model.bin")
        #expect(!fileExists(source), "moved, not copied")
        #expect(try FileMetadata.read(installed).fileNumber == sourceInode, "same inode: no second copy of the bytes")
        #expect(try Data(contentsOf: installed) == hosted.data)
        #expect(try readActiveRecord(downloader.layout, packID: pack.id) == activated)
        #expect(try readLedger(downloader.layout, packID: pack.id, revision: pack.revision).records["model.bin"]?.sha256 == hosted.pin.sha256)
        #expect(hosted.resource.requests.isEmpty, "no network")
        #expect(events.all.contains { $0.phase == .verifying && $0.fileCompletedBytes == 400_000 })
        #expect(try await downloader.verifiedFileURL(for: pack, filename: "model.bin") == installed)
        #expect(!fileExists(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
    }

    @Test func importCanKeepTheSource() async throws {
        let root = try TemporaryDirectory()
        let inbox = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 150_000, seed: 62))
        let pack = makePack("keep-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: root.url)
        let source = try stage(hosted.data, named: "model.bin", in: inbox)

        let record = try await downloader.importLocalFile(source, pack: pack, file: "model.bin", removeSource: false)

        #expect(record?.matches(pack) == true)
        #expect(try Data(contentsOf: source) == hosted.data, "the source is kept")
        let installed = downloader.layout.fileURL(packID: pack.id, revision: pack.revision, filename: "model.bin")
        #expect(try FileMetadata.read(installed).fileNumber != FileMetadata.read(source).fileNumber)
        #expect(try Data(contentsOf: installed) == hosted.data)
    }

    @Test func aSizeMismatchLeavesTheSourceUntouched() async throws {
        let root = try TemporaryDirectory()
        let inbox = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 100_000, seed: 63))
        let pack = makePack("size-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: root.url)
        let shorter = hosted.data.prefix(99_000)
        let source = try stage(shorter, named: "model.bin", in: inbox)
        let before = try FileMetadata.read(source)

        await #expect(throws: ModelDownloadError.sizeMismatch(filename: "model.bin", expected: 100_000, actual: 99_000)) {
            try await downloader.importLocalFile(source, pack: pack, file: "model.bin")
        }

        #expect(try FileMetadata.read(source) == before)
        #expect(try Data(contentsOf: source) == shorter)
        #expect(await downloader.activeRecord(packID: pack.id) == nil)
        #expect(!fileExists(downloader.layout.fileURL(packID: pack.id, revision: pack.revision, filename: "model.bin")))
    }

    @Test func aHashMismatchLeavesTheSourceUntouched() async throws {
        let root = try TemporaryDirectory()
        let inbox = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 200_000, seed: 64))
        let pack = makePack("hash-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: root.url)
        let impostor = randomData(count: 200_000, seed: 65)

        for removeSource in [true, false] {
            let source = try stage(impostor, named: "model.bin", in: inbox)
            let before = try FileMetadata.read(source)
            do {
                try await downloader.importLocalFile(source, pack: pack, file: "model.bin", removeSource: removeSource)
                Issue.record("a file with the wrong SHA-256 must be rejected")
            } catch let error as ModelDownloadError {
                #expect(error == .checksumMismatch(filename: "model.bin", expected: hosted.pin.sha256, actual: sha256Hex(impostor)))
            }
            #expect(try FileMetadata.read(source) == before, "removeSource: \(removeSource)")
            #expect(try Data(contentsOf: source) == impostor)
            #expect(!fileExists(downloader.layout.partialURL(sha256: hosted.pin.sha256)))
            #expect(!fileExists(downloader.layout.fileURL(packID: pack.id, revision: pack.revision, filename: "model.bin")))
            #expect(await downloader.activeRecord(packID: pack.id) == nil)
        }
    }

    @Test func onlyRegularPinnedFilesAreAccepted() async throws {
        let root = try TemporaryDirectory()
        let inbox = try TemporaryDirectory()
        let hosted = host("model.bin", data: randomData(count: 50_000, seed: 66))
        let pack = makePack("reject-\(UUID().uuidString)", files: [hosted])
        let downloader = makeDownloader(root: root.url)
        let source = try stage(hosted.data, named: "other.bin", in: inbox)

        await #expect(throws: ModelDownloadError.unknownFile(packID: pack.id, filename: "other.bin")) {
            try await downloader.importLocalFile(source, pack: pack, file: "other.bin")
        }
        let link = inbox.url.appending(path: "model.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: ModelDownloadError.invalidImportSource(filename: "model.bin")) {
            try await downloader.importLocalFile(link, pack: pack, file: "model.bin")
        }
        await #expect(throws: ModelDownloadError.invalidImportSource(filename: "model.bin")) {
            try await downloader.importLocalFile(inbox.url.appending(path: "missing.bin"), pack: pack, file: "model.bin")
        }
        #expect(fileExists(source))
    }

    // MARK: ModelManager

    @Test func aPartialPackActivatesWhenItsLastFileIsImported() async throws {
        let fixture = try ModelManagerTests.Fixture()
        let inbox = try TemporaryDirectory()
        let manager = fixture.manager()
        let pack = fixture.asrPack

        let first = try await manager.importLocalFile(try stage(fixture.asrWeights.data, named: "asr.bin", in: inbox), pack: pack.id, file: "asr.bin")
        #expect(first == nil, "one file of the pack is still missing")
        let partial = try #require(await manager.status(ofPack: pack.id))
        #expect(partial.state == .notInstalled)
        #expect(partial.downloadedBytes == 300_000)
        await #expect(throws: ModelManagerError.notInstalled(packID: pack.id)) {
            try await manager.verifiedFileURL(pack: pack.id, file: "asr.bin")
        }

        let second = try await manager.importLocalFile(try stage(fixture.asrVAD.data, named: "vad.bin", in: inbox), pack: pack.id, file: "vad.bin")
        #expect(second?.matches(pack) == true)
        #expect(await manager.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(try Data(contentsOf: try await manager.verifiedFileURL(pack: pack.id, file: "vad.bin")) == fixture.asrVAD.data)
        #expect(fixture.asrWeights.resource.requests.isEmpty && fixture.asrVAD.resource.requests.isEmpty)
    }

    @Test func importedFilesAreNotDownloadedAgain() async throws {
        let fixture = try ModelManagerTests.Fixture()
        let inbox = try TemporaryDirectory()
        let manager = fixture.manager()
        let pack = fixture.asrPack

        _ = try await manager.importLocalFile(try stage(fixture.asrWeights.data, named: "asr.bin", in: inbox), pack: pack.id, file: "asr.bin")
        try await manager.install(packID: pack.id)

        #expect(await manager.status(ofPack: pack.id)?.state == .installed(revision: pack.revision))
        #expect(fixture.asrWeights.resource.requests.isEmpty, "the imported file was reused")
        #expect(fixture.asrVAD.resource.requests.count == 1)
    }

    @Test func importPendingFilesImportsManifestFilesAndIgnoresEverythingElse() async throws {
        let fixture = try ModelManagerTests.Fixture()
        let inbox = try TemporaryDirectory()
        let manager = fixture.manager()
        _ = try stage(fixture.asrWeights.data, named: "asr.bin", in: inbox)
        _ = try stage(fixture.asrVAD.data, named: "vad.bin", in: inbox)
        _ = try stage(fixture.llm.data, named: "llm.gguf", in: inbox)
        let notes = try stage(Data("not a model".utf8), named: "notes.txt", in: inbox)
        let hidden = try stage(Data("x".utf8), named: ".DS_Store", in: inbox)
        try FileManager.default.createDirectory(at: inbox.url.appending(path: "asr.bin.d"), withIntermediateDirectories: true)

        let results = await manager.importPendingFiles(from: inbox.url)

        #expect(Set(results.keys) == ["asr.bin", "vad.bin", "llm.gguf"])
        let asr = try results["asr.bin"]?.get()
        let llm = try results["llm.gguf"]?.get()
        let vad = try results["vad.bin"]?.get()
        #expect(asr?.packID == fixture.asrPack.id && asr?.activated == nil, "imported in name order: the pack is still incomplete")
        #expect(llm?.activated?.matches(fixture.llmPack) == true)
        #expect(vad?.activated?.matches(fixture.asrPack) == true)
        #expect(await manager.isReady)
        #expect(fileExists(notes) && fileExists(hidden), "unknown files are left alone")
        #expect(!fileExists(inbox.url.appending(path: "asr.bin")) && !fileExists(inbox.url.appending(path: "llm.gguf")))
    }

    @Test func importPendingFilesReportsRejectedFilesAndKeepsThem() async throws {
        let fixture = try ModelManagerTests.Fixture()
        let inbox = try TemporaryDirectory()
        let manager = fixture.manager()
        let impostor = randomData(count: 1_500_000, seed: 67)
        let source = try stage(impostor, named: "llm.gguf", in: inbox)
        _ = try stage(Data(count: 10), named: "vad.bin", in: inbox)

        let results = await manager.importPendingFiles(from: inbox.url)

        guard case let .failure(llmError)? = results["llm.gguf"], case let .failure(vadError)? = results["vad.bin"] else {
            Issue.record("both imports must fail: \(results)")
            return
        }
        #expect(llmError as? ModelDownloadError == .checksumMismatch(filename: "llm.gguf", expected: fixture.llm.pin.sha256, actual: sha256Hex(impostor)))
        #expect(vadError as? ModelDownloadError == .sizeMismatch(filename: "vad.bin", expected: 20_000, actual: 10))
        #expect(try Data(contentsOf: source) == impostor, "rejected files stay where they were")
        #expect(await manager.status(ofPack: fixture.llmPack.id)?.state == .notInstalled)
        #expect(await !manager.isReady)
    }

    @Test func managerImportsOnlyManifestPacksAndFiles() async throws {
        let fixture = try ModelManagerTests.Fixture()
        let inbox = try TemporaryDirectory()
        let manager = fixture.manager()
        let source = try stage(fixture.llm.data, named: "llm.gguf", in: inbox)

        await #expect(throws: ModelManagerError.unknownFile(packID: fixture.asrPack.id, filename: "llm.gguf")) {
            try await manager.importLocalFile(source, pack: fixture.asrPack.id, file: "llm.gguf")
        }
        await #expect(throws: ModelManagerError.unknownPack("other-pack")) {
            try await manager.importLocalFile(source, pack: "other-pack", file: "llm.gguf")
        }
        let small = fixture.manager(device: .iPhone6GB)
        await #expect(throws: ModelManagerError.self) {
            try await small.importLocalFile(source, pack: fixture.llmPack.id, file: "llm.gguf")
        }
        #expect(fileExists(source))
    }
}
