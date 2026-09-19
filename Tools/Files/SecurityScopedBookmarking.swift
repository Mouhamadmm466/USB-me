import Foundation

/// The bookmark layer of `BookmarkFileScopeStore`, injectable so the store's persistence, search
/// and containment logic can be tested on plain directories.
public protocol SecurityScopedBookmarking: Sendable {
    func bookmarkData(for folderURL: URL) throws -> Data
    /// Resolves bookmark data to a URL; `isStale` means the bookmark should be recreated.
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    /// Starts security-scoped access. Returns whether access was started (and must be stopped).
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Security-scoped bookmarks for folders picked with `UIDocumentPickerViewController`.
public struct SystemSecurityScopedBookmarking: SecurityScopedBookmarking {
    public init() {}

    public func bookmarkData(for folderURL: URL) throws -> Data {
        #if os(iOS)
        // iOS bookmarks to picker URLs are implicitly security-scoped.
        try folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        // macOS builds of the package are for tests/tools only (not sandboxed).
        try folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Plain directories without bookmarks (tests, evaluation, macOS tools). The "bookmark" is the
/// folder's absolute path.
public struct PlainPathBookmarking: SecurityScopedBookmarking {
    public init() {}

    public func bookmarkData(for folderURL: URL) throws -> Data {
        Data(folderURL.standardizedFileURL.path.utf8)
    }

    public func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: bookmark, encoding: .utf8), path.hasPrefix("/") else {
            throw ToolAdapterError.scopeNotFound
        }
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    public func startAccessing(_ url: URL) -> Bool { true }
    public func stopAccessing(_ url: URL) {}
}
