import Core
import CryptoKit
import Foundation
import Models
import Testing

@Suite("Model integrity", .timeLimit(.minutes(2)))
struct ModelIntegrityTests {
    private func write(_ data: Data, in directory: TemporaryDirectory, name: String = "model.bin") throws -> URL {
        let url = directory.url.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func pin(for data: Data, name: String = "model.bin") -> ModelFile {
        ModelFile(filename: name, sourceURL: URL(string: "https://example.com/\(name)")!, repository: "test/repo",
                  revision: fakeCommit(1), bytes: Int64(data.count), sha256: sha256Hex(data))
    }

    @Test func streamingHashEqualsOneShotHash() async throws {
        let directory = try TemporaryDirectory()
        // 10 MB + 123 bytes: spans several 4 MB chunks and ends mid-chunk.
        let data = randomData(count: 10 * 1024 * 1024 + 123, seed: 7)
        let url = try write(data, in: directory)
        let expected = sha256Hex(data)
        #expect(try await ModelIntegrity.sha256(of: url) == expected)
        #expect(try await ModelIntegrity.sha256(of: url, chunkSize: 1_000) == expected)
        #expect(try await ModelIntegrity.sha256(of: url, chunkSize: 4 * 1024 * 1024 + 1) == expected)

        let empty = try write(Data(), in: directory, name: "empty.bin")
        #expect(try await ModelIntegrity.sha256(of: empty) == sha256Hex(Data()))
    }

    @Test func hashReportsProgressUpToTheTotal() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 3 * 1024 * 1024 + 5, seed: 8)
        let url = try write(data, in: directory)
        let updates = Recorder<[Int64]>()
        _ = try await ModelIntegrity.sha256(of: url, chunkSize: 1024 * 1024) { processed, total in
            updates.record([processed, total])
        }
        #expect(updates.all == [[1_048_576, 3_145_733], [2_097_152, 3_145_733], [3_145_728, 3_145_733], [3_145_733, 3_145_733]])
    }

    @Test func hashIsCancellable() async throws {
        let directory = try TemporaryDirectory()
        let url = try write(randomData(count: 8 * 1024 * 1024, seed: 9), in: directory)
        let task = Task { try await ModelIntegrity.sha256(of: url, chunkSize: 4096) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func missingFilesAreReportedAsMissing() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "nope.bin")
        await #expect(throws: ModelIntegrityError.fileMissing) { try await ModelIntegrity.sha256(of: url) }
    }

    @Test func verifyReturnsARecordOfTheVerifiedFile() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 200_000, seed: 10)
        let url = try write(data, in: directory)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

        let record = try await ModelIntegrity.verify(file: url, expected: pin(for: data), appVersion: "2.0 (5)", clock: clock.agentClock)
        let metadata = try FileMetadata.read(url)
        #expect(record.sha256 == sha256Hex(data))
        #expect(record.bytes == 200_000)
        #expect(record.fileNumber == metadata.fileNumber)
        #expect(record.modificationDate == metadata.modificationDate)
        #expect(record.verifiedAt == clock.now)
        #expect(record.appVersion == "2.0 (5)")
    }

    @Test func verifyRejectsWrongContentAndWrongSize() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 50_000, seed: 11)
        let url = try write(data, in: directory)
        let other = randomData(count: 50_000, seed: 12)

        do {
            _ = try await ModelIntegrity.verify(file: url, expected: pin(for: other), appVersion: testAppVersion)
            Issue.record("expected a checksum mismatch")
        } catch let error as ModelIntegrityError {
            #expect(error == .checksumMismatch(expected: sha256Hex(other), actual: sha256Hex(data)))
            #expect(error.isContentMismatch)
        }
        await #expect(throws: ModelIntegrityError.sizeMismatch(expected: 49_999, actual: 50_000)) {
            try await ModelIntegrity.verify(file: url, expected: pin(for: data.prefix(49_999)), appVersion: testAppVersion)
        }
    }

    @Test func quickCheckDetectsSizeInodeAndModificationDateChanges() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 100_000, seed: 13)
        let url = try write(data, in: directory)
        let expected = pin(for: data)
        let policy = IntegrityPolicy(appVersion: testAppVersion)
        let record = try await ModelIntegrity.verify(file: url, expected: expected, appVersion: testAppVersion)
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: Date()) == .valid)

        // mtime changed (same size, same inode)
        try FileManager.default.setAttributes([.modificationDate: record.modificationDate.addingTimeInterval(1)], ofItemAtPath: url.path)
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: Date()) == .needsFullVerification(.metadataChanged))

        // replaced by a different file (new inode) with the original mtime
        let replacement = try write(data, in: directory, name: "replacement.bin")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        try FileManager.default.setAttributes([.modificationDate: record.modificationDate], ofItemAtPath: url.path)
        #expect(try FileMetadata.read(url).fileNumber != record.fileNumber)
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: Date()) == .needsFullVerification(.metadataChanged))

        // size changed: definitely unusable
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: Date()) == .invalid(.sizeMismatch(expected: 100_000, actual: 100_001)))

        // missing
        try FileManager.default.removeItem(at: url)
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: Date()) == .invalid(.fileMissing))
    }

    @Test func policyRequiresAFullReHashWhenDue() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 10_000, seed: 14)
        let url = try write(data, in: directory)
        let expected = pin(for: data)
        let record = try await ModelIntegrity.verify(file: url, expected: expected, appVersion: testAppVersion)
        let policy = IntegrityPolicy(appVersion: testAppVersion)
        let now = record.verifiedAt

        #expect(ModelIntegrity.quickCheck(file: url, record: nil, expected: expected, policy: policy, now: now) == .needsFullVerification(.noRecord))
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: IntegrityPolicy(appVersion: "1.0.1 (2)"), now: now) == .needsFullVerification(.appVersionChanged))
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: now.addingTimeInterval(6 * 86_400)) == .valid)
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: now.addingTimeInterval(7 * 86_400 + 1)) == .needsFullVerification(.expired))
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: IntegrityPolicy(appVersion: testAppVersion, maximumAge: 60), now: now.addingTimeInterval(61)) == .needsFullVerification(.expired))
        #expect(ModelIntegrity.quickCheck(file: url, record: record, expected: expected, policy: policy, now: now.addingTimeInterval(-3 * 86_400)) == .needsFullVerification(.expired), "clock moved back")

        var otherPin = record
        otherPin.sha256 = String(repeating: "0", count: 64)
        #expect(ModelIntegrity.quickCheck(file: url, record: otherPin, expected: expected, policy: policy, now: now) == .needsFullVerification(.pinChanged))
    }

    @Test func validateReHashesOnlyWhenRequiredAndCatchesSilentCorruptionWhenDue() async throws {
        let directory = try TemporaryDirectory()
        let data = randomData(count: 64_000, seed: 15)
        let url = try write(data, in: directory)
        let expected = pin(for: data)
        let clock = TestClock()
        let policy = IntegrityPolicy(appVersion: testAppVersion)

        let first = try await ModelIntegrity.validate(file: url, record: nil, expected: expected, policy: policy, clock: clock.agentClock)
        #expect(first.fullVerificationReason == .noRecord)
        let second = try await ModelIntegrity.validate(file: url, record: first.record, expected: expected, policy: policy, clock: clock.agentClock)
        #expect(second.fullVerificationReason == nil)
        #expect(second.record == first.record)

        // Bit rot: bytes change but size, inode and mtime do not. The quick check cannot see it...
        let metadata = try FileMetadata.read(url)
        try corruptInPlace(url, bumpModificationDate: false)
        try FileManager.default.setAttributes([.modificationDate: metadata.modificationDate], ofItemAtPath: url.path)
        #expect(try await ModelIntegrity.validate(file: url, record: first.record, expected: expected, policy: policy, clock: clock.agentClock).fullVerificationReason == nil)
        // ...the periodic full re-hash does.
        clock.advance(by: 8 * 86_400)
        await #expect(throws: ModelIntegrityError.self) {
            try await ModelIntegrity.validate(file: url, record: first.record, expected: expected, policy: policy, clock: clock.agentClock)
        }
    }
}
