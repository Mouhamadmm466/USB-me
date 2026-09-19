import Foundation

/// Where a case came from: `calls.jsonl:42`.
public struct EvalSourceLocation: Sendable, Hashable, Codable, CustomStringConvertible {
    public let file: String
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line)" }
}

/// Every way loading the dataset can fail, with enough context to fix the file by hand.
public enum EvalLoadError: Error, Sendable, Equatable, CustomStringConvertible {
    case directoryNotFound(path: String)
    case unreadableFile(path: String, reason: String)
    /// The line is not valid JSON (syntax error).
    case invalidJSON(EvalSourceLocation, reason: String)
    /// Valid JSON that does not match `EvalCase` / `EvalFixture`.
    case decodingFailed(EvalSourceLocation, codingPath: String, reason: String)
    /// A key the schema does not know (usually a typo such as `clarification_reasn`); JSONDecoder
    /// would otherwise ignore it silently.
    case unknownKey(EvalSourceLocation, keyPath: String)
    case duplicateCaseID(String, first: EvalSourceLocation, second: EvalSourceLocation)
    case fixtureIDMismatch(file: String, declaredID: String)
    case duplicateFixtureID(String)
    case missingFixture(caseID: String, fixture: String, location: EvalSourceLocation)
    case noCases(path: String)

    public var description: String {
        switch self {
        case let .directoryNotFound(path):
            "Directory not found: \(path)"
        case let .unreadableFile(path, reason):
            "Cannot read \(path): \(reason)"
        case let .invalidJSON(location, reason):
            "\(location): invalid JSON: \(reason)"
        case let .decodingFailed(location, codingPath, reason):
            "\(location): \(codingPath.isEmpty ? "<root>" : codingPath): \(reason)"
        case let .unknownKey(location, keyPath):
            "\(location): unknown key \(keyPath) (typo? the schema would ignore it)"
        case let .duplicateCaseID(id, first, second):
            "Duplicate case id \"\(id)\" at \(first) and \(second)"
        case let .fixtureIDMismatch(file, declaredID):
            "Fixture file \(file) declares id \"\(declaredID)\"; the id must equal the file name"
        case let .duplicateFixtureID(id):
            "Duplicate fixture id \"\(id)\""
        case let .missingFixture(caseID, fixture, location):
            "\(location): case \(caseID) references fixture \"\(fixture)\" which does not exist"
        case let .noCases(path):
            "No cases found in \(path)"
        }
    }
}

/// The loaded, cross-checked dataset.
public struct EvalDataset: Sendable {
    /// All cases, in file-name order then line order.
    public let cases: [EvalCase]
    /// Fixtures by id.
    public let fixtures: [String: EvalFixture]
    /// Case id -> `file:line`.
    public let locations: [String: EvalSourceLocation]

    public init(cases: [EvalCase], fixtures: [String: EvalFixture], locations: [String: EvalSourceLocation]) {
        self.cases = cases
        self.fixtures = fixtures
        self.locations = locations
    }

    public func fixture(for evalCase: EvalCase) -> EvalFixture? { fixtures[evalCase.fixture] }

    public func location(of evalCase: EvalCase) -> EvalSourceLocation? { locations[evalCase.id] }

    /// Cases whose id, category, subcategory or tags match a filter; nil filters match everything.
    public func filtered(categories: Set<String>? = nil, tags: Set<String>? = nil, ids: Set<String>? = nil) -> [EvalCase] {
        cases.filter { c in
            (categories.map { $0.contains(c.category) } ?? true)
                && (tags.map { !$0.isDisjoint(with: c.tags) } ?? true)
                && (ids.map { $0.contains(c.id) } ?? true)
        }
    }
}

/// Loads `Tests/AgentEval/Cases/*.jsonl` and `Tests/AgentEval/Fixtures/*.json`.
public enum EvalCaseLoader {
    /// Loads and cross-checks cases and fixtures (unique ids, every referenced fixture exists).
    public static func loadDataset(
        casesDirectory: URL = EvalPaths.casesDirectory,
        fixturesDirectory: URL = EvalPaths.fixturesDirectory
    ) throws -> EvalDataset {
        let fixtures = try loadFixtures(from: fixturesDirectory)
        let located = try loadCases(from: casesDirectory)
        var locations: [String: EvalSourceLocation] = [:]
        for (evalCase, location) in located {
            if let first = locations[evalCase.id] {
                throw EvalLoadError.duplicateCaseID(evalCase.id, first: first, second: location)
            }
            locations[evalCase.id] = location
            if fixtures[evalCase.fixture] == nil {
                throw EvalLoadError.missingFixture(caseID: evalCase.id, fixture: evalCase.fixture, location: location)
            }
        }
        return EvalDataset(cases: located.map(\.0), fixtures: fixtures, locations: locations)
    }

    /// Every `*.jsonl` file in `directory`, sorted by file name.
    public static func loadCases(from directory: URL) throws -> [(EvalCase, EvalSourceLocation)] {
        let files = try listFiles(in: directory, withExtension: "jsonl")
        var all: [(EvalCase, EvalSourceLocation)] = []
        for file in files {
            all += try loadCases(fileURL: file)
        }
        if all.isEmpty { throw EvalLoadError.noCases(path: directory.path) }
        return all
    }

