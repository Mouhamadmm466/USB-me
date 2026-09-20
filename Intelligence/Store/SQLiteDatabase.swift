import Foundation
import SQLite3

/// Values that can cross the SQLite boundary.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Date) { self = .real(value.timeIntervalSince1970) }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
}

/// One row of a result set. Columns are read by index, in the order the query selected them.
public struct SQLRow: Sendable {
    private let values: [SQLValue]

    init(values: [SQLValue]) { self.values = values }

    public func int(_ index: Int) -> Int64? {
        if case let .integer(value) = values[index] { return value }
        if case let .real(value) = values[index] { return Int64(value) }
        return nil
    }

    public func double(_ index: Int) -> Double? {
        if case let .real(value) = values[index] { return value }
        if case let .integer(value) = values[index] { return Double(value) }
        return nil
    }

    public func string(_ index: Int) -> String? {
        if case let .text(value) = values[index] { return value }
        return nil
    }

    public func data(_ index: Int) -> Data? {
        if case let .blob(value) = values[index] { return value }
        return nil
    }

    public func date(_ index: Int) -> Date? { double(index).map(Date.init(timeIntervalSince1970:)) }
    public func bool(_ index: Int) -> Bool { (int(index) ?? 0) != 0 }
}

public enum SQLiteError: Error, CustomStringConvertible, Equatable {
    case open(code: Int32, message: String)
    case statement(sql: String, code: Int32, message: String)
    case migration(from: Int32, message: String)

    public var description: String {
        switch self {
        case let .open(code, message): "sqlite open failed (\(code)): \(message)"
        case let .statement(sql, code, message): "sqlite error (\(code)) in \(sql.prefix(120)): \(message)"
        case let .migration(from, message): "sqlite migration from v\(from) failed: \(message)"
        }
    }
}

/// Thin SQLite wrapper for the personal intelligence store.
///
/// Deliberately small: prepared statements, bindings, transactions and `user_version` migrations —
/// no ORM. Not thread-safe by itself; every caller reaches it through `IntelligenceStore`, whose
/// serial executor owns it (the same pattern the model runtimes use for llama.cpp/whisper.cpp).
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(code: result, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 3_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA temp_store = MEMORY;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var userVersion: Int32 {
        get { (try? query("PRAGMA user_version;").first?.int(0)).flatMap { $0 }.map(Int32.init) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue);") }
    }

    /// True when this SQLite build has FTS5 (all current iOS/macOS versions do; checked so a
    /// missing module degrades to LIKE search instead of crashing).
    lazy var hasFTS5: Bool = {
        (try? execute("CREATE VIRTUAL TABLE IF NOT EXISTS fts5_probe USING fts5(x);")) != nil
            && (try? execute("DROP TABLE IF EXISTS fts5_probe;")) != nil
    }()

    /// Runs one or more statements with no results (schema changes, pragmas).
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw SQLiteError.statement(sql: sql, code: result, message: message)
        }
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.statement(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError.statement(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
            }
            let count = Int(sqlite3_column_count(statement))
            var values: [SQLValue] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, column) {
                        values.append(.blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))))
                    } else {
                        values.append(.null)
                    }
                default: values.append(.null)
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Applies migrations whose index is above the current `user_version`.
    func migrate(_ migrations: [String]) throws {
        let current = userVersion
        guard Int(current) < migrations.count else { return }
        for index in Int(current)..<migrations.count {
            do {
                try transaction { try execute(migrations[index]) }
            } catch {
                throw SQLiteError.migration(from: current, message: String(describing: error))
            }
            userVersion = Int32(index + 1)
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SQLiteError.statement(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(statement, index)
            case let .integer(number): bound = sqlite3_bind_int64(statement, index, number)
            case let .real(number): bound = sqlite3_bind_double(statement, index, number)
            case let .text(string): bound = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case let .blob(data):
                bound = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError.statement(sql: sql, code: bound, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        return statement
    }
}
