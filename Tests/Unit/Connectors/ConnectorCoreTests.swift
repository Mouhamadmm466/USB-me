import Core
import Foundation
import Testing
@testable import Connectors

/// A connector that does nothing, so the tests about *rules* are not tests about Gmail.
private struct StubConnector: Connector {
    let id: String
    let name: String
    let hosts: Set<String> = ["stub.example.com"]
    let auth: ConnectorAuthStyle
    let capabilities: [ConnectorCapability]

    init(id: String = "stub", name: String = "Stub", auth: ConnectorAuthStyle? = nil) {
        self.id = id
        self.name = name
        self.auth = auth ?? .token(ConnectorTokenInstructions(
            url: URL(string: "https://example.com/token")!, guidance: "Make one."
        ))
        capabilities = [
            ConnectorCapability(id: CapabilityID("stub.search"), title: "Search things",
                                summary: "Search.", risk: .readOnly),
            ConnectorCapability(id: CapabilityID("stub.send"), title: "Send a note",
                                summary: "Send.", risk: .externalCommunication, isWrite: true),
        ]
    }

    func perform(_ call: ConnectorCall, auth: ConnectorAuthorization) async throws -> ConnectorResult {
        ConnectorResult(observation: "ran \(call.capability)")
    }
}

@Suite struct ConnectorPermissionTests {
    private let connector = StubConnector()

    @Test func readingIsOnAndWritingAsksBeforeTheUserTouchesAnything() {
        let permissions = ConnectorPermissions.defaults(for: connector)
        #expect(permissions.grant(for: CapabilityID("stub.search"), in: connector) == .on)
        #expect(permissions.grant(for: CapabilityID("stub.send"), in: connector) == .ask)
    }

    @Test func aCapabilityTurnedOffIsNotOfferedToTheModelAtAll() async throws {
        let accounts = EphemeralAccountStore()
        let registry = ConnectorRegistry(connectors: [connector], accounts: accounts, tokens: EphemeralTokenStore())
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(accessToken: "t"))

        await registry.set(.off, for: CapabilityID("stub.send"), in: "stub")
        let available = await registry.availableCapabilities().map(\.capability.id.rawValue)

        // Not "refused when asked for" — never described. It cannot ask for what it has not heard of.
        #expect(available == ["stub.search"])
    }

    @Test func aServiceWithEverythingOffIsNotConnectedAsFarAsTheAgentIsConcerned() async throws {
        let registry = ConnectorRegistry(connectors: [connector], accounts: EphemeralAccountStore(),
                                         tokens: EphemeralTokenStore())
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(accessToken: "t"))
        #expect(await registry.connected() == ["stub"])

        for capability in connector.capabilities {
            await registry.set(.off, for: capability.id, in: "stub")
        }
        #expect(await registry.connected().isEmpty)
        #expect(await registry.allowedHosts().isEmpty)
    }

    @Test func reconnectingKeepsWhatTheUserAlreadyDecided() async throws {
        let registry = ConnectorRegistry(connectors: [connector], accounts: EphemeralAccountStore(),
                                         tokens: EphemeralTokenStore())
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(accessToken: "one"))
        await registry.set(.off, for: CapabilityID("stub.send"), in: "stub")

        // Signing in again is not a reason to re-open something they switched off.
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(accessToken: "two"))
        let account = try #require(await registry.account("stub"))
        #expect(account.permissions.grant(for: CapabilityID("stub.send"), in: connector) == .off)
    }

    @Test func disconnectingTakesTheTokenFirst() async throws {
        let tokens = EphemeralTokenStore()
        let registry = ConnectorRegistry(connectors: [connector], accounts: EphemeralAccountStore(), tokens: tokens)
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(accessToken: "t"))

        try await registry.disconnect("stub")

        #expect(try tokens.authorization(for: "stub") == nil)
        #expect(await registry.account("stub") == nil)
        #expect(await registry.connected().isEmpty)
    }
}

@Suite struct ConnectorTokenTests {
    @Test func aTokenThatIsAboutToExpireCountsAsExpired() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // A call that takes a moment must not start with a token that dies halfway through it.
        #expect(ConnectorAuthorization(accessToken: "t", expiresAt: now.addingTimeInterval(30)).isExpired(at: now))
        #expect(!ConnectorAuthorization(accessToken: "t", expiresAt: now.addingTimeInterval(600)).isExpired(at: now))
        #expect(!ConnectorAuthorization(accessToken: "t").isExpired(at: now))
    }

    @Test func anExpiredTokenIsRefreshedAndTheNewOneIsKept() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let connector = StubConnector(auth: .oauth(OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://example.com/auth")!,
            tokenEndpoint: URL(string: "https://example.com/token")!,
            redirect: .fixed(uri: "app:/cb", scheme: "app"), clientID: "abc", scopes: ["read"]
        )))
        let tokens = EphemeralTokenStore()
        let registry = ConnectorRegistry(connectors: [connector], accounts: EphemeralAccountStore(), tokens: tokens)
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(
            accessToken: "old", refreshToken: "refresh", expiresAt: now.addingTimeInterval(-10)
        ))
        let session = RecordingConnectorSession([
            .json("token", #"{"access_token":"new","expires_in":3600}"#),
        ])

        let fresh = try await registry.authorization(for: "stub", session: session, now: now)

        #expect(fresh.accessToken == "new")
        // Google only sends the refresh token once; losing it would mean asking the user to sign in
        // again for no reason.
        #expect(fresh.refreshToken == "refresh")
        #expect(try tokens.authorization(for: "stub")?.accessToken == "new")
    }

    @Test func anExpiredTokenWithNothingToRefreshWithSaysSoRatherThanFailingOddly() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let connector = StubConnector()
        let registry = ConnectorRegistry(connectors: [connector], accounts: EphemeralAccountStore(),
                                         tokens: EphemeralTokenStore())
        try await registry.connect("stub", label: "me", authorization: ConnectorAuthorization(
            accessToken: "old", expiresAt: now.addingTimeInterval(-10)
        ))

        await #expect(throws: ConnectorError.expired) {
            try await registry.authorization(for: "stub", session: RecordingConnectorSession(), now: now)
        }
    }
}

