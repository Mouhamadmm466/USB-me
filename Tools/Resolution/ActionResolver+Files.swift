import Core
import Foundation

extension ActionResolver {
    static let maxFileCandidates = 8
    static let openFileSearchLimit = 50

    // MARK: search_files

    func resolveSearchFiles(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.searchFiles
        if let blocked = await permissionBlock(.fileScope, for: tool) { return blocked }
        guard case let .valid(query) = TextSanitizer.singleLine(call.string("query"), maxLength: TextSanitizer.maxLength(of: "query", in: tool, fallback: 80)) else {
            return clarify(.missingField, ClarificationText.whatFileToFind, missingArgument: "query", call: call, context: context)
        }
        return .resolved(.searchFiles(query: query))
    }

    // MARK: open_file

    func resolveOpenFile(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.openFile
        if let blocked = await permissionBlock(.fileScope, for: tool) { return blocked }

        if let pinned = context.pinnedSelections["file_query"], pinned.kind == .file,
           let reference = await pinnedFile(pinned) {
            return .resolved(.openFile(reference))
        }

        guard case let .valid(query) = TextSanitizer.singleLine(call.string("file_query"), maxLength: TextSanitizer.maxLength(of: "file_query", in: tool, fallback: 120)) else {
            return clarify(.missingField, ClarificationText.whichFileToOpen, missingArgument: "file_query", call: call, context: context)
        }
        let matches: [FileMatch]
        do {
            matches = try await environment.files.matches(query: query, limit: Self.openFileSearchLimit)
        } catch {
            return failed(tool, ToolAdapterError.failureCode(for: error))
        }
        let complete = matches.filter(\.matchesAllTerms)
        guard let topScore = complete.first?.score else {
            return clarify(.fileNotFound, ClarificationText.fileNotFound(query), missingArgument: "file_query", call: call, context: context)
        }
        let best = complete.filter { $0.score == topScore }.map(\.summary.reference)
        if best.count == 1 { return .resolved(.openFile(best[0])) }

        let names = Self.spokenFileNames(best)
        return clarify(
            .fileAmbiguous,
            ClarificationText.fileAmbiguous(names: names, query: query),
            candidates: Self.fileCandidates(Array(best.prefix(Self.maxFileCandidates))),
            missingArgument: "file_query",
            call: call,
            context: context
        )
    }

    /// Re-validates a file the user picked in a clarification (still authorized, still there).
    private func pinnedFile(_ candidate: ClarificationCandidate) async -> FileReference? {
        let (scope, path) = FileCandidateID.decode(candidate.identifier)
        let scopeIDs: [String]
        if let scope {
            scopeIDs = [scope]
        } else {
            scopeIDs = await environment.files.scopes().map(\.id)
        }
        for scopeID in scopeIDs {
            let reference = FileReference(scopeIdentifier: scopeID, relativePath: path, displayName: (path as NSString).lastPathComponent)
            if (try? await environment.files.url(for: reference)) != nil { return reference }
        }
        return nil
    }

    /// Base names when they differ ("Budget 2026" / "Budget 2025"), full names otherwise.
    static func spokenFileNames(_ references: [FileReference]) -> [String] {
        let bases = references.map { ($0.displayName as NSString).deletingPathExtension }
        let distinct = Set(bases.map(TextTokens.fold)).count == bases.count
        return distinct ? bases : references.map(\.displayName)
    }

    static func fileCandidates(_ references: [FileReference]) -> [ClarificationCandidate] {
        let folded = references.map { TextTokens.fold($0.displayName) }
        return references.enumerated().map { index, reference in
            let duplicateName = folded.filter { $0 == folded[index] }.count > 1
            let folder = (reference.relativePath as NSString).deletingLastPathComponent
            let display = duplicateName && !folder.isEmpty ? "\(reference.displayName) (in \(folder))" : reference.displayName
            let base = (reference.displayName as NSString).deletingPathExtension
            let fileExtension = (reference.displayName as NSString).pathExtension
            var seen = Set<String>()
            let terms = [reference.displayName, base, fileExtension, (folder as NSString).lastPathComponent]
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            return ClarificationCandidate(kind: .file, identifier: FileCandidateID.encode(reference), displayText: display, matchTerms: terms)
        }
    }

    // MARK: open_supported_app

    func resolveOpenSupportedApp(_ call: ProposedToolCall) -> ResolutionOutcome {
        guard let raw = Self.nonEmpty(call.string("app")) else {
            return failed(.openSupportedApp, .invalidArguments)
        }
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "_")
        guard let app = SupportedApp(rawValue: normalized) else {
            return failed(.openSupportedApp, .unsupported)
        }
        let query = app == .maps ? AppURLBuilder.sanitizedQuery(call.string("query")) : nil
        return .resolved(.openSupportedApp(app, query: query))
    }
}
