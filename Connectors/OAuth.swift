import CryptoKit
import Foundation

/// What a provider needs to sign someone in.
///
/// The client identifier is not a secret and lives in the app's configuration; there is no client
/// *secret* anywhere, because a secret shipped inside an app is not a secret. That is what PKCE is
/// for: the app proves it is the same app that started the sign-in by holding a verifier it never
/// sent, which is a guarantee an embedded string could never give.
public struct OAuthConfiguration: Sendable, Equatable {
    /// How the provider decides where to send the user back.
    public enum Redirect: Sendable, Equatable {
        /// A scheme the app chose and registered with the provider.
        case fixed(uri: String, scheme: String)
        /// Google's iOS clients do not let you choose. The redirect *is* the client ID with its
        /// components reversed, used as a URL scheme, and anything else comes back as
        /// `redirect_uri_mismatch` — which is exactly what happened when this was the bundle id.
        case reversedClientID(path: String)
    }

    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var redirect: Redirect
    /// Set by the user. Empty until they create a project with the provider and paste it in, which
    /// is a step no amount of code can do for them.
    public var clientID: String
    public var scopes: [String]
    /// Extra parameters this provider needs on the authorization request.
    public var additionalParameters: [String: String]

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        redirect: Redirect,
        clientID: String = "",
        scopes: [String],
        additionalParameters: [String: String] = [:]
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirect = redirect
        self.clientID = clientID
        self.scopes = scopes
        self.additionalParameters = additionalParameters
    }

    public var redirectURI: String {
        switch redirect {
        case let .fixed(uri, _): uri
        case let .reversedClientID(path): "\(reversedClientID):\(path)"
        }
    }

    /// The scheme `ASWebAuthenticationSession` waits for. It intercepts the callback itself, so
    /// this does not have to be registered in Info.plist — but it does have to be exactly what the
    /// provider will redirect to, or the sheet sits there until the user gives up.
    public var callbackScheme: String {
        switch redirect {
        case let .fixed(_, scheme): scheme
        case .reversedClientID: reversedClientID
        }
    }

    /// "123-abc.apps.googleusercontent.com" becomes "com.googleusercontent.apps.123-abc".
    var reversedClientID: String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return clientID }
        return "com.googleusercontent.apps.\(clientID.dropLast(suffix.count))"
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    public func with(clientID: String) -> OAuthConfiguration {
        var copy = self
        copy.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

/// One sign-in attempt: the verifier stays here, the challenge goes out.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(random: @Sendable (Int) -> Data = PKCE.randomBytes) {
        verifier = PKCE.base64url(random(64))
        challenge = PKCE.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = PKCE.base64url(random(16))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    /// Unpadded base64url, which is what the spec asks for and what providers reject you over.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the two requests an authorization-code flow needs, and reads the two answers.
///
/// Deliberately has no idea how a browser works: the app presents the URL however the platform
/// does it and hands the callback back here. That keeps every rule about what is sent — and the
/// state check that makes a callback from somewhere else useless — testable without a browser.
public struct OAuthFlow: Sendable {
    public let configuration: OAuthConfiguration
    public let pkce: PKCE

    public init(configuration: OAuthConfiguration, pkce: PKCE = PKCE()) {
        self.configuration = configuration
        self.pkce = pkce
    }

    public var authorizationURL: URL? {
        var items = [
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "response_type": "code",
            "scope": configuration.scopes.joined(separator: " "),
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "state": pkce.state,
        ]
        items.merge(configuration.additionalParameters) { _, new in new }
        return URL.build(configuration.authorizationEndpoint.absoluteString, items)
    }

    /// Reads the provider's callback. Throws when the state does not match ours, which is the whole
    /// reason state exists: a callback we did not start must not be able to connect an account.
    public func code(from callback: URL) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw OAuthError.badCallback
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw OAuthError.refused(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else {
            throw OAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthError.badCallback
        }
        return code
    }

    public func exchangeRequest(code: String) -> ConnectorRequest {
        ConnectorRequest(
            method: .post,
            url: configuration.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(OAuthFlow.form([
                "client_id": configuration.clientID,
                "redirect_uri": configuration.redirectURI,
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": pkce.verifier,
            ]).utf8)
        )
    }

    public static func refreshRequest(configuration: OAuthConfiguration, refreshToken: String) -> ConnectorRequest {
        ConnectorRequest(
            method: .post,
            url: configuration.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(OAuthFlow.form([
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]).utf8)
        )
    }

    /// Reads a token response. Keeps the refresh token we already had when the provider does not
    /// send a new one — Google only returns it on the first exchange, and losing it means asking
    /// the user to sign in again for no reason.
    public static func authorization(
        from response: ConnectorResponse, keeping existingRefresh: String? = nil, now: Date = Date()
    ) throws -> ConnectorAuthorization {
        guard response.isOK else { throw OAuthError.refused("http \(response.status)") }
        struct Token: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let token = try? JSONDecoder().decode(Token.self, from: response.data) else {
            throw OAuthError.badToken
        }
        return ConnectorAuthorization(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? existingRefresh,
            expiresAt: token.expires_in.map { now.addingTimeInterval($0) }
        )
    }

    static func form(_ items: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.sorted { $0.key < $1.key }.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }
}

public enum OAuthError: Error, Equatable, CustomStringConvertible {
    case notConfigured(String)
    case badCallback
    case stateMismatch
    case refused(String)
    case badToken

    public var description: String {
        switch self {
        case let .notConfigured(name):
            "\(name) needs its client ID before it can be connected."
        case .badCallback:
            "That sign-in didn't come back with anything I could use."
        case .stateMismatch:
            "That sign-in didn't match the one I started, so I stopped."
        case let .refused(reason):
            "The sign-in was refused (\(reason))."
        case .badToken:
            "The sign-in came back in a shape I don't understand."
        }
    }
}