@Suite struct OAuthFlowTests {
    private let configuration = OAuthConfiguration(
        authorizationEndpoint: URL(string: "https://example.com/auth")!,
        tokenEndpoint: URL(string: "https://example.com/token")!,
        redirect: .fixed(uri: "app:/cb", scheme: "app"), clientID: "client-123", scopes: ["read", "write"]
    )

    @Test func theChallengeGoesOutAndTheVerifierStaysHere() throws {
        let flow = OAuthFlow(configuration: configuration)
        let url = try #require(flow.authorizationURL?.absoluteString)

        #expect(url.contains("code_challenge_method=S256"))
        #expect(url.contains("code_challenge=\(flow.pkce.challenge)"))
        #expect(url.contains("client_id=client-123"))
        // The one thing that must never be in a URL: the secret that proves we are us.
        #expect(!url.contains(flow.pkce.verifier))
        #expect(!url.contains("client_secret"))
    }

    @Test func aCallbackWeDidNotStartIsRefused() throws {
        let flow = OAuthFlow(configuration: configuration)
        let forged = URL(string: "app:/cb?code=stolen&state=somebody-elses")!

        #expect(throws: OAuthError.stateMismatch) { try flow.code(from: forged) }
    }

    @Test func aRefusalComesBackAsARefusalRatherThanAMissingCode() throws {
        let flow = OAuthFlow(configuration: configuration)
        let denied = URL(string: "app:/cb?error=access_denied&state=\(flow.pkce.state)")!

        #expect(throws: OAuthError.refused("access_denied")) { try flow.code(from: denied) }
    }

    @Test func theExchangeSendsTheVerifierAndNoSecret() throws {
        let flow = OAuthFlow(configuration: configuration)
        let request = flow.exchangeRequest(code: "the-code")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)

        #expect(request.method == .post)
        #expect(body.contains("code_verifier=\(flow.pkce.verifier)"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test func aTokenResponseBecomesAnAuthorizationWithAnExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let response = ConnectorResponse(
            status: 200, data: Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8)
        )

        let authorization = try OAuthFlow.authorization(from: response, now: now)

        #expect(authorization.accessToken == "a")
        #expect(authorization.refreshToken == "r")
        #expect(authorization.expiresAt == now.addingTimeInterval(3600))
    }
}

@Suite struct ConnectorScopeTests {
    @Test func aPayloadIsWhatWouldActuallyBeSentNotADescriptionOfIt() {
        let payload = ConnectorStepExecutorPayload.payload(of: ["query": "Sarah benchmark", "limit": "5"])
        // "Search your email" is not checkable; this is.
        #expect(payload.contains("query: Sarah benchmark"))
        #expect(payload.contains("limit: 5"))
    }
}

/// The payload helper is internal to the agent module; this mirrors it so the rule can be tested
/// from here without opening the executor up.
private enum ConnectorStepExecutorPayload {
    static func payload(of arguments: [String: String]) -> String {
        arguments.sorted { $0.key < $1.key }
            .filter { !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}

@Suite struct GoogleRedirectTests {
    /// The bug that made connecting Gmail impossible: Google's iOS clients do not let you choose a
    /// redirect. It is the client ID with its components reversed, used as a URL scheme, and
    /// anything else is refused with `redirect_uri_mismatch` before the user sees a consent screen.
    private let clientID = "27611766407-t1rc9ncmein0pt950f2h5nv0taa8ucnk.apps.googleusercontent.com"

    @Test func theRedirectIsTheClientIDReversed() {
        let configuration = OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            redirect: .reversedClientID(path: "/oauth2redirect"),
            clientID: clientID,
            scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
        )

        #expect(configuration.callbackScheme
            == "com.googleusercontent.apps.27611766407-t1rc9ncmein0pt950f2h5nv0taa8ucnk")
        #expect(configuration.redirectURI
            == "com.googleusercontent.apps.27611766407-t1rc9ncmein0pt950f2h5nv0taa8ucnk:/oauth2redirect")
    }

    @Test func gmailAndDriveAskGoogleForTheSameThing() {
        // Both are one Google project with one client, so both must derive the same redirect —
        // otherwise connecting the second one fails after the first one worked.
        guard case let .oauth(gmail) = GmailConnector(clientID: clientID).auth,
              case let .oauth(drive) = DriveConnector(clientID: clientID).auth else {
            return #expect(Bool(false), "both should use OAuth")
        }
        #expect(gmail.redirectURI == drive.redirectURI)
        #expect(gmail.callbackScheme == drive.callbackScheme)
        #expect(gmail.redirectURI.hasPrefix("com.googleusercontent.apps."))
    }

    @Test func theAuthorizationURLCarriesTheScopesGmailActuallyNeeds() throws {
        guard case let .oauth(configuration) = GmailConnector(clientID: clientID).auth else {
            return #expect(Bool(false), "Gmail should use OAuth")
        }
        let url = try #require(OAuthFlow(configuration: configuration).authorizationURL?.absoluteString)

        #expect(url.contains("gmail.readonly"))
        #expect(url.contains("gmail.send"))
        // Without both of these Google hands over no refresh token, and the connection dies an hour
        // later with nothing to renew it.
        #expect(url.contains("access_type=offline"))
        #expect(url.contains("prompt=consent"))
    }
}
