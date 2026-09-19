import Core
import CryptoKit
import Foundation
import Telemetry
#if canImport(Darwin)
import Darwin
#endif

// Integrity policy (PRD §12, §18) — see also Docs/MODEL_MANIFEST.md.
//
// 1. Install: every file is streamed through SHA-256 and compared with its pin *before* it is
//    moved into a revision directory. Nothing else can put a file there.
// 2. Every successful full verification writes an `IntegrityRecord` (digest, size, inode, mtime,
//    time, app build) into `<root>/<packID>/<revision>/.integrity.json`.
// 3. Before each load, `quickCheck` stats the file: it must exist, have the pinned size, and still
//    have the size, inode and mtime recorded at the last full verification, under the same pin.
// 4. A full re-hash is required when there is no record, the metadata changed, the app build
//    changed, or the last full verification is older than `IntegrityPolicy.maximumAge` (7 days by
//    default, configurable). The periodic re-hash is what catches silent corruption that leaves
//    metadata untouched.
// 5. Runtimes only ever receive URLs from `ModelManager.verifiedFileURL(pack:file:)`, which runs
//    this policy for the manifest-pinned revision and returns only files that passed.

/// Evidence that one file matched its pin at a point in time.
public struct IntegrityRecord: Codable, Sendable, Equatable {
    /// Lowercase hex SHA-256 computed over the whole file.
    public var sha256: String
    public var bytes: Int64
    /// File-system file number (inode) at verification time.
    public var fileNumber: UInt64
    public var modificationDate: Date
    public var verifiedAt: Date
    /// `AppVersionInfo.integrityStamp` of the build that verified the file.
    public var appVersion: String

    public init(sha256: String, bytes: Int64, fileNumber: UInt64, modificationDate: Date, verifiedAt: Date, appVersion: String) {
        self.sha256 = sha256
        self.bytes = bytes
        self.fileNumber = fileNumber
        self.modificationDate = modificationDate
        self.verifiedAt = verifiedAt
        self.appVersion = appVersion
    }
}

/// What `stat(2)` says about a regular file.
public struct FileMetadata: Sendable, Equatable {
    public let bytes: Int64
    public let fileNumber: UInt64
    public let modificationDate: Date

    public init(bytes: Int64, fileNumber: UInt64, modificationDate: Date) {
        self.bytes = bytes
        self.fileNumber = fileNumber
        self.modificationDate = modificationDate
    }

    /// Timestamps round-trip through JSON as `Double` seconds; anything closer than this is the
    /// same instant. A real modification lands far later than 10 µs after the verified write.
    static let modificationDateTolerance: TimeInterval = 0.000_01

    public static func read(_ url: URL) throws -> FileMetadata {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw ModelIntegrityError.fileMissing }
            throw ModelIntegrityError.unreadable(errno: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ModelIntegrityError.fileMissing }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileMetadata(
            bytes: Int64(info.st_size),
            fileNumber: UInt64(info.st_ino),
            modificationDate: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Unchanged since `record` was written: same size, same inode, same mtime.
    public func matches(_ record: IntegrityRecord) -> Bool {
        bytes == record.bytes
            && fileNumber == record.fileNumber
            && abs(modificationDate.timeIntervalSince(record.modificationDate)) < Self.modificationDateTolerance
    }
}

/// When a file must be fully re-hashed before it may be loaded.
public struct IntegrityPolicy: Sendable, Equatable {
    public static let defaultMaximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// A record older than this requires a full re-hash.
    public var maximumAge: TimeInterval
    /// Stamp of the running build (`AppVersionInfo.integrityStamp`).
    public var appVersion: String
    /// A record dated further in the future than this (the clock moved back) counts as expired.
    public var clockSkewTolerance: TimeInterval

    public init(appVersion: String, maximumAge: TimeInterval = IntegrityPolicy.defaultMaximumAge, clockSkewTolerance: TimeInterval = 24 * 60 * 60) {
        self.appVersion = appVersion
        self.maximumAge = maximumAge
        self.clockSkewTolerance = clockSkewTolerance
    }
}

public enum FullVerificationReason: String, Sendable, Codable, SafeLabelConvertible {
    case noRecord
    /// The record describes different content (the pin changed).
    case pinChanged
    case metadataChanged
    case appVersionChanged
    case expired
}

public enum QuickCheckResult: Sendable, Equatable {
    /// Unchanged since a recent full verification under this build.
    case valid
    /// Plausible, but the policy requires a full re-hash before use.
    case needsFullVerification(FullVerificationReason)
    /// Definitely unusable (missing, wrong size, unreadable).
    case invalid(ModelIntegrityError)
}

public enum ModelIntegrityError: Error, Sendable, Equatable {
    case fileMissing
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    /// Size, inode or mtime changed while the file was being hashed.
    case modifiedDuringVerification
    case unreadable(errno: Int32)

