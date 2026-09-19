import Core
import Foundation
import Testing
@testable import Tools

/// A temporary directory tree that is removed when the value is released.
final class TemporaryTree {
    let root: URL
    let storage: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolsTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shared", isDirectory: true)
        storage = base.appendingPathComponent("Storage", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        for directory in [root, storage, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func write(_ relativePath: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("content".utf8).write(to: url)
        return url
    }

    func link(_ relativePath: String, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(relativePath), withDestinationURL: destination)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

@Suite struct PathContainmentTests {
    @Test(arguments: ["", "/etc/passwd", "../secret.txt", "a/../../b", "a/./b", "a//b", "~/notes.txt", "a/b/", "..", ".", "nul\0byte"])
    func rejectsUnsafeRelativePaths(path: String) {
        #expect(throws: ToolAdapterError.invalidPath) { try PathContainment.validatedComponents(of: path) }
    }

    @Test func acceptsOrdinaryRelativePaths() throws {
        #expect(try PathContainment.validatedComponents(of: "Budget 2026.xlsx") == ["Budget 2026.xlsx"])
        #expect(try PathContainment.validatedComponents(of: "Notes/Week..1.txt") == ["Notes", "Week..1.txt"])
    }

    @Test func containmentIsComponentWise() {
        let root = URL(fileURLWithPath: "/tmp/scope")
        #expect(PathContainment.isStrictlyInside(URL(fileURLWithPath: "/tmp/scope/a.txt"), root: root))
        #expect(!PathContainment.isStrictlyInside(URL(fileURLWithPath: "/tmp/scope2/a.txt"), root: root))
        #expect(!PathContainment.isStrictlyInside(URL(fileURLWithPath: "/tmp/scope"), root: root))
    }
}

@Suite struct BookmarkFileScopeStoreTests {
    private func makeStore(_ tree: TemporaryTree, limits: BookmarkFileScopeStore.Limits = .init()) -> BookmarkFileScopeStore {
        BookmarkFileScopeStore.plainDirectory(storageDirectory: tree.storage, limits: limits)
    }

    @Test func addPersistListAndRemoveScopes() async throws {
        let tree = try TemporaryTree()
        let store = makeStore(tree)
        #expect(await store.hasAuthorizedScope() == false)

        let id = try await store.addScope(folderURL: tree.root)
        #expect(await store.hasAuthorizedScope())
        #expect(await store.scopes().map(\.id) == [id])
        #expect(await store.scopes().first?.displayName == "Shared")
        // Adding the same folder again returns the existing scope.
        #expect(try await store.addScope(folderURL: tree.root) == id)

        // A fresh store reads the persisted bookmark.
        let reopened = makeStore(tree)
        #expect(await reopened.scopes().map(\.id) == [id])

        // The storage file is excluded from backups.
        let file = tree.storage.appendingPathComponent(BookmarkFileScopeStore.storageFileName)
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        try await reopened.removeScope(id: id)
        #expect(await reopened.hasAuthorizedScope() == false)
        #expect(await makeStore(tree).scopes().isEmpty)
    }

    @Test func addingAFileInsteadOfAFolderFails() async throws {
        let tree = try TemporaryTree()
        let file = try tree.write("single.txt")
        await #expect(throws: ToolAdapterError.invalidPath) { try await makeStore(tree).addScope(folderURL: file) }
    }

    @Test func searchSkipsHiddenFilesPackagesSymlinksAndDeepFiles() async throws {
        let tree = try TemporaryTree()
        try tree.write("Budget 2026.xlsx")
        try tree.write("Budget 2025.xlsx")
        try tree.write("Archive/Old budget.pdf")
        try tree.write(".hidden budget.txt")
        try tree.write(".git/budget.txt")
        try tree.write("Budget.app/Contents/budget.txt")
        try tree.write("a/b/c/d/e/f/g/budget deep.txt")
        let secret = try tree.write("secret budget.txt", in: tree.outside)
        try tree.link("linked budget.txt", to: secret)
        try tree.link("escape", to: tree.outside)

        let store = makeStore(tree)
        let id = try await store.addScope(folderURL: tree.root)
        let results = try await store.search(query: "budget", limit: 10)
        let paths = Set(results.map(\.reference.relativePath))
        #expect(paths == ["Budget 2026.xlsx", "Budget 2025.xlsx", "Archive/Old budget.pdf"])
        #expect(results.allSatisfy { $0.reference.scopeIdentifier == id })
        #expect(results.allSatisfy { $0.byteSize == 7 && $0.modifiedAt != nil })
    }

    @Test func searchRespectsLimitsAndCaps() async throws {
        let tree = try TemporaryTree()
        for index in 1...15 { try tree.write("report \(index).txt") }
        let store = makeStore(tree)
        _ = try await store.addScope(folderURL: tree.root)
        #expect(try await store.search(query: "report", limit: 10).count == 10)

        let capped = makeStore(tree, limits: .init(maxDepth: 6, maxEntriesPerScope: 5))
        #expect(try await capped.search(query: "report", limit: 50).count == 5)

        try tree.write("x/y/report deep.txt")
        let shallow = makeStore(tree, limits: .init(maxDepth: 1, maxEntriesPerScope: 100))
        let names = try await shallow.search(query: "deep", limit: 50).map(\.reference.displayName)
        #expect(names.isEmpty)
    }

    @Test func urlForReferenceIsStrictlyContained() async throws {
        let tree = try TemporaryTree()
        try tree.write("Notes/plan.txt")
        let secret = try tree.write("secret.txt", in: tree.outside)
        try tree.link("linked.txt", to: secret)
        try tree.link("escape", to: tree.outside)
        let store = makeStore(tree)
        let id = try await store.addScope(folderURL: tree.root)

        let ok = try await store.url(for: FileReference(scopeIdentifier: id, relativePath: "Notes/plan.txt", displayName: "plan.txt"))
        #expect(PathContainment.isStrictlyInside(ok, root: tree.root))
        #expect(ok.lastPathComponent == "plan.txt")

        func reference(_ path: String) -> FileReference { FileReference(scopeIdentifier: id, relativePath: path, displayName: "x") }
        await #expect(throws: ToolAdapterError.invalidPath) { try await store.url(for: reference("../Outside/secret.txt")) }
        await #expect(throws: ToolAdapterError.invalidPath) { try await store.url(for: reference(secret.path)) }
        await #expect(throws: ToolAdapterError.outsideScope) { try await store.url(for: reference("escape/secret.txt")) }
        await #expect(throws: ToolAdapterError.outsideScope) { try await store.url(for: reference("linked.txt")) }
        await #expect(throws: ToolAdapterError.notFound) { try await store.url(for: reference("Notes/missing.txt")) }
        await #expect(throws: ToolAdapterError.notFound) { try await store.url(for: reference("Notes")) }
        await #expect(throws: ToolAdapterError.scopeNotFound) {
            try await store.url(for: FileReference(scopeIdentifier: "unknown", relativePath: "Notes/plan.txt", displayName: "plan.txt"))
        }
    }

    @Test func searchWithoutScopesThrows() async throws {
        let tree = try TemporaryTree()
        await #expect(throws: ToolAdapterError.scopeNotFound) { try await makeStore(tree).search(query: "x", limit: 5) }
    }
}

@Suite struct FileMatcherTests {
    private let files = [
        FileCandidate(reference: FileReference(scopeIdentifier: "s", relativePath: "Budget 2026.xlsx", displayName: "Budget 2026.xlsx"), modifiedAt: nil, byteSize: nil),
        FileCandidate(reference: FileReference(scopeIdentifier: "s", relativePath: "Budget 2026.pdf", displayName: "Budget 2026.pdf"), modifiedAt: nil, byteSize: nil),
        FileCandidate(reference: FileReference(scopeIdentifier: "s", relativePath: "QuarterlyReport.docx", displayName: "QuarterlyReport.docx"), modifiedAt: nil, byteSize: nil),
        FileCandidate(reference: FileReference(scopeIdentifier: "s", relativePath: "Photos/beach.heic", displayName: "beach.heic"), modifiedAt: nil, byteSize: nil),
    ]

    @Test func typeWordsMatchExtensions() {
        let pdf = FileMatcher.rank(query: "the budget pdf", candidates: files, limit: 5)
        #expect(pdf.first?.summary.reference.displayName == "Budget 2026.pdf")
        #expect(pdf.first?.matchesAllTerms == true)
        let sheet = FileMatcher.rank(query: "budget spreadsheet", candidates: files, limit: 5)
        #expect(sheet.first?.summary.reference.displayName == "Budget 2026.xlsx")
        #expect(FileMatcher.rank(query: "photo", candidates: files, limit: 5).map(\.summary.reference.displayName) == ["beach.heic"])
    }

    @Test func caseInsensitiveWordsPrefixesAndTypos() {
        #expect(FileMatcher.rank(query: "QUARTERLY report", candidates: files, limit: 5).first?.summary.reference.displayName == "QuarterlyReport.docx")
        #expect(FileMatcher.rank(query: "quart", candidates: files, limit: 5).first?.summary.reference.displayName == "QuarterlyReport.docx")
        #expect(FileMatcher.rank(query: "quartely", candidates: files, limit: 5).first?.summary.reference.displayName == "QuarterlyReport.docx")
        #expect(FileMatcher.rank(query: "invoice", candidates: files, limit: 5).isEmpty)
    }
}

@Suite struct FileResolutionTests {
    private let files = [
        World.file("docs", "Budget 2026.xlsx"),
        World.file("docs", "Budget 2025.xlsx"),
        World.file("docs", "Trip/Itinerary.pdf"),
    ]

    private func suite(scopes: [String] = ["docs"]) -> FakeToolSuite {
        World.suite(files: files, authorizedScopes: scopes)
    }

    @Test func noAuthorizedScopeNeedsPermission() async {
        let outcome = await World.resolve(.openFile, ["file_query": .string("budget")], suite: suite(scopes: []))
        #expect(outcome.permission == .fileScope)
        let search = await World.resolve(.searchFiles, ["query": .string("budget")], suite: suite(scopes: []))
        #expect(search.permission == .fileScope)
    }

    @Test func grantedStatusWithoutAScopeStillNeedsAFolder() async {
        let granted = World.suite(files: files, authorizedScopes: [], permissions: [.fileScope: .granted])
        #expect(await World.resolve(.openFile, ["file_query": .string("budget")], suite: granted).permission == .fileScope)
    }

    @Test func searchFilesResolvesToQuery() async {
        let outcome = await World.resolve(.searchFiles, ["query": .string(" itinerary ")], suite: suite())
        #expect(outcome.action == .searchFiles(query: "itinerary"))
        let empty = await World.resolve(.searchFiles, ["query": .string("")], suite: suite())
        #expect(empty.clarification?.question == "What file should I look for?")
    }

    @Test func uniqueMatchOpens() async {
        let outcome = await World.resolve(.openFile, ["file_query": .string("itinerary")], suite: suite())
        #expect(outcome.action == .openFile(FileReference(scopeIdentifier: "docs", relativePath: "Trip/Itinerary.pdf", displayName: "Itinerary.pdf")))
        let specific = await World.resolve(.openFile, ["file_query": .string("budget 2026")], suite: suite())
        #expect(specific.action == .openFile(FileReference(scopeIdentifier: "docs", relativePath: "Budget 2026.xlsx", displayName: "Budget 2026.xlsx")))
    }

    @Test func severalMatchesAreAmbiguous() async throws {
        let clarification = try #require(await World.resolve(.openFile, ["file_query": .string("budget")], suite: suite()).clarification)
        #expect(clarification.reason == .fileAmbiguous)
        #expect(clarification.question == "I found Budget 2025 and Budget 2026. Which one?")
        #expect(clarification.candidates.map(\.identifier) == ["docs::Budget 2025.xlsx", "docs::Budget 2026.xlsx"])
        #expect(clarification.candidates.map(\.displayText) == ["Budget 2025.xlsx", "Budget 2026.xlsx"])
        #expect(clarification.missingArgument == "file_query")

        // Picking a candidate resolves to exactly that file.
        let partial = try #require(clarification.partialCall)
        let picked = await ActionResolver(environment: suite().environment)
            .resolve(partial, context: World.context().pinning("file_query", clarification.candidates[1]))
        #expect(picked.action == .openFile(FileReference(scopeIdentifier: "docs", relativePath: "Budget 2026.xlsx", displayName: "Budget 2026.xlsx")))
    }

    @Test func noMatchIsNotFound() async throws {
        let clarification = try #require(await World.resolve(.openFile, ["file_query": .string("tax return")], suite: suite()).clarification)
        #expect(clarification.reason == .fileNotFound)
        #expect(clarification.question == "I couldn't find tax return in your shared folders. What's the file called?")
    }

    @Test func pinnedFileOutsideTheScopeIsRejected() async throws {
        let bogus = ClarificationCandidate(kind: .file, identifier: "docs::../../etc/passwd", displayText: "passwd", matchTerms: [])
        let outcome = await World.resolve(.openFile, ["file_query": .string("budget")], pins: ["file_query": bogus], suite: suite())
        // The bogus pin is ignored and the normal (ambiguous) search result is returned.
        #expect(outcome.clarification?.reason == .fileAmbiguous)
    }

    @Test func filesInUnauthorizedScopesAreInvisible() async {
        let mixed = World.suite(files: files + [World.file("private", "Budget secret.xlsx")], authorizedScopes: ["docs"])
        let clarification = await World.resolve(.openFile, ["file_query": .string("budget")], suite: mixed).clarification
        #expect(clarification?.candidates.count == 2)
    }
}

@Suite struct AppURLTests {
    @Test(arguments: [
        (SupportedApp.maps, "maps://"),
        (.music, "music://"),
        (.messages, "sms:"),
        (.mail, "message://"),
        (.calendar, "calshow://"),
        (.settings, "app-settings:"),
        (.appStore, "itms-apps://apps.apple.com"),
        (.shortcuts, "shortcuts://"),
    ])
    func fixedURLs(app: SupportedApp, expected: String) {
        #expect(AppURLBuilder.url(for: app, query: nil)?.absoluteString == expected)
    }

    @Test func everySupportedAppHasAURL() {
        for app in SupportedApp.allCases {
            #expect(AppURLBuilder.url(for: app, query: nil) != nil, "\(app.rawValue)")
        }
    }

    @Test func mapsQueryIsPercentEncoded() {
        #expect(AppURLBuilder.url(for: .maps, query: "Blue Bottle Coffee")?.absoluteString == "https://maps.apple.com/?q=Blue%20Bottle%20Coffee")
        #expect(AppURLBuilder.url(for: .maps, query: "Café Luna")?.absoluteString == "https://maps.apple.com/?q=Caf%C3%A9%20Luna")
        #expect(AppURLBuilder.url(for: .maps, query: "   ")?.absoluteString == "maps://")
    }

    @Test func queriesAreIgnoredForOtherApps() {
        for app in SupportedApp.allCases where app != .maps {
            #expect(AppURLBuilder.url(for: app, query: "evil.example.com/steal?x=1") == AppURLBuilder.url(for: app, query: nil))
        }
    }

    @Test(arguments: [
        ("x&saddr=evil#frag", "https://maps.apple.com/?q=x%26saddr%3Devil%23frag"),
        ("javascript:alert(1)", "https://maps.apple.com/?q=javascript%3Aalert%281%29"),
        ("../../etc/passwd", "https://maps.apple.com/?q=..%2F..%2Fetc%2Fpasswd"),
        ("pizza\n&daddr=home", "https://maps.apple.com/?q=pizza%20%26daddr%3Dhome"),
        ("coffee\u{202E}moc.live", "https://maps.apple.com/?q=coffeemoc.live"),
        ("100% sure; drop", "https://maps.apple.com/?q=100%25%20sure%3B%20drop"),
    ])
    func injectionStringsCannotEscapeTheQuery(query: String, expected: String) {
        #expect(AppURLBuilder.url(for: .maps, query: query)?.absoluteString == expected)
    }

    @Test func queriesAreCappedAtEightyCharacters() throws {
        let long = String(repeating: "word ", count: 40)
        let sanitized = try #require(AppURLBuilder.sanitizedQuery(long))
        #expect(sanitized.count <= 80)
        #expect(!sanitized.hasSuffix(" "))
        let unbroken = String(repeating: "x", count: 200)
        #expect(AppURLBuilder.sanitizedQuery(unbroken)?.count == 80)
    }

    @Test func telURLsAcceptOnlyDigits() {
        #expect(CallURLBuilder.telURL(digits: "+15551234567")?.absoluteString == "tel:+15551234567")
        #expect(CallURLBuilder.telURL(digits: "911")?.absoluteString == "tel:911")
        #expect(CallURLBuilder.telURL(digits: "12") == nil)
        #expect(CallURLBuilder.telURL(digits: "555-1234") == nil)
        #expect(CallURLBuilder.telURL(digits: "*123#") == nil)
        #expect(CallURLBuilder.telURL(digits: "5551234;ext") == nil)
    }

    @Test func resolverKeepsQueryForMapsOnly() async {
        let maps = await World.resolve(.openSupportedApp, ["app": .string("maps"), "query": .string("  coffee\u{0007} near me ")])
        #expect(maps.action == .openSupportedApp(.maps, query: "coffee near me"))
        let music = await World.resolve(.openSupportedApp, ["app": .string("music"), "query": .string("jazz")])
        #expect(music.action == .openSupportedApp(.music, query: nil))
        let store = await World.resolve(.openSupportedApp, ["app": .string("app_store")])
        #expect(store.action == .openSupportedApp(.appStore, query: nil))
    }

    @Test func unknownAppIsUnsupported() async {
        let outcome = await World.resolve(.openSupportedApp, ["app": .string("safari")])
        #expect(outcome.failure == ToolFailure(tool: .openSupportedApp, code: .unsupported))
        let missing = await World.resolve(.openSupportedApp, [:])
        #expect(missing.failure == ToolFailure(tool: .openSupportedApp, code: .invalidArguments))
    }
}
