import Core
import Foundation

/// Scripted message composer. Each `compose` consumes the next scripted outcome (default `.sent`)
/// and records `.messageComposed`. When texting is unavailable nothing is presented or recorded.
public actor FakeMessageComposer: MessageComposing {
    private var canSend: Bool
    private var scriptedOutcomes: [MessageComposeOutcome]
    private var defaultOutcome: MessageComposeOutcome
    private let recorder: SideEffectRecorder
    public private(set) var composeAttempts = 0

    public init(
        canSendText: Bool = true,
        outcomes: [MessageComposeOutcome] = [],
        defaultOutcome: MessageComposeOutcome = .sent,
        recorder: SideEffectRecorder
    ) {
        canSend = canSendText
        scriptedOutcomes = outcomes
        self.defaultOutcome = defaultOutcome
        self.recorder = recorder
    }

    public func setCanSendText(_ value: Bool) {
        canSend = value
    }

    /// Outcomes returned by the next `compose` calls, in order.
    public func script(_ outcomes: [MessageComposeOutcome]) {
        scriptedOutcomes = outcomes
    }

    public func canSendText() async -> Bool { canSend }

    public func compose(recipients: [String], body: String) async -> MessageComposeOutcome {
        composeAttempts += 1
        guard canSend else { return .unavailable }
        let outcome = scriptedOutcomes.isEmpty ? defaultOutcome : scriptedOutcomes.removeFirst()
        if outcome != .unavailable {
            await recorder.record(.messageComposed(recipients: recipients, body: body, outcome: outcome))
        }
        return outcome
    }
}

/// Scripted call launcher. Records `.callStarted` only when the call flow "opened".
public actor FakeCallLauncher: CallLaunching {
    private var canCall: Bool
    private var opens: Bool
    private let recorder: SideEffectRecorder
    public private(set) var callAttempts = 0

    public init(canPlaceCalls: Bool = true, opens: Bool = true, recorder: SideEffectRecorder) {
        canCall = canPlaceCalls
        self.opens = opens
        self.recorder = recorder
    }

    public func setCanPlaceCalls(_ value: Bool) {
        canCall = value
    }

    /// Whether the next `startCall` succeeds.
    public func setOpens(_ value: Bool) {
        opens = value
    }

    public func canPlaceCalls() async -> Bool { canCall }

    public func startCall(toDigits digits: String) async -> Bool {
        callAttempts += 1
        guard canCall, opens, CallURLBuilder.telURL(digits: digits) != nil else { return false }
        await recorder.record(.callStarted(digits: digits))
        return true
    }
}

/// Records `.appOpened`. Apps in `unavailableApps` fail to open.
public actor FakeAppLauncher: AppLaunching {
    private var unavailableApps: Set<SupportedApp>
    private let recorder: SideEffectRecorder

    public init(unavailableApps: Set<SupportedApp> = [], recorder: SideEffectRecorder) {
        self.unavailableApps = unavailableApps
        self.recorder = recorder
    }

    public func setUnavailable(_ apps: Set<SupportedApp>) {
        unavailableApps = apps
    }

    public func open(_ app: SupportedApp, query: String?) async -> Bool {
        guard !unavailableApps.contains(app), AppURLBuilder.url(for: app, query: query) != nil else { return false }
        await recorder.record(.appOpened(app, query: app == .maps ? AppURLBuilder.sanitizedQuery(query) : nil))
        return true
    }
}