    /// The bytes on disk are not the pinned bytes (as opposed to an I/O problem).
    public var isContentMismatch: Bool {
        switch self {
        case .sizeMismatch, .checksumMismatch: true
        default: false
        }
    }
}

/// Outcome of the load-time policy (`ModelIntegrity.validate`).
public struct IntegrityValidation: Sendable, Equatable {
    public let record: IntegrityRecord
    /// Why a full re-hash ran; nil when the quick check was sufficient.
    public let fullVerificationReason: FullVerificationReason?
}

public enum ModelIntegrity {
    /// Hashing reads this much per step (~4 MB), checking for cancellation in between.
    public static let defaultChunkSize = 4 * 1024 * 1024

    /// Called with (bytes hashed so far, total bytes) after every chunk.
    public typealias ProgressHandler = @Sendable (_ processedBytes: Int64, _ totalBytes: Int64) -> Void

    /// Streaming SHA-256 of a file in constant memory. Runs off any actor, is cancellable between
    /// chunks, and yields between chunks so long hashes do not monopolise a cooperative thread.
    @concurrent
    public static func sha256(of url: URL, chunkSize: Int = ModelIntegrity.defaultChunkSize, progress: ProgressHandler? = nil) async throws -> String {
        precondition(chunkSize > 0, "chunkSize must be positive")
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            throw code == ENOENT || code == ENOTDIR ? ModelIntegrityError.fileMissing : ModelIntegrityError.unreadable(errno: code)
        }
        defer { close(descriptor) }

        var info = stat()
        let totalBytes: Int64 = fstat(descriptor, &info) == 0 ? Int64(info.st_size) : -1
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 64)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var processed: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, buffer.baseAddress, chunkSize)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw ModelIntegrityError.unreadable(errno: code)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            processed += Int64(count)
            progress?(processed, totalBytes)
            await Task.yield()
        }
        return HexEncoding.string(hasher.finalize())
    }

    /// Full verification: size check, streaming SHA-256, and a guarantee that the file did not
    /// change underneath the hash. Returns the record to persist.
    @concurrent
    public static func verify(
        file url: URL,
        expected: ModelFile,
        appVersion: String,
        clock: AgentClock = AgentClock(),
        chunkSize: Int = ModelIntegrity.defaultChunkSize,
        progress: ProgressHandler? = nil
    ) async throws -> IntegrityRecord {
        let before = try FileMetadata.read(url)
        guard before.bytes == expected.bytes else {
            throw ModelIntegrityError.sizeMismatch(expected: expected.bytes, actual: before.bytes)
        }
        let digest = try await sha256(of: url, chunkSize: chunkSize, progress: progress)
        let after = try FileMetadata.read(url)
        guard after == before else { throw ModelIntegrityError.modifiedDuringVerification }
        guard digest == expected.sha256.lowercased() else {
            throw ModelIntegrityError.checksumMismatch(expected: expected.sha256.lowercased(), actual: digest)
        }
        return IntegrityRecord(
            sha256: digest,
            bytes: after.bytes,
            fileNumber: after.fileNumber,
            modificationDate: after.modificationDate,
            verifiedAt: clock.now(),
            appVersion: appVersion
        )
    }

    /// Metadata-only check (a single `stat`). See the policy at the top of this file.
    public static func quickCheck(
        file url: URL,
        record: IntegrityRecord?,
        expected: ModelFile,
        policy: IntegrityPolicy,
        now: Date
    ) -> QuickCheckResult {
        let metadata: FileMetadata
        do {
            metadata = try FileMetadata.read(url)
        } catch let error as ModelIntegrityError {
            return .invalid(error)
        } catch {
            return .invalid(.unreadable(errno: EIO))
        }
        guard metadata.bytes == expected.bytes else {
            return .invalid(.sizeMismatch(expected: expected.bytes, actual: metadata.bytes))
        }
        guard let record else { return .needsFullVerification(.noRecord) }
        guard record.sha256 == expected.sha256.lowercased(), record.bytes == expected.bytes else {
            return .needsFullVerification(.pinChanged)
        }
        guard metadata.matches(record) else { return .needsFullVerification(.metadataChanged) }
        guard record.appVersion == policy.appVersion else { return .needsFullVerification(.appVersionChanged) }
        let age = now.timeIntervalSince(record.verifiedAt)
        guard age <= policy.maximumAge, age >= -policy.clockSkewTolerance else {
            return .needsFullVerification(.expired)
        }
        return .valid
    }

    /// The load-time policy: quick check, and a full re-hash when it is required.
    /// Throws `ModelIntegrityError` when the file is missing or does not match its pin.
    public static func validate(
        file url: URL,
        record: IntegrityRecord?,
        expected: ModelFile,
        policy: IntegrityPolicy,
        clock: AgentClock = AgentClock(),
        progress: ProgressHandler? = nil
    ) async throws -> IntegrityValidation {
        switch quickCheck(file: url, record: record, expected: expected, policy: policy, now: clock.now()) {
        case .valid:
            guard let record else { preconditionFailure("a valid quick check always has a record") }
            return IntegrityValidation(record: record, fullVerificationReason: nil)
        case let .invalid(error):
            throw error
        case let .needsFullVerification(reason):
            let fresh = try await verify(file: url, expected: expected, appVersion: policy.appVersion, clock: clock, progress: progress)
            return IntegrityValidation(record: fresh, fullVerificationReason: reason)
        }
    }
}
