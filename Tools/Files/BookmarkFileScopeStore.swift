import Core
import Foundation
import Permissions
import Telemetry

/// `FileScopeStore` that persists one bookmark per user-picked folder in a JSON file under
/// Application Support (excluded from backup; Data Protection on iOS) and searches those folders
/// with bounded enumeration.
///
/// The bookmark layer is injectable: `SystemSecurityScopedBookmarking` for the app,
/// `PlainPathBookmarking` for tests and tools (see `plainDirectory(storageDirectory:)`).
public actor BookmarkFileScopeStore: FileScopeStore {
    public struct Limits: Sendable, Equatable {
        /// Deepest directory level searched (1 = only the folder's direct children).
        public var maxDepth: Int
        /// Entries visited per scope before enumeration stops.
        public var maxEntriesPerScope: Int

        public init(maxDepth: Int = 6, maxEntriesPerScope: Int = 5_000) {
            self.maxDepth = maxDepth
            self.maxEntriesPerScope = maxEntriesPerScope
        }
    }

    struct Record: Codable, Sendable, Equatable {
        let id: String
        var displayName: String
        var bookmark: Data
        let addedAt: Date
    }

    struct StoredScopes: Codable {
        var version = 1
        var scopes: [Record]
    }

    public static let storageFileName = "file-scopes.json"

    private let directory: URL
    private let bookmarking: any SecurityScopedBookmarking
    private let limits: Limits
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> String
    private var loaded: [Record]?
    /// Scopes with long-lived access (started for files handed out by `url(for:)`).
    private var activeAccess: [String: URL] = [:]

    /// - Parameters:
    ///   - directory: where `file-scopes.json` lives (created on first write).
    ///   - bookmarking: the bookmark layer.
    public init(
        directory: URL,
        bookmarking: any SecurityScopedBookmarking = SystemSecurityScopedBookmarking(),
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.directory = directory
        self.bookmarking = bookmarking
        self.limits = limits
        self.now = now
        self.makeIdentifier = makeIdentifier
    }

    /// `Application Support/VoiceAgent/FileScopes`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("VoiceAgent", isDirectory: true)
            .appendingPathComponent("FileScopes", isDirectory: true)
    }

    /// The app's store: security-scoped bookmarks in the default directory.
    public static func standard() -> BookmarkFileScopeStore {
        BookmarkFileScopeStore(directory: defaultDirectory)
    }

    /// Plain directories, no bookmarks (tests, evaluation, macOS tools).
    public static func plainDirectory(storageDirectory: URL, limits: Limits = Limits()) -> BookmarkFileScopeStore {
        BookmarkFileScopeStore(directory: storageDirectory, bookmarking: PlainPathBookmarking(), limits: limits)
    }

    private var storageURL: URL { directory.appendingPathComponent(Self.storageFileName, isDirectory: false) }

    // MARK: Persistence

    private func records() -> [Record] {
        if let loaded { return loaded }
        var result: [Record] = []
        if let data = try? Data(contentsOf: storageURL),
           let stored = try? JSONDecoder().decode(StoredScopes.self, from: data) {
            result = stored.scopes
        }
        loaded = result
        return result
    }

    private func save(_ records: [Record]) throws {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                #if os(iOS)
                let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                #else
                let attributes: [FileAttributeKey: Any] = [:]
                #endif
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
            }
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directoryURL = directory
            try? directoryURL.setResourceValues(excluded)

            let data = try JSONEncoder().encode(StoredScopes(scopes: records))
            #if os(iOS)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: storageURL, options: [.atomic])
            #endif
            var fileURL = storageURL
            try? fileURL.setResourceValues(excluded)
        } catch {
            throw ToolAdapterError.systemFailure
        }
        loaded = records
    }

    // MARK: Bookmarks

    /// Resolves a record's folder, refreshing a stale bookmark. Nil when it no longer resolves.
    private func resolveRoot(_ record: Record) -> URL? {
        guard let resolved = try? bookmarking.resolve(record.bookmark) else { return nil }
        if resolved.isStale {
            let started = bookmarking.startAccessing(resolved.url)
            defer { if started { bookmarking.stopAccessing(resolved.url) } }
            if let refreshed = try? bookmarking.bookmarkData(for: resolved.url) {
                var all = records()
                if let index = all.firstIndex(where: { $0.id == record.id }) {
                    all[index].bookmark = refreshed
                    try? save(all)
                }
            }
        }
        return resolved.url
    }

    // MARK: FileScopeStore

    public func addScope(folderURL: URL) async throws -> String {
        let started = bookmarking.startAccessing(folderURL)
        defer { if started { bookmarking.stopAccessing(folderURL) } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolAdapterError.invalidPath
        }
        let canonicalFolder = PathContainment.canonical(folderURL)
        for record in records() {
            if let root = resolveRoot(record), PathContainment.canonical(root) == canonicalFolder {
                return record.id
            }
        }
        let bookmark: Data
        do {
            bookmark = try bookmarking.bookmarkData(for: folderURL)
        } catch {
            throw ToolAdapterError.systemFailure
        }
        let record = Record(id: makeIdentifier(), displayName: folderURL.lastPathComponent, bookmark: bookmark, addedAt: now())
        try save(records() + [record])
        PrivacySafeLogger.shared.log(.toolExecution(tool: "file_scope", status: "added"))
        return record.id
    }

    public func removeScope(id: String) async throws {
        if let root = activeAccess.removeValue(forKey: id) {
            bookmarking.stopAccessing(root)
        }
        let remaining = records().filter { $0.id != id }
        guard remaining.count != records().count else { return }
        try save(remaining)
        PrivacySafeLogger.shared.log(.toolExecution(tool: "file_scope", status: "removed"))
    }

    public func scopes() async -> [FileScope] {
        records()
            .sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
            .map { FileScope(id: $0.id, displayName: $0.displayName, addedAt: $0.addedAt) }
    }

    public func hasAuthorizedScope() async -> Bool {
        records().contains { resolveRoot($0) != nil }
    }

    public func matches(query: String, limit: Int) async throws -> [FileMatch] {
        let all = records().sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
        guard !all.isEmpty else { throw ToolAdapterError.scopeNotFound }
        var candidates: [FileCandidate] = []
        var resolvedAny = false
        for record in all {
            guard let root = resolveRoot(record) else { continue }
            resolvedAny = true
            let started = activeAccess[record.id] == nil && bookmarking.startAccessing(root)
            defer { if started { bookmarking.stopAccessing(root) } }
            candidates += enumerate(root: root, scopeIdentifier: record.id)
        }
        guard resolvedAny else { throw ToolAdapterError.scopeNotFound }
        return FileMatcher.rank(query: query, candidates: candidates, limit: limit)
    }

    public func url(for reference: FileReference) async throws -> URL {
        guard let record = records().first(where: { $0.id == reference.scopeIdentifier }) else {
            throw ToolAdapterError.scopeNotFound
        }
        _ = try PathContainment.validatedComponents(of: reference.relativePath)
        guard let root = resolveRoot(record) else { throw ToolAdapterError.scopeNotFound }
        // Keep the folder accessible while the file is being viewed (one access per scope).
        if activeAccess[record.id] == nil, bookmarking.startAccessing(root) {
            activeAccess[record.id] = root
        }
        let url = try PathContainment.containedURL(root: root, relativePath: reference.relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolAdapterError.notFound
        }
        return url
    }

    /// Ends every long-lived folder access (e.g. when the app goes to the background).
    public func relinquishAccess() {
        for root in activeAccess.values { bookmarking.stopAccessing(root) }
        activeAccess.removeAll()
    }

    // MARK: Enumeration

    private func enumerate(root: URL, scopeIdentifier: String) -> [FileCandidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey,
        ]
        let canonicalRoot = PathContainment.canonical(root)
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let keySet = Set(keys)
        let rootComponents = canonicalRoot.pathComponents
        // Enumerated URLs extend the canonical root and symlinks are skipped, so a lexical
        // comparison is enough here; `url(for:)` re-checks containment on the real path.
        func relativePath(of url: URL) -> String? {
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
            return components.dropFirst(rootComponents.count).joined(separator: "/")
        }
        var results: [FileCandidate] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > limits.maxEntriesPerScope { break }
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if enumerator.level >= limits.maxDepth { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let relativePath = relativePath(of: url) else { continue }
            results.append(FileCandidate(
                reference: FileReference(
                    scopeIdentifier: scopeIdentifier,
                    relativePath: relativePath,
                    displayName: url.lastPathComponent
                ),
                modifiedAt: values.contentModificationDate,
                byteSize: values.fileSize.map(Int64.init)
            ))
        }
        return results
    }
}
