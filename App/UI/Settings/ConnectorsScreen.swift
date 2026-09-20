import Connectors
import Core
import SwiftUI

/// What the Connected services screens draw, already formatted.
struct ConnectorsViewState: Equatable {
    struct CapabilityRow: Identifiable, Equatable {
        let id: String
        var title: String
        /// One line in the user's terms: what allowing this actually lets it do.
        var summary: String
        var isWrite: Bool
        var grant: ConnectorGrant
    }

    struct ServiceRow: Identifiable, Equatable {
        let id: String
        var name: String
        /// The account, when connected: an address or a username.
        var account: String?
        var isConnected: Bool { account != nil }
        /// True when the service needs a client ID the user has not supplied yet.
        var needsSetup: Bool
        var setupNote: String?
        var capabilities: [CapabilityRow]

        /// "Reading only", "Reading, and asking before it writes", "Not connected".
        var summary: String {
            guard isConnected else { return needsSetup ? "Needs setting up" : "Not connected" }
            let on = capabilities.count { $0.grant == .on }
            let asking = capabilities.count { $0.grant == .ask }
            if on == 0, asking == 0 { return "Nothing allowed" }
            if asking == 0 { return on == 1 ? "1 thing allowed" : "\(on) things allowed" }
            return "\(on) allowed, \(asking) asking"
        }
    }

    var services: [ServiceRow] = []
    /// Set while a sign-in is in flight, so the row can say so.
    var connecting: String?
    var error: String?
}

struct ConnectorsIntents {
    var connect: @MainActor (_ serviceID: String) -> Void = { _ in }
    var disconnect: @MainActor (_ serviceID: String) -> Void = { _ in }
    var setGrant: @MainActor (_ serviceID: String, _ capabilityID: String, _ grant: ConnectorGrant) -> Void = { _, _, _ in }
    /// The user pasted a token (GitHub) or a client ID (Google).
    var submitSecret: @MainActor (_ serviceID: String, _ value: String) -> Void = { _, _ in }
    var refresh: @MainActor () async -> Void = {}

    static let inert = ConnectorsIntents()
}

/// The list of services, and what each one is allowed to do.
///
/// Deliberately not one switch per service. "Read my email" and "send email as me" are different
/// decisions, and a single "Connect Gmail" toggle that silently means both is how apps end up with
/// permissions nobody remembers granting. Everything starts at reading; writing starts at asking.
struct ConnectorsScreen: View {
    let state: ConnectorsViewState
    let intents: ConnectorsIntents

    var body: some View {
        List {
            ForEach(state.services) { service in
                Section {
                    NavigationLink {
                        ConnectorDetailScreen(service: service, intents: intents)
                            .navigationTitle(service.name)
                    } label: {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: Self.symbol(for: service.id))
                                .font(.system(size: 16, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(service.isConnected ? Palette.clay : Palette.inkSecondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(service.name).textStyle(.body).foregroundStyle(Palette.ink)
                                Text(service.account ?? service.summary)
                                    .textStyle(.footnote)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                            Spacer(minLength: 0)
                            if state.connecting == service.id {
                                ProgressView().controlSize(.mini)
                            } else if service.isConnected {
                                Text(service.summary)
                                    .textStyle(.footnote)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                        }
                    }
                }
            }

            if let error = state.error {
                Section {
                    Text(error)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                EmptyView()
            } footer: {
                SettingsFooter("A connected service is read through the same door as everything else: the internet setting decides whether anything may go, each request is logged, and nothing is ever copied into what I keep about you unless you say so.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
        .task { await intents.refresh() }
    }

    static func symbol(for id: String) -> String {
        switch id {
        case "gmail": "envelope.fill"
        case "drive": "folder.fill.badge.person.crop"
        case "github": "chevron.left.forwardslash.chevron.right"
        default: "link"
        }
    }
}

/// One service: how to connect it, and a switch for every single thing it can do.
struct ConnectorDetailScreen: View {
    let service: ConnectorsViewState.ServiceRow
    let intents: ConnectorsIntents

    @State private var secret = ""
    @State private var confirmsDisconnect = false

    var body: some View {
        List {
            if !service.isConnected {
                Section {
                    if service.needsSetup {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            if let note = service.setupNote {
                                Text(note)
                                    .textStyle(.subheadline)
                                    .foregroundStyle(Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            SecureField("Paste it here", text: $secret)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save") { intents.submitSecret(service.id, secret); secret = "" }
                                .buttonStyle(.capsule(.prominent, size: .small, fullWidth: false))
                                .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.vertical, Spacing.xs)
                    } else {
                        Button("Connect \(service.name)") { intents.connect(service.id) }
                            .textStyle(.body, weight: .medium)
                    }
                } footer: {
                    SettingsFooter("Signing in happens in Safari, on \(service.name)'s own page. The app never sees your password, and the token it gets back is kept in the iPhone's keychain.")
                }
            }

            Section {
                ForEach(service.capabilities) { capability in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Picker(selection: Binding(
                            get: { capability.grant },
                            set: { intents.setGrant(service.id, capability.id, $0) }
                        )) {
                            ForEach(ConnectorGrant.allCases, id: \.self) { grant in
                                Text(grant.displayName).tag(grant)
                            }
                        } label: {
                            RowLabel(title: capability.title, subtitle: capability.summary)
                        }
                        .pickerStyle(.menu)
                    }
                    .disabled(!service.isConnected)
                }
            } header: {
                SettingsHeader("What it may do")
            } footer: {
                SettingsFooter("Anything set to off isn't offered to me at all — I can't ask for what I've never been told about. Anything that writes shows you exactly what it would do first.")
            }

            if service.isConnected {
                Section {
                    Button(role: .destructive) { confirmsDisconnect = true } label: {
                        Text("Disconnect").textStyle(.body, weight: .medium).foregroundStyle(Palette.danger)
                    }
                    .confirmationDialog("Disconnect \(service.name)?", isPresented: $confirmsDisconnect,
                                        titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) { intents.disconnect(service.id) }
                    } message: {
                        Text("The token is removed from this iPhone. Nothing I already learned is forgotten — you can do that in What I know.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.groupedCanvas)
        .font(.dm(.body))
        .tint(Palette.clay)
    }
}
