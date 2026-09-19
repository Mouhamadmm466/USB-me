import Foundation
import Synchronization

/// How one HTTP attempt ended successfully (the body was received to the end).
struct TransferOutcome: Sendable, Equatable {
    /// 200 or 206.
    let statusCode: Int
    /// Size of the partial file when the attempt ended.
    let fileBytes: Int64
    /// The server ignored `Range` (answered 200), so the file was restarted from byte 0.
    let restartedFromZero: Bool
}

/// Protocol-level reasons an attempt was abandoned. Transport errors surface as `URLError`.
enum TransferFailure: Error, Sendable, Equatable {
    case httpStatus(Int)
    /// 416; `serverTotal` from `Content-Range: bytes */N` when present.
    case rangeNotSatisfiable(serverTotal: Int64?)
    /// A 206 whose `Content-Range` does not start where we asked.
    case invalidContentRange
    /// The server announced, or sent, a different size than the pin.
    case sizeMismatch(expected: Int64, reported: Int64)
    case insecureRedirect
    case notHTTP
    case writeFailed(outOfSpace: Bool)
}

/// One HTTP GET that streams its body into a partial file, resuming at `resumeOffset` with
/// `Range: bytes=N-`.
///
/// Bytes are written as they arrive (`urlSession(_:dataTask:didReceive:)` → `FileHandle`), so a
/// multi-GB download uses constant memory and an interruption keeps everything received so far.
/// A fresh `URLSession` (from the injected configuration, so tests can install a `URLProtocol`)
/// is created per attempt with this object as its delegate and invalidated when the attempt ends.
final class HTTPRangeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked Sendable: every `var` below is read and written only on `queue`, the session's
    // serial delegate queue (maxConcurrentOperationCount == 1). `run()` and `cancel()` touch that
    // state exclusively by enqueuing operations on `queue`; the `let`s are immutable.

    typealias ProgressHandler = @Sendable (_ fileBytes: Int64, _ bytesPerSecond: Double) -> Void

    private let request: URLRequest
    private let fileURL: URL
    private let resumeOffset: Int64
    private let expectedBytes: Int64
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let progressInterval: Duration
    private let onProgress: ProgressHandler
    private let queue: OperationQueue
    /// Flush to storage every 64 MB so a crash loses little of a resumable partial.
    private let syncInterval: Int64 = 64 * 1024 * 1024

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<TransferOutcome, Error>?
    private var failure: TransferFailure?
    private var cancelRequested = false
    private var statusCode = 0
    private var fileBytes: Int64 = 0
    private var restartedFromZero = false
    private var unsyncedBytes: Int64 = 0
    private var meter = ThroughputMeter()
    private var lastReport: ContinuousClock.Instant?

    init(
        sourceURL: URL,
        resumeOffset: Int64,
        expectedBytes: Int64,
        fileURL: URL,
        makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration,
        progressInterval: Duration,
        onProgress: @escaping ProgressHandler
    ) {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Byte ranges must refer to the stored bytes, never to a compressed encoding.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        self.request = request
        self.fileURL = fileURL
        self.resumeOffset = resumeOffset
        self.expectedBytes = expectedBytes
        self.makeConfiguration = makeConfiguration
        self.progressInterval = progressInterval
        self.onProgress = onProgress
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        queue.name = "app.voiceagent.models.transfer"
        super.init()
    }

    /// Runs the attempt to completion. Cancelling the calling task cancels the request and throws
    /// `CancellationError`; the bytes already written stay in the partial file.
    func run() async throws -> TransferOutcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransferOutcome, Error>) in
                queue.addOperation { self.start(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.addOperation {
            self.cancelRequested = true
            self.task?.cancel()
        }
    }

    // MARK: Queue-confined implementation

    private func start(_ continuation: CheckedContinuation<TransferOutcome, Error>) {
        self.continuation = continuation
        guard !cancelRequested else {
            complete(.failure(CancellationError()))
            return
        }
        let session = URLSession(configuration: makeConfiguration(), delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    private func complete(_ result: Result<TransferOutcome, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func openPartial(truncatingTo offset: Int64) -> Bool {
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: UInt64(offset)) // also moves the file pointer there
            self.handle = handle
            fileBytes = offset
            return true
        } catch {
            failure = .writeFailed(outOfSpace: Self.isOutOfSpace(error))
            return false
        }
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
        }
        return false
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = .notHTTP
            completionHandler(.cancel)
            return
        }
        statusCode = http.statusCode
        let contentRange = ContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        switch http.statusCode {
        case 206:
            guard let contentRange, contentRange.start == resumeOffset else {
                failure = .invalidContentRange
                break
            }
            if let total = contentRange.total, total != expectedBytes {
                failure = .sizeMismatch(expected: expectedBytes, reported: total)
                break
            }
            _ = openPartial(truncatingTo: resumeOffset)
        case 200:
            // Full body: either no Range was sent, or the server ignored it. Start over at byte 0.
            if http.expectedContentLength >= 0, http.expectedContentLength != expectedBytes {
                failure = .sizeMismatch(expected: expectedBytes, reported: http.expectedContentLength)
                break
            }
            restartedFromZero = resumeOffset > 0
            _ = openPartial(truncatingTo: 0)
        case 416:
            failure = .rangeNotSatisfiable(serverTotal: contentRange?.total)
        default:
            failure = .httpStatus(http.statusCode)
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        let newSize = fileBytes + Int64(data.count)
        guard newSize <= expectedBytes else {
            // Never let a wrong or hostile response grow the file past its pinned size.
            failure = .sizeMismatch(expected: expectedBytes, reported: newSize)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .writeFailed(outOfSpace: Self.isOutOfSpace(error))
            dataTask.cancel()
            return
        }
        fileBytes = newSize
        unsyncedBytes += Int64(data.count)
        if unsyncedBytes >= syncInterval {
            try? handle.synchronize()
            unsyncedBytes = 0
        }
        let now = ContinuousClock.now
        meter.record(bytes: fileBytes, at: now)
        if let lastReport, now - lastReport < progressInterval { return }
        lastReport = now
        onProgress(fileBytes, meter.bytesPerSecond)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let handle {
            try? handle.synchronize()
            try? handle.close()
            self.handle = nil
        }
        if lastReport != nil {
            onProgress(fileBytes, meter.bytesPerSecond)
        }
        session.finishTasksAndInvalidate() // releases the session's strong reference to self
        self.session = nil
        self.task = nil
        if let failure {
            complete(.failure(failure))
        } else if cancelRequested {
            complete(.failure(CancellationError()))
        } else if let error {
            complete(.failure(error))
        } else {
            complete(.success(TransferOutcome(statusCode: statusCode, fileBytes: fileBytes, restartedFromZero: restartedFromZero)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Hugging Face `resolve` URLs redirect to a CDN. Refuse downgrades; keep our headers.
        guard request.url?.scheme?.lowercased() == "https" else {
            failure = .insecureRedirect
            completionHandler(nil)
            task.cancel()
            return
        }
        var redirected = request
        for field in ["Range", "Accept-Encoding"] {
            if let value = self.request.value(forHTTPHeaderField: field) {
                redirected.setValue(value, forHTTPHeaderField: field)
            }
        }
        completionHandler(redirected)
    }
}

/// `Content-Range: bytes 100-999/1000`, `bytes 100-999/*` or `bytes */1000`.
struct ContentRange: Equatable, Sendable {
    let start: Int64?
    let end: Int64?
    let total: Int64?

    init?(_ header: String?) {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst("bytes".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        total = parts[1] == "*" ? nil : Int64(parts[1])
        if parts[0] == "*" {
            start = nil
            end = nil
        } else {
            let bounds = parts[0].split(separator: "-", maxSplits: 1)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start <= end else { return nil }
            self.start = start
            self.end = end
        }
    }
}

/// Transfer rate over a sliding window.
struct ThroughputMeter: Sendable {
    private struct Sample: Sendable {
        let at: ContinuousClock.Instant
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private let window: Duration
    private let spacing: Duration

    init(window: Duration = .seconds(3), spacing: Duration = .milliseconds(100)) {
        self.window = window
        self.spacing = spacing
    }

    mutating func record(bytes: Int64, at now: ContinuousClock.Instant) {
        if let last = samples.last {
            if bytes < last.bytes {
                samples.removeAll() // restarted from zero
            } else if now - last.at < spacing {
                return
            }
        }
        samples.append(Sample(at: now, bytes: bytes))
        let cutoff = now - window
        while samples.count > 2, samples[1].at <= cutoff {
            samples.removeFirst()
        }
    }

    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.at > first.at else { return 0 }
        let elapsed = last.at - first.at
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return seconds > 0 ? Double(last.bytes - first.bytes) / seconds : 0
    }
}

/// Throttled progress with a rate, callable from any thread (used for hashing progress).
final class ProgressThrottle: Sendable {
    private struct State {
        var meter = ThroughputMeter()
        var lastEmit: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let interval: Duration

    init(interval: Duration) {
        self.interval = interval
    }

    /// The current rate if an update should be emitted now, nil when throttled.
    func update(bytes: Int64, force: Bool) -> Double? {
        state.withLock { state in
            let now = ContinuousClock.now
            state.meter.record(bytes: bytes, at: now)
            if !force, let last = state.lastEmit, now - last < interval { return nil }
            state.lastEmit = now
            return state.meter.bytesPerSecond
        }
    }
}

/// Fan-out of values to any number of `AsyncStream` subscribers; safe to call from any thread.
final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func subscribe(bufferingNewest limit: Int) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets {
            continuation.yield(element)
        }
    }

    func finish() {
        let targets = continuations.withLock { state -> [AsyncStream<Element>.Continuation] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for continuation in targets {
            continuation.finish()
        }
    }
}
