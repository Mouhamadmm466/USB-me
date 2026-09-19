import Foundation
import Telemetry
#if os(iOS)
import AVFAudio
#endif

/// Platform-neutral audio port type (mirrors `AVAudioSession.Port`, which is iOS-only), so the
/// routing policy can be unit-tested on macOS.
public enum AudioPortType: String, Sendable, CaseIterable, Codable {
    case builtInReceiver
    case builtInSpeaker
    case builtInMic
    case headphones
    case headsetMic
    case lineOut
    case lineIn
    case bluetoothHFP
    case bluetoothA2DP
    case bluetoothLE
    case airPlay
    case carAudio
    case usbAudio
    case hdmi
    case displayPort
    case continuityMicrophone
    case virtual
    case other
}

/// A port as the router sees it. Port *names* are deliberately not kept: they can contain
/// personal names ("Alex's AirPods") and must never reach logs.
public struct AudioPortDescriptor: Sendable, Equatable {
    public let type: AudioPortType
    /// The device runs its own echo cancellation / noise reduction (many car kits and headsets).
    public let hasHardwareVoiceCallProcessing: Bool

    public init(_ type: AudioPortType, hasHardwareVoiceCallProcessing: Bool = false) {
        self.type = type
        self.hasHardwareVoiceCallProcessing = hasHardwareVoiceCallProcessing
    }
}

/// Where the assistant's voice comes out.
public enum AudioRouteKind: String, Sendable, CaseIterable, Codable, SafeLabelConvertible {
    case builtInReceiver
    case builtInSpeaker
    /// Wired headphones or headset.
    case wired
    case bluetoothHFP
    case bluetoothA2DP
    case bluetoothLE
    case airPlay
    case carAudio
    case usb
    /// HDMI, DisplayPort, line out: external speakers or a TV.
    case external
    /// No output port.
    case none
    case unknown
}

/// Where the microphone signal comes from.
public enum AudioInputKind: String, Sendable, CaseIterable, Codable, SafeLabelConvertible {
    case builtInMic
    case wiredMic
    case bluetoothHFP
    case bluetoothLE
    case carAudio
    case usb
    case continuity
    case lineIn
    case none
    case other
}

/// How likely the assistant's own voice reaches the microphone.
public enum EchoRisk: Int, Sendable, CaseIterable, Codable, Comparable, SafeLabelConvertible {
    case low = 0
    case medium = 1
    case high = 2

