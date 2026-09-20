import Connectors
import Foundation

/// A `ConnectorSession` that answers from a script and remembers everything it was asked.
///
/// Every adapter is tested through this rather than through the service it talks to. It is the
/// only place a test can see the exact request that would have left the phone, and that is where
/// the things worth checking live: that a value interpolated into a query is escaped, that a large
/// binary is never fetched at all, and that a refusal comes back as the right error.
actor RecordingConnectorSession: ConnectorSession {
    /// A canned answer and the piece of URL it answers to. Routes are matched in order, so a
    /// narrow one listed first wins over a broad one.
    struct Route: Sendable {
        let match: String
        let response: ConnectorResponse

        init(_ match: String, _ response: ConnectorResponse) {
            self.match = match
            self.response = response
        }

        static func json(_ match: String, _ body: String, status: Int = 200) -> Route {
            Route(match, ConnectorResponse(status: status, data: Data(body.utf8)))
        }

        static func text(_ match: String, _ body: String, status: Int = 200) -> Route {
            Route(match, ConnectorResponse(status: status, data: Data(body.utf8)))
        }

        /// A route that exists only to refuse, for the paths where the status is the point.
        static func failing(_ match: String, status: Int) -> Route {
            Route(match, ConnectorResponse(status: status, data: Data()))
        }
    }

    private let routes: [Route]
    private(set) var requests: [ConnectorRequest] = []

    init(_ routes: [Route] = []) {
        self.routes = routes
    }

    func send(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        requests.append(request)
        guard let route = routes.first(where: { request.url.absoluteString.contains($0.match) }) else {
            // A request nobody scripted is a test about to pass for the wrong reason, so it comes
            // back as a refusal rather than as an empty success.
            return ConnectorResponse(status: 404, data: Data())
        }
        return route.response
    }

    /// Every URL asked for, in order. Most assertions are really about this.
    var urls: [String] { requests.map(\.url.absoluteString) }

    // Routes read best as `.json(…)` inside an array literal, where the contextual type is `Route`,
    // and as `RecordingConnectorSession.json(…)` when they are built one at a time. Both spellings
    // exist so a test can be written either way.
    static func json(_ match: String, _ body: String, status: Int = 200) -> Route {
        .json(match, body, status: status)
    }

    static func text(_ match: String, _ body: String, status: Int = 200) -> Route {
        .text(match, body, status: status)
    }

    static func failing(_ match: String, status: Int) -> Route {
        .failing(match, status: status)
    }
}