    public static func loadCases(fileURL: URL) throws -> [(EvalCase, EvalSourceLocation)] {
        try decodeCases(jsonl: readText(fileURL), fileName: fileURL.lastPathComponent)
    }

    /// Decodes JSON Lines text. Blank lines and lines starting with `//` are skipped.
    public static func decodeCases(jsonl text: String, fileName: String) throws -> [(EvalCase, EvalSourceLocation)] {
        var result: [(EvalCase, EvalSourceLocation)] = []
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") { continue }
            let location = EvalSourceLocation(file: fileName, line: lineNumber)
            result.append((try decodeStrict(EvalCase.self, from: Data(line.utf8), at: location), location))
        }
        return result
    }

    /// Every `*.json` file in `directory`; each fixture's id must equal its file name.
    public static func loadFixtures(from directory: URL) throws -> [String: EvalFixture] {
        var fixtures: [String: EvalFixture] = [:]
        for file in try listFiles(in: directory, withExtension: "json") {
            let fixture = try decodeFixture(data: Data(readText(file).utf8), fileName: file.lastPathComponent)
            let expectedID = file.deletingPathExtension().lastPathComponent
            guard fixture.id == expectedID else {
                throw EvalLoadError.fixtureIDMismatch(file: file.lastPathComponent, declaredID: fixture.id)
            }
            guard fixtures[fixture.id] == nil else { throw EvalLoadError.duplicateFixtureID(fixture.id) }
            fixtures[fixture.id] = fixture
        }
        return fixtures
    }

    public static func decodeFixture(data: Data, fileName: String) throws -> EvalFixture {
        try decodeStrict(EvalFixture.self, from: data, at: EvalSourceLocation(file: fileName, line: 1))
    }

    // MARK: - Strict decoding

    /// Decodes `T`, mapping errors to `EvalLoadError`, then rejects keys the schema ignored: the
    /// value is re-encoded and every key present in the input but absent from the re-encoding
    /// (other than explicit `null`s) is unknown. This stays in sync with `EvalSchema.swift`
    /// automatically.
    static func decodeStrict<T: Codable>(_ type: T.Type, from data: Data, at location: EvalSourceLocation) throws -> T {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw EvalLoadError.invalidJSON(location, reason: syntaxErrorDescription(error))
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            let (path, reason) = describe(error)
            throw EvalLoadError.decodingFailed(location, codingPath: path, reason: reason)
        } catch {
            throw EvalLoadError.decodingFailed(location, codingPath: "", reason: String(describing: error))
        }
        if let reencoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value)),
           let unknown = firstUnknownKey(original: raw, known: reencoded, path: "") {
            throw EvalLoadError.unknownKey(location, keyPath: unknown)
        }
        return value
    }

    static func firstUnknownKey(original: Any, known: Any, path: String) -> String? {
        if let object = original as? [String: Any] {
            let knownObject = known as? [String: Any] ?? [:]
            for key in object.keys.sorted() {
                let value = object[key]!
                let keyPath = path.isEmpty ? key : "\(path).\(key)"
                guard let knownValue = knownObject[key] else {
                    if value is NSNull { continue }
                    return keyPath
                }
                if let nested = firstUnknownKey(original: value, known: knownValue, path: keyPath) { return nested }
            }
        } else if let array = original as? [Any], let knownArray = known as? [Any], array.count == knownArray.count {
            for (index, element) in array.enumerated() {
                if let nested = firstUnknownKey(original: element, known: knownArray[index], path: "\(path)[\(index)]") {
                    return nested
                }
            }
        }
        return nil
    }

    static func describe(_ error: DecodingError) -> (path: String, reason: String) {
        func render(_ path: [CodingKey]) -> String {
            var out = ""
            for key in path {
                if let index = key.intValue {
                    out += "[\(index)]"
                } else {
                    out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return out
        }
        switch error {
        case let .keyNotFound(key, context):
            let path = render(context.codingPath)
            return (path, "missing required key \"\(key.stringValue)\"")
        case let .typeMismatch(type, context):
            return (render(context.codingPath), "expected \(type): \(context.debugDescription)")
        case let .valueNotFound(type, context):
            return (render(context.codingPath), "expected a \(type) value but found null: \(context.debugDescription)")
        case let .dataCorrupted(context):
            return (render(context.codingPath), context.debugDescription)
        @unknown default:
            return ("", String(describing: error))
        }
    }

    private static func syntaxErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        if let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String { return detail }
        return nsError.localizedDescription
    }

    private static func listFiles(in directory: URL, withExtension ext: String) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EvalLoadError.directoryNotFound(path: directory.path)
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw EvalLoadError.unreadableFile(path: directory.path, reason: error.localizedDescription)
        }
        return contents.filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readText(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EvalLoadError.unreadableFile(path: url.path, reason: error.localizedDescription)
        }
    }
}
