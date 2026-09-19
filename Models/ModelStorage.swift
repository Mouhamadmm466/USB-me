import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Storage layout (everything below the root is excluded from backup; iOS protection class
// `completeUntilFirstUserAuthentication`):
//
//   <root>/                                  Application Support/Models by default
//     .partial/<sha256>.part                 resumable downloads, content-addressed
//     .trash/                                detached packs awaiting removal (emptied on launch)
//     .intents.json                          ModelManager: packs the user asked to install/paused
//     <packID>/active.json                   activation record: the one revision runtimes may use
//     <packID>/<revision>/<filename>         verified files, one directory per pinned content set
//     <packID>/<revision>/.integrity.json    IntegrityRecord per file (see ModelIntegrity.swift)

/// Paths of the on-device model store.
public struct ModelStorageLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Models`: persistent (unlike Caches, the system never purges it behind
    /// the app's back), and excluded from backup because every file can be downloaded again.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    public var partialDirectory: URL { root.appending(path: ".partial", directoryHint: .isDirectory) }
    public var trashDirectory: URL { root.appending(path: ".trash", directoryHint: .isDirectory) }

    public func packDirectory(_ packID: String) -> URL {
        root.appending(path: packID, directoryHint: .isDirectory)
    }

    public func revisionDirectory(packID: String, revision: String) -> URL {
        packDirectory(packID).appending(path: revision, directoryHint: .isDirectory)
    }

    public func fileURL(packID: String, revision: String, filename: String) -> URL {
        revisionDirectory(packID: packID, revision: revision).appending(path: filename, directoryHint: .notDirectory)
    }

    public func activationRecordURL(packID: String) -> URL {
        packDirectory(packID).appending(path: "active.json", directoryHint: .notDirectory)
    }

    public func integrityLedgerURL(packID: String, revision: String) -> URL {
        revisionDirectory(packID: packID, revision: revision).appending(path: ".integrity.json", directoryHint: .notDirectory)
    }

    public func partialURL(sha256: String) -> URL {
        partialDirectory.appending(path: "\(sha256.lowercased()).part", directoryHint: .notDirectory)
    }
}

// MARK: - Records

/// A revision that was active before the current one (the rollback target).
public struct RevisionPointer: Codable, Sendable, Equatable {
    public let revision: String
    public let files: [ModelFile]
    public let activatedAt: Date

    public init(revision: String, files: [ModelFile], activatedAt: Date) {
        self.revision = revision
        self.files = files
        self.activatedAt = activatedAt
    }
}

/// `<root>/<packID>/active.json`: which revision of a pack runtimes may load. Written only after
/// every file of that revision passed SHA-256 verification, and always atomically.
public struct ActivationRecord: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let packID: String
    public let role: ModelRole
    public let revision: String
    /// Full pins of the active revision, so the record is self-describing (rollback needs them).
    public let files: [ModelFile]
    public let activatedAt: Date
    public let appVersion: String
    /// The previously active revision of the same pack, if its files are still on disk.
    public let previous: RevisionPointer?

    public init(
        packID: String,
        role: ModelRole,
        revision: String,
        files: [ModelFile],
        activatedAt: Date,
        appVersion: String,
        previous: RevisionPointer?
    ) {
        formatVersion = Self.currentFormatVersion
        self.packID = packID
        self.role = role
        self.revision = revision
        self.files = files
        self.activatedAt = activatedAt
        self.appVersion = appVersion
        self.previous = previous
    }

    /// True when this record activates exactly the content `pack` pins: same pack id, same role
    /// (model family), same revision and the same file names, sizes and digests.
    public func matches(_ pack: ModelPack) -> Bool {
        packID == pack.id && role == pack.role && revision == pack.revision && Self.sameContent(files, pack.files)
    }

    /// True when the rollback target is exactly the content `pack` pins (same family).
    public func previousMatches(_ pack: ModelPack) -> Bool {
        guard let previous, packID == pack.id, role == pack.role else { return false }
        return previous.revision == pack.revision && Self.sameContent(previous.files, pack.files)
    }

    var pointer: RevisionPointer { RevisionPointer(revision: revision, files: files, activatedAt: activatedAt) }

    static func sameContent(_ lhs: [ModelFile], _ rhs: [ModelFile]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let left = lhs.sorted { $0.filename < $1.filename }
        let right = rhs.sorted { $0.filename < $1.filename }
        return zip(left, right).allSatisfy { a, b in
            a.filename == b.filename && a.bytes == b.bytes && a.sha256.lowercased() == b.sha256.lowercased()
        }
    }
}

/// `<root>/<packID>/<revision>/.integrity.json`.
struct IntegrityLedger: Codable, Sendable, Equatable {
    var formatVersion = 1
    var records: [String: IntegrityRecord] = [:]
}

/// Bytes on disk per pack, and free space.
public struct ModelStorageUsage: Sendable, Equatable {
    public struct Pack: Sendable, Equatable, Identifiable {
        public let id: String
        public let displayName: String
        /// Files of the active revision.
        public let activeBytes: Int64
        /// Other revisions on disk: the rollback target, or files of an unfinished update.
        public let inactiveBytes: Int64
        /// Resumable partial downloads.
        public let partialBytes: Int64

        public init(id: String, displayName: String, activeBytes: Int64, inactiveBytes: Int64, partialBytes: Int64) {
            self.id = id
            self.displayName = displayName
            self.activeBytes = activeBytes
            self.inactiveBytes = inactiveBytes
            self.partialBytes = partialBytes
        }

        public var totalBytes: Int64 { activeBytes + inactiveBytes + partialBytes }
    }

    public let packs: [Pack]
    /// Free space for new downloads (see `StorageSpace`); nil if the volume could not be queried.
    public let availableBytes: Int64?

    public init(packs: [Pack], availableBytes: Int64?) {
        self.packs = packs
        self.availableBytes = availableBytes
    }

    public var totalBytes: Int64 { packs.reduce(0) { $0 + $1.totalBytes } }
}

// MARK: - Free space

public enum StorageSpace {
    /// Bytes available for new files on the volume that holds `url`.
    ///
    /// iOS uses `volumeAvailableCapacityForImportantUsage` (it counts space the system will purge
    /// for a user-initiated download); otherwise, or when that value is unavailable,
    /// `volumeAvailableCapacity`.
    public static func availableCapacity(for url: URL) throws -> Int64 {
        let probe = nearestExistingAncestor(of: url)
        #if os(iOS)
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        #else
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        #endif
        guard let capacity = values.volumeAvailableCapacity else { throw CocoaError(.fileReadUnknown) }
        return Int64(capacity)
    }

    static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        var remainingSteps = 64
        while remainingSteps > 0, !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == candidate.path(percentEncoded: false) { break }
            candidate = parent
            remainingSteps -= 1
        }
        return candidate
    }
}

// MARK: - File-system helpers

/// Coding for every JSON file in the store. Dates use Foundation's default representation
/// (`timeIntervalSinceReferenceDate` as a Double), which round-trips exactly — mtime comparisons
/// and record equality depend on that; `.secondsSince1970` would add a rounding step.
enum ModelJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

enum ModelFileSystem {
    /// iOS data protection for model files: readable once the device has been unlocked after boot,
    /// so downloads and model loads keep working while the phone is locked.
    static var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: path(url)) }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(url), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Creates the directory if needed, applies the protection class and excludes it (and so
    /// everything inside it) from backup.
    static func ensureDirectory(_ url: URL) throws {
        if !isDirectory(url) {
            if exists(url) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: protectionAttributes)
        }
        #if os(iOS)
        if let attributes = protectionAttributes {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path(url))
        }
        #endif
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    /// Applies the model protection class to an existing file (iOS; no-op elsewhere). Changes only
    /// metadata (ctime), never the size, inode or mtime that integrity records track.
    static func applyProtection(_ url: URL) {
        #if os(iOS)
        if let attributes = protectionAttributes {
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: path(url))
        }
        #endif
    }

    /// Creates an empty file with the model protection class when nothing exists at `url`.
    static func createFileIfNeeded(_ url: URL) throws {
        guard !exists(url) else { return }
        guard FileManager.default.createFile(atPath: path(url), contents: nil, attributes: protectionAttributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path(url)])
        }
    }

    /// Size of a regular file; nil when there is none.
    static func fileSize(_ url: URL) -> Int64? {
        try? FileMetadata.read(url).bytes
    }

    static func removeItemIfExists(_ url: URL) throws {
        guard exists(url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func truncate(_ url: URL, to size: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(0, size)))
    }

    /// `rename(2)`: atomic, replaces an existing destination; both paths must be on one volume.
    static func renameReplacing(from source: URL, to destination: URL) throws {
        let (result, code) = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> (Int32, Int32) in
                guard let sourcePath, let destinationPath else { return (-1, EINVAL) }
                let result = rename(sourcePath, destinationPath)
                return (result, result == 0 ? 0 : errno)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    /// Writes to a uniquely named temporary file next to `url`, flushes it, then renames it over
    /// `url`. Readers observe either the previous complete file or the new complete file.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: path(temporary), contents: nil, attributes: protectionAttributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path(temporary)])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try renameReplacing(from: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func isTemporaryWriteName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.contains(".tmp-")
    }

    /// Logical size of the regular, non-hidden files below `url` (model bytes; the small hidden
    /// records and temporary files are not counted). 0 when missing.
    static func logicalSize(of url: URL) -> Int64 {
        if let size = fileSize(url) { return size }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
