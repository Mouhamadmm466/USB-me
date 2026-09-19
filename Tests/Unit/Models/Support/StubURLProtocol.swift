import Foundation
import Synchronization

/// What the stub does for one request. Requests consume a resource's script in order; once it is
/// empty every request gets `.serve`.
enum StubBehavior: Sendable, Equatable {
    /// 206 for `Range: bytes=N-` (unless the resource ignores ranges), otherwise 200.
    case serve
    /// Like `.serve`, but the server ends the body after this many bytes (a truncated response;
    /// every delivered byte reaches the client).
    case truncateAfter(Int)
    /// Like `.serve`, but the transfer fails with `URLError.networkConnectionLost` after this many
    /// bytes. URLSession may drop bytes it has not yet handed to its delegate when a protocol
    /// fails, so tests that assert exact offsets use `truncateAfter` (or `failAfter(0)`).
    case failAfter(Int)
    /// Like `.serve`, but after this many bytes the connection stays open without sending more
    /// until the client cancels: a transfer that is reliably still running when a test pauses,
    /// cancels or deletes it.
    case stallAfter(Int)
    /// This status with an empty body.
    case status(Int)
    /// 416 with `Content-Range: bytes */<size>`, whatever was asked.
    case rangeNotSatisfiable
    /// For a range request, a 206 whose `Content-Range` starts one byte later than asked.
    case wrongRangeStart
}

/// One in-memory resource: body, behaviour and a log of the requests it received.
final class StubResource: Sendable {
    struct Request: Sendable, Equatable {
        let range: String?
        let acceptEncoding: String?
    }

    struct Plan: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        enum Ending: Sendable {
            case finish
            case fail
            case stall
        }

        /// Stop after this many body bytes, then end as `ending` says.
        let endAfter: Int?
        let ending: Ending
        let chunkSize: Int
    }

    private struct State {
        var body: Data
        var ignoresRange: Bool
        var script: [StubBehavior]
        var requests: [Request] = []
        var chunkSize: Int
    }

    private let state: Mutex<State>

    init(body: Data, ignoresRange: Bool = false, script: [StubBehavior] = [], chunkSize: Int = 64 * 1024) {
        state = Mutex(State(body: body, ignoresRange: ignoresRange, script: script, chunkSize: chunkSize))
    }

    var requests: [Request] { state.withLock { $0.requests } }

    func setBody(_ body: Data) { state.withLock { $0.body = body } }
    func setScript(_ script: [StubBehavior]) { state.withLock { $0.script = script } }
    func setIgnoresRange(_ ignores: Bool) { state.withLock { $0.ignoresRange = ignores } }

    /// Records the request and decides the response.
    func plan(for request: URLRequest) -> Plan {
        state.withLock { state in
            let range = request.value(forHTTPHeaderField: "Range")
            state.requests.append(Request(range: range, acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding")))
            let behavior = state.script.isEmpty ? StubBehavior.serve : state.script.removeFirst()
            let body = state.body
            let total = body.count

            func plan(_ status: Int, _ headers: [String: String], _ slice: Data, endAfter: Int? = nil, ending: Plan.Ending = .finish) -> Plan {
                var headers = headers
                headers["Content-Length"] = String(slice.count)
                headers["Accept-Ranges"] = "bytes"
                return Plan(status: status, headers: headers, body: slice, endAfter: endAfter, ending: ending,
                            chunkSize: state.chunkSize)
            }

            switch behavior {
            case let .status(code):
                return plan(code, [:], Data())
            case .rangeNotSatisfiable:
                return plan(416, ["Content-Range": "bytes */\(total)"], Data())
            case .serve, .truncateAfter, .failAfter, .stallAfter, .wrongRangeStart:
                let (endAfter, ending): (Int?, Plan.Ending) = switch behavior {
                case let .truncateAfter(bytes): (bytes, .finish)
                case let .failAfter(bytes): (bytes, .fail)
                case let .stallAfter(bytes): (bytes, .stall)
                default: (nil, .finish)
                }
                guard let range, !state.ignoresRange, let start = Self.rangeStart(range) else {
                    return plan(200, [:], body, endAfter: endAfter, ending: ending)
                }
                guard start < total else {
                    return plan(416, ["Content-Range": "bytes */\(total)"], Data())
                }
                let served = behavior == .wrongRangeStart ? min(start + 1, total - 1) : start
                return plan(206, ["Content-Range": "bytes \(served)-\(total - 1)/\(total)"], body.subdata(in: served..<total),
                            endAfter: endAfter, ending: ending)
            }
        }
    }

    private static func rangeStart(_ header: String) -> Int? {
        guard header.hasPrefix("bytes="), header.hasSuffix("-") else { return nil }
        return Int(header.dropFirst("bytes=".count).dropLast())
    }
}

/// Registry of stub resources keyed by absolute URL. Tests use unique URLs, so parallel tests
/// never observe each other's resources.
final class StubServer: Sendable {
    static let shared = StubServer()
    static let host = "models.stub.test"

    private let resources = Mutex<[String: StubResource]>([:])

    func register(_ resource: StubResource, at url: URL) {
        resources.withLock { $0[url.absoluteString] = resource }
    }

    func resource(for url: URL) -> StubResource? {
        resources.withLock { $0[url.absoluteString] }
    }

    static func url(namespace: String, name: String) -> URL {
        URL(string: "https://\(host)/\(namespace)/\(name)")!
    }

    /// Session configuration whose only network is this stub.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        return configuration
    }
}

/// Serves `StubServer` resources to URLSession, streaming bodies in chunks and failing or stalling
/// on cue. No request ever leaves the process.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // @unchecked Sendable: `stopped` is only accessed under `lock`; the delivery closure only
    // reads immutable values and calls the thread-safe URLProtocolClient.
    private let lock = NSLock()
    private var stopped = false
    private let delivery = DispatchQueue(label: "models.stub.delivery")

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == StubServer.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let resource = StubServer.shared.resource(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let plan = resource.plan(for: request)
        let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(plan)
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func deliver(_ plan: StubResource.Plan) {
        delivery.async { [self] in
            var position = 0
            while !self.isStopped {
                let limit = plan.endAfter.map { min($0, plan.body.count) } ?? plan.body.count
                if position >= limit {
                    switch limit >= plan.body.count ? .finish : plan.ending {
                    case .finish: self.client?.urlProtocolDidFinishLoading(self)
                    case .fail: self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    case .stall: break // keep the connection open until URLSession stops loading
                    }
                    return
                }
                let end = min(position + plan.chunkSize, limit)
                self.client?.urlProtocol(self, didLoad: plan.body.subdata(in: position..<end))
                position = end
            }
        }
    }
}