    public var safeLabelText: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }

    public static func < (lhs: EchoRisk, rhs: EchoRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Classified current audio route.
public struct AudioRoute: Sendable, Equatable {
    public let output: AudioRouteKind
    public let input: AudioInputKind
    /// The output device processes voice itself (echo cancellation in the headset / car).
    public let hasHardwareVoiceProcessing: Bool
    public let echoRisk: EchoRisk

    /// - Parameter echoRisk: override; by default derived from the output kind.
    public init(
        output: AudioRouteKind,
        input: AudioInputKind,
        hasHardwareVoiceProcessing: Bool = false,
        echoRisk: EchoRisk? = nil
    ) {
        self.output = output
        self.input = input
        self.hasHardwareVoiceProcessing = hasHardwareVoiceProcessing
        self.echoRisk = echoRisk
            ?? AudioRouter.echoRisk(output: output, hasHardwareVoiceProcessing: hasHardwareVoiceProcessing)
    }

    public var kind: AudioRouteKind { output }

    /// Only the user can hear the assistant (earpiece or head-worn device). Losing such a route
    /// must not move a private reply onto the loudspeaker. A2DP is treated as private because it
    /// is almost always headphones on a phone (a Bluetooth speaker cannot be told apart).
    public var isPrivateListening: Bool {
        switch output {
        case .builtInReceiver, .wired, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: true
        case .builtInSpeaker, .airPlay, .carAudio, .usb, .external, .none, .unknown: false
        }
    }

    public static let unknown = AudioRoute(output: .unknown, input: .other)
}

/// What the audio stack should do after a route change. A set, so several can apply.
public struct AudioRouteResponse: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Stop assistant playback (Apple's guideline: pause when the old device went away).
    public static let stopPlayback = AudioRouteResponse(rawValue: 1 << 0)
    /// Check the engine is still running and restart it if the change stopped it.
    public static let verifyEngineRunning = AudioRouteResponse(rawValue: 1 << 1)
    /// Someone changed the category; re-apply ours (idempotent).
    public static let reapplySessionConfiguration = AudioRouteResponse(rawValue: 1 << 2)
    /// Echo risk may have changed; update barge-in strictness.
    public static let refreshEchoPolicy = AudioRouteResponse(rawValue: 1 << 3)
    /// No usable input: capture cannot continue until the route changes again.
    public static let suspendCapture = AudioRouteResponse(rawValue: 1 << 4)
}

/// Platform-neutral route-change reason (mirrors `AVAudioSession.RouteChangeReason`).
public enum AudioRouteChangeReason: String, Sendable, CaseIterable, Codable, SafeLabelConvertible {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
}

/// Pure routing logic: classification, echo risk and the route-change policy.
public enum AudioRouter {
    /// Classifies a route from its ports. The first output is the primary one; echo risk is
    /// the highest over all outputs (mirroring to a TV makes the whole route risky).
    public static func classify(outputs: [AudioPortDescriptor], inputs: [AudioPortDescriptor]) -> AudioRoute {
        let primary = outputs.first.map { outputKind(for: $0.type) } ?? AudioRouteKind.none
        let input = inputs.first.map { inputKind(for: $0.type) } ?? AudioInputKind.none
        let hardwareProcessing = outputs.first?.hasHardwareVoiceCallProcessing ?? false
        let risks = outputs.map {
            echoRisk(output: outputKind(for: $0.type), hasHardwareVoiceProcessing: $0.hasHardwareVoiceCallProcessing)
        }
        return AudioRoute(
            output: primary,
            input: input,
            hasHardwareVoiceProcessing: hardwareProcessing,
            echoRisk: risks.max() ?? echoRisk(output: primary, hasHardwareVoiceProcessing: false)
        )
    }

    public static func outputKind(for type: AudioPortType) -> AudioRouteKind {
        switch type {
        case .builtInReceiver: .builtInReceiver
        case .builtInSpeaker: .builtInSpeaker
        case .headphones: .wired
        case .bluetoothHFP: .bluetoothHFP
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE: .bluetoothLE
        case .airPlay: .airPlay
        case .carAudio: .carAudio
        case .usbAudio: .usb
        case .hdmi, .displayPort, .lineOut: .external
        case .builtInMic, .headsetMic, .lineIn, .continuityMicrophone, .virtual, .other: .unknown
        }
    }

    public static func inputKind(for type: AudioPortType) -> AudioInputKind {
        switch type {
        case .builtInMic: .builtInMic
        case .headsetMic: .wiredMic
        case .bluetoothHFP: .bluetoothHFP
        case .bluetoothLE: .bluetoothLE
        case .carAudio: .carAudio
        case .usbAudio: .usb
        case .continuityMicrophone: .continuity
        case .lineIn: .lineIn
        default: .other
        }
    }

    /// Echo risk of an output. High on the loudspeaker and on anything that plays into the room
    /// (AirPlay, car, TV); low on head-worn devices; one step lower when the device cancels
    /// echo itself.
    public static func echoRisk(output: AudioRouteKind, hasHardwareVoiceProcessing: Bool) -> EchoRisk {
        let base: EchoRisk = switch output {
        case .builtInSpeaker, .airPlay, .carAudio, .external: .high
        case .builtInReceiver, .bluetoothA2DP, .usb, .unknown: .medium
        case .wired, .bluetoothHFP, .bluetoothLE, .none: .low
        }
        guard hasHardwareVoiceProcessing, base > .low else { return base }
        return EchoRisk(rawValue: base.rawValue - 1) ?? .low
    }

    /// Policy for a route change (Apple, "Responding to audio route changes"): when the old
    /// device became unavailable and the new route is public, stop playback so a private reply
    /// never jumps to the loudspeaker; after any device change make sure the engine still runs.
    public static func response(
        to reason: AudioRouteChangeReason,
        previous: AudioRoute?,
        current: AudioRoute
    ) -> AudioRouteResponse {
        var response: AudioRouteResponse = [.refreshEchoPolicy]
        switch reason {
        case .oldDeviceUnavailable:
            response.insert(.verifyEngineRunning)
            // Unknown previous route: be conservative and treat it as private.
            let wasPrivate = previous?.isPrivateListening ?? true
            if wasPrivate, !current.isPrivateListening {
                response.insert(.stopPlayback)
            }
        case .newDeviceAvailable, .wakeFromSleep, .unknown:
            response.insert(.verifyEngineRunning)
        case .categoryChange:
            response.formUnion([.reapplySessionConfiguration, .verifyEngineRunning])
        case .noSuitableRouteForCategory:
            response.formUnion([.stopPlayback, .suspendCapture])
        case .override, .routeConfigurationChange:
            break
        }
        if current.output == .none { response.insert(.stopPlayback) }
        if current.input == .none { response.insert(.suspendCapture) }
        return response
    }
}

#if os(iOS)
extension AudioPortType {
    public init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInReceiver: self = .builtInReceiver
        case .builtInSpeaker: self = .builtInSpeaker
        case .builtInMic: self = .builtInMic
        case .headphones: self = .headphones
        case .headsetMic: self = .headsetMic
        case .lineOut: self = .lineOut
        case .lineIn: self = .lineIn
        case .bluetoothHFP: self = .bluetoothHFP
        case .bluetoothA2DP: self = .bluetoothA2DP
        case .bluetoothLE: self = .bluetoothLE
        case .airPlay: self = .airPlay
        case .carAudio: self = .carAudio
        case .usbAudio: self = .usbAudio
        case .HDMI: self = .hdmi
        case .displayPort: self = .displayPort
        case .continuityMicrophone: self = .continuityMicrophone
        case .virtual: self = .virtual
        default: self = .other
        }
    }
}

extension AudioPortDescriptor {
    public init(_ port: AVAudioSessionPortDescription) {
        self.init(AudioPortType(port.portType), hasHardwareVoiceCallProcessing: port.hasHardwareVoiceCallProcessing)
    }
}

extension AudioRoute {
    public init(_ route: AVAudioSessionRouteDescription) {
        self = AudioRouter.classify(
            outputs: route.outputs.map(AudioPortDescriptor.init),
            inputs: route.inputs.map(AudioPortDescriptor.init)
        )
    }
}

extension AudioRouteChangeReason {
    public init(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .newDeviceAvailable: self = .newDeviceAvailable
        case .oldDeviceUnavailable: self = .oldDeviceUnavailable
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        case .wakeFromSleep: self = .wakeFromSleep
        case .noSuitableRouteForCategory: self = .noSuitableRouteForCategory
        case .routeConfigurationChange: self = .routeConfigurationChange
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
#endif
