import AuthenticationServices
import Connectors
import Core
import Foundation
import SwiftUI
import Telemetry

/// Connecting an outside service, and everything the Connected services screens need.
///
/// The app's part of this is deliberately small: present a sign-in that Safari owns, hand the
/// callback to `OAuthFlow`, put the token in the Keychain. It never sees a password, never stores
/// one, and the only thing it keeps is a token it cannot read the meaning of.
@MainActor
extension AppModel {
    static let connectorConfiguration: ConnectorConfigurationStore = {
        let url = (try? ConnectorConfigurationStore.defaultURL())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "connector-configuration.json")
        return ConnectorConfigurationStore(url: url)
    }()

    var connectorIntents: ConnectorsIntents {
        ConnectorsIntents(
            connect: { [weak self] id in self?.connect(id) },
            disconnect: { [weak self] id in self?.disconnect(id) },
            setGrant: { [weak self] service, capability, grant in
                guard let self else { return }
                Task { @MainActor in
                    await AppModel.connectors.set(grant, for: CapabilityID(capability), in: service)
                    await self.refreshConnectors()
                }
            },
            submitSecret: { [weak self] id, value in self?.submitConnectorSecret(id, value) },
            refresh: { [weak self] in await self?.refreshConnectors() }
        )
    }

    /// Reads the registry into the shape the screens draw.
    func refreshConnectors() async {
        var services: [ConnectorsViewState.ServiceRow] = []
        for connector in AppModel.connectors.all {
            let account = await AppModel.connectors.account(connector.id)
            let permissions = account?.permissions ?? ConnectorPermissions.defaults(for: connector)
            services.append(ConnectorsViewState.ServiceRow(
                id: connector.id,
                name: connector.name,
                account: account?.label,
                needsSetup: await needsSetup(connector),
                setupNote: setupNote(for: connector),
                capabilities: connector.capabilities.map { capability in
                    ConnectorsViewState.CapabilityRow(
                        id: capability.id.rawValue,
                        title: capability.title,
                        summary: capability.summary,
                        isWrite: capability.isWrite,
                        grant: permissions.grant(for: capability.id, in: connector)
                    )
                }
            ))
        }
        connectors.services = services
        connectorHosts = await AppModel.connectors.allowedHosts()
    }

    /// True when the service cannot even be offered yet: an OAuth service with no client ID, or a
    /// token service that has no token.
    private func needsSetup(_ connector: any Connector) async -> Bool {
        guard await AppModel.connectors.account(connector.id) == nil else { return false }
        switch connector.auth {
        case .oauth:
            return await AppModel.connectorConfiguration
                .clientID(for: AppModel.configurationKey(for: connector.id)) == nil
        case .token:
            return true
        }
    }

    private func setupNote(for connector: any Connector) -> String? {
        switch connector.auth {
        case let .token(instructions):
            "\(instructions.guidance)\n\nMake one at \(instructions.url.absoluteString)"
        case .oauth:
            """
            \(connector.name) needs an OAuth client of your own — Google won't let an app reach your \
            account without one, and one shipped inside the app would belong to whoever built it \
            rather than to you.

            At console.cloud.google.com: make a project, enable the Gmail and Drive APIs, then \
            Credentials → Create credentials → OAuth client ID → iOS, with the bundle ID \
            com.mouhamadmamane.voiceagent. Paste the client ID here; it isn't a secret.

            Then, on the OAuth consent screen, add your own Google account under Test users. Reading \
            mail is a restricted scope, so until the app is verified only accounts on that list can \
            allow it — and Google refuses with "access blocked" rather than explaining why. While the \
            project is in Testing, the connection lasts seven days before it asks again.
            """
        }
    }

    // MARK: Connecting

    func connect(_ serviceID: String) {
        guard let connector = AppModel.connectors.connector(serviceID) else { return }
        guard case let .oauth(base) = connector.auth else { return }
        connectors.error = nil
        connectors.connecting = serviceID

        Task { @MainActor in
            defer { connectors.connecting = nil }
            do {
                let key = AppModel.configurationKey(for: serviceID)
                guard let clientID = await AppModel.connectorConfiguration.clientID(for: key) else {
                    throw OAuthError.notConfigured(connector.name)
                }
                let flow = OAuthFlow(configuration: base.with(clientID: clientID))
                guard let url = flow.authorizationURL else { throw OAuthError.notConfigured(connector.name) }

                let callback = try await signIn(at: url, scheme: flow.configuration.callbackScheme)
                let code = try flow.code(from: callback)
                let session = URLSessionConnectorSession()
                let response = try await session.send(flow.exchangeRequest(code: code))
                let authorization = try OAuthFlow.authorization(from: response)

                try await AppModel.connectors.connect(
                    serviceID, label: await label(for: connector, authorization: authorization),
                    authorization: authorization
                )
                await refreshConnectors()
                PrivacySafeLogger.shared.log(.counter(name: "connector.connected", value: 1))
            } catch {
                connectors.error = (error as? CustomStringConvertible)?.description
                    ?? "That didn't connect."
                PrivacySafeLogger.shared.log(.error(domain: "connector", code: "connect_failed"))
            }
        }
    }

    /// The token a user pasted: GitHub's personal access token, or a Google client ID.
    func submitConnectorSecret(_ serviceID: String, _ value: String) {
        guard let connector = AppModel.connectors.connector(serviceID) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connectors.error = nil

        Task { @MainActor in
            switch connector.auth {
            case .oauth:
                await AppModel.connectorConfiguration.set(
                    trimmed, for: AppModel.configurationKey(for: serviceID)
                )
                await refreshConnectors()
            case .token:
                do {
                    let authorization = ConnectorAuthorization(accessToken: trimmed)
                    try await AppModel.connectors.connect(
                        serviceID, label: await label(for: connector, authorization: authorization),
                        authorization: authorization
                    )
                    await refreshConnectors()
                } catch {
                    connectors.error = (error as? CustomStringConvertible)?.description
                        ?? "That token didn't work."
                }
            }
        }
    }

    func disconnect(_ serviceID: String) {
        Task { @MainActor in
            try? await AppModel.connectors.disconnect(serviceID)
            await refreshConnectors()
        }
    }

    /// Who the account belongs to, asked of the service itself so the user sees the address they
    /// actually signed in with rather than one the app guessed.
    private func label(for connector: any Connector, authorization: ConnectorAuthorization) async -> String {
        let identified = try? await connector.identify(auth: authorization)
        return identified ?? connector.name
    }

    /// Gmail and Drive are one Google project with one OAuth client, so the client ID is asked for
    /// once and used by both. Making someone paste the same string twice is how they end up with
    /// two projects and one of them misconfigured.
    static func configurationKey(for connectorID: String) -> String {
        ["gmail", "drive"].contains(connectorID) ? "google" : connectorID
    }

    /// Safari's own sign-in sheet. `prefersEphemeralWebBrowserSession` is deliberately off: the
    /// point is to use the session the user already has, so they are not made to type a password
    /// into a window this app put on screen.
    private func signIn(at url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.badCallback)
                }
            }
            session.presentationContextProvider = AppModel.signInAnchor
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { continuation.resume(throwing: OAuthError.badCallback) }
        }
    }

    static let signInAnchor = SignInAnchor()
}

/// Tells `ASWebAuthenticationSession` which window to hang the sheet on.
final class SignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
