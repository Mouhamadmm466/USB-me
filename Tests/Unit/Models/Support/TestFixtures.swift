import Core
import CryptoKit
import Foundation
import Models
import Synchronization
import Telemetry

// MARK: - Data

/// Deterministic pseudo-random bytes (SplitMix64), so failures reproduce.
func randomData(count: Int, seed: UInt64) -> Data {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        var index = 0
        while index < count {
            var word = next()
            for _ in 0..<8 where index < count {
                raw[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
    }
    return data
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A 40-hex upstream "commit" for test pins.
func fakeCommit(_ seed: UInt64) -> String {
    String(sha256Hex(randomData(count: 16, seed: seed)).prefix(40))
}

// MARK: - Hosted packs

/// A file served by `StubServer` together with the pin that describes it.
struct HostedFile: Sendable {
    let data: Data
    let resource: StubResource
    let pin: ModelFile
}

/// Registers `data` on the stub server under a unique URL and returns its pin.
func host(
    _ filename: String,
    data: Data,
    namespace: String = UUID().uuidString,
    pinnedData: Data? = nil,
    chunkSize: Int = 64 * 1024,
    chunkDelay: Duration = .zero
) -> HostedFile {
    let url = StubServer.url(namespace: namespace, name: filename)
    let resource = StubResource(body: data, chunkSize: chunkSize, chunkDelay: chunkDelay)
    StubServer.shared.register(resource, at: url)
    let pinned = pinnedData ?? data
    let pin = ModelFile(
        filename: filename,
        sourceURL: url,
        repository: "stub/\(namespace)",
        revision: fakeCommit(UInt64(pinned.count)),
        bytes: Int64(pinned.count),
        sha256: sha256Hex(pinned)
    )
    return HostedFile(data: data, resource: resource, pin: pin)
}

func makePack(_ id: String, role: ModelRole = .asr, files: [HostedFile], minimumMemoryGB: Double = 7.5) -> ModelPack {
    ModelPack(
        id: id,
        role: role,
        displayName: "Test \(role.rawValue)",
        license: "MIT",
        files: files.map(\.pin),
        minimumAppVersion: "1.0.0",
        minimumIOSVersion: "18.0",
        minimumPhysicalMemoryGB: minimumMemoryGB
    )
}

// MARK: - Environment

/// A unique temporary directory, removed when the value is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A clock tests can move forward.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date()) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    var agentClock: AgentClock { AgentClock(now: { [self] in self.now }) }
}

extension RetryPolicy {
    static let fastTests = RetryPolicy(maxRetries: 3, maxAttempts: 20, initialDelay: .milliseconds(5), multiplier: 2, maxDelay: .milliseconds(20), jitter: 0)
}

let testStorageMargin: Int64 = 512 * 1024 * 1024
let testAppVersion = "1.0.0 (1)"

func makeDownloader(
    root: URL,
    capacity: Int64 = 1 << 50,
    retry: RetryPolicy = .fastTests,
    appVersion: String = testAppVersion,
    clock: AgentClock = AgentClock(),
    logger: PrivacySafeLogger = .shared
) -> ModelDownloadManager {
    ModelDownloadManager(
        root: root,
        configuration: ModelDownloadManager.Configuration(
            appVersion: appVersion,
            storageMargin: testStorageMargin,
            retryPolicy: retry,
            progressInterval: .milliseconds(1),
            clock: clock
        ),
        sessionConfiguration: { StubServer.sessionConfiguration() },
        availableCapacity: { _ in capacity },
        logger: logger
    )
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A one-way flag shared between tasks.
final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

extension DeviceProfile {
    /// An 8 GB-class iPhone: ProcessInfo reports a little under 8 GiB (here 7.45 GiB).
    static let iPhone8GB = DeviceProfile(platform: .iOS, physicalMemoryBytes: 7_999_000_000, operatingSystemVersion: SemanticVersion("18.0")!, appVersion: SemanticVersion("1.0.0"))
    static let iPhone6GB = DeviceProfile(platform: .iOS, physicalMemoryBytes: 5_980_000_000, operatingSystemVersion: SemanticVersion("18.2")!, appVersion: SemanticVersion("1.0.0"))
}

// MARK: - On-disk records (decoded through public types only)

func readActiveRecord(_ layout: ModelStorageLayout, packID: String) throws -> ActivationRecord {
    try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: layout.activationRecordURL(packID: packID)))
}

struct StoredLedger: Decodable {
    let records: [String: IntegrityRecord]
}

func readLedger(_ layout: ModelStorageLayout, packID: String, revision: String) throws -> StoredLedger {
    try JSONDecoder().decode(StoredLedger.self, from: Data(contentsOf: layout.integrityLedgerURL(packID: packID, revision: revision)))
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
}

/// Overwrites a file's bytes in place (same inode) and moves its mtime away from the recorded one.
func corruptInPlace(_ url: URL, seed: UInt64 = 99, bumpModificationDate: Bool = true) throws {
    let size = Int(fileSize(url) ?? 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: randomData(count: min(size, 4096), seed: seed))
    try handle.close()
    if bumpModificationDate {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path(percentEncoded: false))
    }
}

// MARK: - Waiting

struct WaitTimeout: Error {}

/// First element of `stream` that satisfies `predicate`, or `WaitTimeout`.
func firstValue<T: Sendable>(
    of stream: AsyncStream<T>,
    timeout: Duration = .seconds(30),
    where predicate: @escaping @Sendable (T) -> Bool
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) {
                return value
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw WaitTimeout() }
        return value
    }
}

/// Collects values from a stream into a thread-safe log until cancelled.
final class Recorder<T: Sendable>: Sendable {
    private let values = Mutex<[T]>([])

    var all: [T] { values.withLock { $0 } }

    func record(_ value: T) {
        values.withLock { $0.append(value) }
    }

    func start(_ stream: AsyncStream<T>) -> Task<Void, Never> {
        Task { for await value in stream { self.record(value) } }
    }
}

/// Locates a repository file by walking up from this source file.
func repositoryFile(_ relativePath: String, from filePath: String = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let candidate = directory.appending(path: relativePath)
        if fileExists(candidate) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: relativePath])
}
