import Core
import Foundation
import Permissions

/// A folder the user shared with the app through the document picker.
public struct FileScope: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// The folder's name (user content: never logged).
    public let displayName: String
    public let addedAt: Date

    public init(id: String, displayName: String, addedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.addedAt = addedAt
    }
}

/// A search hit with the information needed to detect ties.
public struct FileMatch: Sendable, Hashable {
    public let summary: FileSummary
    /// Higher is better.
    public let score: Int
    /// Every name word of the query matched this file (file-type words such as "pdf" are optional).
    public let matchesAllTerms: Bool

    public init(summary: FileSummary, score: Int, matchesAllTerms: Bool) {
        self.summary = summary
        self.score = score
        self.matchesAllTerms = matchesAllTerms
    }
}

/// Access to files inside user-authorized folders only.
public protocol FileScopeStore: FileScopeAuthorizationSource, Sendable {
    /// Persists access to a folder the user picked. Returns the scope id (existing id for a folder
    /// that is already authorized).
    func addScope(folderURL: URL) async throws -> String
    func removeScope(id: String) async throws
    func scopes() async -> [FileScope]
    func hasAuthorizedScope() async -> Bool
    /// Ranked matches across all scopes (best first, at most `limit`).
    func matches(query: String, limit: Int) async throws -> [FileMatch]
    /// Ranked file summaries across all scopes (best first, at most `limit`).
    func search(query: String, limit: Int) async throws -> [FileSummary]
    /// The file's URL, strictly contained in its scope. Throws `ToolAdapterError.invalidPath`,
    /// `.outsideScope`, `.scopeNotFound` or `.notFound`.
    func url(for reference: FileReference) async throws -> URL
}

extension FileScopeStore {
    public func search(query: String, limit: Int) async throws -> [FileSummary] {
        try await matches(query: query, limit: limit).map(\.summary)
    }
}

/// Candidate identifiers for files: "<scope id>::<relative path>" (scope ids never contain "::").
public enum FileCandidateID {
    static let separator = "::"

    public static func encode(_ reference: FileReference) -> String {
        reference.scopeIdentifier + separator + reference.relativePath
    }

    /// (scope id, relative path); the scope is nil for a bare relative path.
    public static func decode(_ identifier: String) -> (scopeIdentifier: String?, relativePath: String) {
        guard let range = identifier.range(of: separator) else { return (nil, identifier) }
        return (String(identifier[..<range.lowerBound]), String(identifier[range.upperBound...]))
    }
}
