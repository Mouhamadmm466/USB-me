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

/// DuckDuckGo's Instant Answer API: keyless, no account, no tracking cookie, and documented.
///
/// Wikipedia answers "what is X" well and everything else badly. This covers the rest of the
/// lookups a person actually makes — a company, a product, a piece of jargon, a person in the news —
/// without a search-engine key, and without sending anything but the words the user said.
public struct DuckDuckGoProvider: WebProviding {
    public let name = "DuckDuckGo"
    public let hosts: Set<String> = ["api.duckduckgo.com"]
    private let session: any WebSession
    private let maximumBytes: Int

    public init(session: any WebSession = URLSessionWeb(), maximumBytes: Int = 400_000) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    public func search(_ query: String) async throws -> [WebResult] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        let (data, _) = try await session.get(components.url!, maximumBytes: maximumBytes)
        struct Response: Decodable {
            struct Topic: Decodable {
                let Text: String?
                let FirstURL: String?
            }
            let Heading: String?
            let AbstractText: String?
            let AbstractURL: String?
            let RelatedTopics: [Topic]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw WebError.noText }

        var results: [WebResult] = []
        if let abstract = response.AbstractText, !abstract.isEmpty,
           let address = response.AbstractURL, let url = URL(string: address) {
            results.append(WebResult(title: response.Heading ?? query, url: url, snippet: abstract))
        }
        for topic in response.RelatedTopics ?? [] {
            guard results.count < 5, let text = topic.Text, !text.isEmpty,
                  let address = topic.FirstURL, let url = URL(string: address) else { continue }
            // The first clause of a related topic is its name; the rest is the description.
            let title = text.split(separator: " - ", maxSplits: 1).first.map(String.init) ?? text
            results.append(WebResult(title: title, url: url, snippet: text))
        }
        return results
    }

    /// Instant answers are summaries, not pages: there is nothing here to open. Reading the page a
    /// result points at is the other provider's job, or nobody's.
    public func read(_ url: URL) async throws -> WebPage {
        throw WebError.notAllowed(url.host() ?? "that host")
    }
}

/// Several providers as one.
///
/// The executor, the policy and the log all deal with a single provider; this is how more than one
/// source gets to exist without any of them learning to. Searches go to all of them at once and the
/// results are merged; a read goes to whichever one owns that host, which is also what keeps a page
/// from redirecting the agent somewhere nobody allowed.
public struct CompositeWebProvider: WebProviding {
    public let name: String
    public let hosts: Set<String>
    private let providers: [any WebProviding]

    public init(name: String = "the web", providers: [any WebProviding]) {
        self.name = name
        self.providers = providers
        self.hosts = providers.reduce(into: Set<String>()) { $0.formUnion($1.hosts) }
    }

    public static var standard: CompositeWebProvider {
        CompositeWebProvider(providers: [WikipediaProvider(), DuckDuckGoProvider()])
    }

    public func search(_ query: String) async throws -> [WebResult] {
        // One slow or broken source must not cost the others their answer.
        let found: [[WebResult]] = await withTaskGroup(of: [WebResult].self) { group in
            for provider in providers {
                group.addTask { (try? await provider.search(query)) ?? [] }
            }
            var all: [[WebResult]] = []
            for await results in group { all.append(results) }
            return all
        }
        // Interleave rather than concatenate: two sources' best answers beat one source's top five.
        var merged: [WebResult] = []
        var seen = Set<URL>()
        for index in 0..<(found.map(\.count).max() ?? 0) {
            for results in found where index < results.count {
                let result = results[index]
                if seen.insert(result.url).inserted { merged.append(result) }
            }
        }
        guard !merged.isEmpty else { return [] }
        return merged
    }

    public func read(_ url: URL) async throws -> WebPage {
        guard let host = url.host(), let owner = providers.first(where: { $0.hosts.contains(host) }) else {
            throw WebError.notAllowed(url.host() ?? "that host")
        }
        return try await owner.read(url)
    }
}
