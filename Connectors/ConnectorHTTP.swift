import Foundation

/// The HTTP a connector is allowed to do.
///
/// One interface, small enough that a test can stand in for it completely — which is the only way
/// to test an adapter against a service you cannot call from a test. Every adapter in this module
/// goes through it, so there is exactly one place where a request is actually made, one place that
/// enforces the size cap, and one place a test has to replace.
public protocol ConnectorSession: Sendable {
    func send(_ request: ConnectorRequest) async throws -> ConnectorResponse
}

public struct ConnectorRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", patch = "PATCH" }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The bytes that actually leave, for the log. Headers are excluded deliberately: the one that
    /// matters is the authorization, and it must never be written down.
    public var bytesSent: Int { (body?.count ?? 0) + url.absoluteString.utf8.count }
}

public struct ConnectorResponse: Sendable, Equatable {
    public var status: Int
    public var data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    public var isOK: Bool { (200..<300).contains(status) }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard isOK else { throw ConnectorError.badResponse(status) }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else { throw ConnectorError.unreadable }
        return decoded
    }
}

public struct URLSessionConnectorSession: ConnectorSession {
    private let session: URLSession
    private let maximumBytes: Int

    public init(timeout: TimeInterval = 20, maximumBytes: Int = 2_000_000) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
        self.maximumBytes = maximumBytes
    }

    public func send(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ConnectorError.unreachable
        }
        guard data.count <= maximumBytes else { throw ConnectorError.unreadable }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ConnectorResponse(status: status, data: data)
    }
}

// MARK: - Shared shapes

public extension ConnectorRequest {
    /// A bearer-token request. Every adapter here authenticates this way, which is why it is written
    /// once: a header assembled by hand in three places is a header spelled wrong in one of them.
    static func bearer(
        _ method: Method = .get, _ url: URL, token: String,
        accept: String = "application/json", body: Data? = nil, extraHeaders: [String: String] = [:]
    ) -> ConnectorRequest {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": accept,
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        headers.merge(extraHeaders) { _, new in new }
        return ConnectorRequest(method: method, url: url, headers: headers, body: body)
    }
}

public extension URL {
    /// Builds a URL with query items, percent-encoding the values. Returns nil rather than a broken
    /// URL so a caller cannot accidentally send a request to a truncated address.
    static func build(_ base: String, _ items: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        if !items.isEmpty {
            components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}

/// Plain text out of the shapes services actually return.
public enum ConnectorText {
    /// Cuts text to something a model can read without the rest of the plan starving for context.
    public static func trimmed(_ text: String, to limit: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// Base64url, as Google uses it for message bodies.
    public static func base64url(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    /// Tags out, entities in, whitespace collapsed. Enough for an email body or a README; not an
    /// HTML renderer, and not trying to be.
    public static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br[^>]*>|</p>|</div>|</tr>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                    ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return trimmed(text, to: .max)
    }
}
