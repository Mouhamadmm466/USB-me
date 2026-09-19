import Core
import Foundation
import Permissions

/// In-memory authorized folders and files. `url(for:)` applies the same lexical path validation
/// as the real store and hands out `file:///FakeScopes/<scope>/<path>` URLs.
public actor FakeFileScopeStore: FileScopeStore {
    public static let urlRoot = "/FakeScopes"

    private var scopeList: [FileScope]
    private var files: [FileSummary]
    private var failure: ToolAdapterError?
    private var addedCount = 0

    /// - Parameters:
    ///   - scopes: authorized scope ids (e.g. the fixture's `authorized_file_scopes`).
    ///   - files: files in any scope; files in unauthorized scopes are invisible.
    public init(scopes: [String] = [], files: [FileSummary] = [], failure: ToolAdapterError? = nil) {
        scopeList = scopes.enumerated().map { index, id in
            FileScope(id: id, displayName: id, addedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        self.files = files
        self.failure = failure
    }

    public func setFiles(_ files: [FileSummary]) {
        self.files = files
    }

    /// `matches`/`search`/`url(for:)` throw `failure` (nil clears it).
    public func setFailure(_ failure: ToolAdapterError?) {
        self.failure = failure
    }

    private var authorizedIDs: Set<String> { Set(scopeList.map(\.id)) }

    public func addScope(folderURL: URL) async throws -> String {
        addedCount += 1
        let id = "fake-scope-\(addedCount)"
        scopeList.append(FileScope(id: id, displayName: folderURL.lastPathComponent, addedAt: Date(timeIntervalSince1970: TimeInterval(scopeList.count))))
        return id
    }

    public func removeScope(id: String) async throws {
        scopeList.removeAll { $0.id == id }
    }

    public func scopes() async -> [FileScope] { scopeList }

    public func hasAuthorizedScope() async -> Bool { !scopeList.isEmpty }

    public func matches(query: String, limit: Int) async throws -> [FileMatch] {
        if let failure { throw failure }
        guard !scopeList.isEmpty else { throw ToolAdapterError.scopeNotFound }
        let visible = files
            .filter { authorizedIDs.contains($0.reference.scopeIdentifier) }
            .map { FileCandidate(reference: $0.reference, modifiedAt: $0.modifiedAt, byteSize: $0.byteSize) }
        return FileMatcher.rank(query: query, candidates: visible, limit: limit)
    }

    public func url(for reference: FileReference) async throws -> URL {
        if let failure { throw failure }
        guard authorizedIDs.contains(reference.scopeIdentifier) else { throw ToolAdapterError.scopeNotFound }
        let components = try PathContainment.validatedComponents(of: reference.relativePath)
        guard files.contains(where: {
            $0.reference.scopeIdentifier == reference.scopeIdentifier && $0.reference.relativePath == reference.relativePath
        }) else { throw ToolAdapterError.notFound }
        var url = URL(fileURLWithPath: Self.urlRoot, isDirectory: true)
            .appendingPathComponent(reference.scopeIdentifier, isDirectory: true)
        for component in components { url.appendPathComponent(component, isDirectory: false) }
        return url
    }

    /// The reference a URL from `url(for:)` points to.
    public func reference(for url: URL) -> FileReference? {
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: Self.urlRoot).pathComponents
        guard components.count > rootComponents.count + 1,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
        let scope = components[rootComponents.count]
        let path = components.dropFirst(rootComponents.count + 1).joined(separator: "/")
        return files.first { $0.reference.scopeIdentifier == scope && $0.reference.relativePath == path }?.reference
    }
}

/// Records `.fileOpened` for URLs handed out by a `FakeFileScopeStore`.
public actor FakeFileOpener: FileOpening {
    private let store: FakeFileScopeStore?
    private var opens: Bool
    private let recorder: SideEffectRecorder

    public init(store: FakeFileScopeStore?, opens: Bool = true, recorder: SideEffectRecorder) {
        self.store = store
        self.opens = opens
        self.recorder = recorder
    }

    /// Whether the next `open` succeeds.
    public func setOpens(_ value: Bool) {
        opens = value
    }

    public func open(_ url: URL) async -> Bool {
        guard opens else { return false }
        let reference = await store?.reference(for: url)
            ?? FileReference(scopeIdentifier: "", relativePath: url.path, displayName: url.lastPathComponent)
        await recorder.record(.fileOpened(reference))
        return true
    }
}
