import Foundation
import Intelligence
import Telemetry

/// One result from looking something up.
public struct WebResult: Sendable, Equatable {
    public var title: String
    public var url: URL
    public var snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// A page, as text.
public struct WebPage: Sendable, Equatable {
    public var title: String
    public var url: URL
    public var text: String
    public var bytes: Int

    public init(title: String, url: URL, text: String, bytes: Int) {
        self.title = title
        self.url = url
        self.text = text
        self.bytes = bytes
    }
}

public enum WebError: Error, Equatable, CustomStringConvertible {
    case notAllowed(String)
    case badResponse(Int)
    case tooLarge
    case noText
    case unreachable

    public var description: String {
        switch self {
        case let .notAllowed(host): "\(host) isn't a source I'm allowed to reach."
        case let .badResponse(code): "That source answered with \(code)."
        case .tooLarge: "That page is too big to read."
        case .noText: "There was no readable text there."
        case .unreachable: "I couldn't reach it."
        }
    }
}

/// Something the agent can look things up in.
///
/// A provider declares its hosts up front: the network policy only ever allows those, so a page
/// that tells the agent to fetch somewhere else has nowhere to send it.
public protocol WebProviding: Sendable {
    /// The name the user sees ("Wikipedia").
    var name: String { get }
    var hosts: Set<String> { get }
    func search(_ query: String) async throws -> [WebResult]
    /// Reads one page this provider is allowed to read.
    func read(_ url: URL) async throws -> WebPage
}

/// A keyless, stable, citable source: Wikipedia's public API.
///
/// Chosen deliberately as the first thing that may leave the device — no key, no account, no
/// tracking cookie, a documented API, and text that can be quoted with a source the user can check.
public struct WikipediaProvider: WebProviding {
    public let name = "Wikipedia"
    public let hosts: Set<String> = ["en.wikipedia.org"]
    private let session: any WebSession
    private let maximumBytes: Int

    public init(session: any WebSession = URLSessionWeb(), maximumBytes: Int = 400_000) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    public func search(_ query: String) async throws -> [WebResult] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*"),
        ]
        let (data, _) = try await session.get(components.url!, maximumBytes: maximumBytes)
        struct Response: Decodable {
            struct Query: Decodable {
                struct Item: Decodable {
                    let title: String
                    let snippet: String
                }
                let search: [Item]
            }
            let query: Query
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw WebError.noText }
        return response.query.search.compactMap { item in
            let slug = item.title.replacingOccurrences(of: " ", with: "_")
            guard let url = URL(string: "https://en.wikipedia.org/wiki/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)") else {
                return nil
            }
            return WebResult(title: item.title, url: url, snippet: HTMLText.plain(item.snippet))
        }
    }

    public func read(_ url: URL) async throws -> WebPage {
        guard let host = url.host(), hosts.contains(host) else { throw WebError.notAllowed(url.host() ?? "that host") }
        // The REST summary endpoint returns the lead section as plain text: the part a person would
        // actually quote, without the markup around it.
        let title = url.lastPathComponent
        let summary = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(title)")!
        let (data, bytes) = try await session.get(summary, maximumBytes: maximumBytes)
        struct Summary: Decodable {
            let title: String
            let extract: String
        }
        guard let decoded = try? JSONDecoder().decode(Summary.self, from: data), !decoded.extract.isEmpty else {
            throw WebError.noText
        }
        return WebPage(title: decoded.title, url: url, text: decoded.extract, bytes: bytes)
    }
}

/// The HTTP the agent is allowed to do. One method, no cookies, no redirects off the allowed host,
/// a size cap and a timeout — an interface small enough that a test can stand in for it completely.
public protocol WebSession: Sendable {
    func get(_ url: URL, maximumBytes: Int) async throws -> (Data, Int)
}

public struct URLSessionWeb: WebSession {
    private let session: URLSession

    public init(timeout: TimeInterval = 12) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, maximumBytes: Int) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // No identifying header: the request says what it is and nothing about who sent it.
        request.setValue("VoiceAgent (on-device assistant)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw WebError.badResponse(http.statusCode) }
        guard data.count <= maximumBytes else { throw WebError.tooLarge }
        return (data, data.count)
    }
}

extension HTMLText {
    /// Wikipedia snippets come back with highlight markup; the user wants the sentence.
    public static func plain(_ markup: String) -> String {
        decode(markup.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
