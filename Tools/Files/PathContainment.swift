import Foundation

/// Strict containment of model-independent relative paths inside an authorized folder.
///
/// A `FileReference.relativePath` only ever comes from enumerating a scope, but it is still
/// validated before use: it must be relative, free of `.`/`..`/empty components, and — after
/// standardizing and resolving symlinks on both sides — lie strictly inside the scope root.
public enum PathContainment {
    static let maxPathLength = 1_024
    static let maxComponents = 64

    /// Lexical validation. Throws `ToolAdapterError.invalidPath`.
    public static func validatedComponents(of relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              relativePath.count <= maxPathLength,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\0") else {
            throw ToolAdapterError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= maxComponents,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ToolAdapterError.invalidPath
        }
        return components
    }

    /// Standardized, symlink-resolved form used for every containment comparison.
    public static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Component-wise check (so "/scope2" is not inside "/scope") that `candidate` is strictly
    /// below `root`. Both are canonicalized first.
    public static func isStrictlyInside(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = canonical(root).pathComponents
        let candidateComponents = canonical(candidate).pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// The existing item at `root/relativePath`, canonicalized, strictly inside `root`.
    /// Throws `.invalidPath`, `.notFound` or `.outsideScope`.
    public static func containedURL(root: URL, relativePath: String, fileManager: FileManager = .default) throws -> URL {
        let components = try validatedComponents(of: relativePath)
        var candidate = root
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
        }
        guard fileManager.fileExists(atPath: candidate.path) else { throw ToolAdapterError.notFound }
        let resolved = canonical(candidate)
        guard isStrictlyInside(resolved, root: root) else { throw ToolAdapterError.outsideScope }
        return resolved
    }
}
