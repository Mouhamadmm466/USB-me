import Foundation
import Telemetry
#if os(iOS)
import AVFAudio
#endif

/// Why the system interrupted the session.
public enum AudioInterruptionReason: String, Sendable, CaseIterable, SafeLabelConvertible {
    /// Another session took the hardware: phone/FaceTime call, Siri, alarm, another app.
    case otherAudio
    /// The built-in microphone was muted in hardware (iPad Smart Folio closed).
    case builtInMicMuted
    /// The route was disconnected (iOS 17+, only when interruption on disconnect is preferred).
    case routeDisconnected
    case unknown
}

/// Session-level events, surfaced to the engine (restart/stop) and to the agent (state machine).
public enum AudioSessionEvent: Sendable, Equatable {
    /// The system deactivated the session; the engine has been stopped by the system.
    case interruptionBegan(reason: AudioInterruptionReason)
    /// Resume only if `shouldResume` (Apple: otherwise wait for the user to restart).
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: AudioRouteChangeReason, previous: AudioRoute?, current: AudioRoute)
    /// Media services died; every audio object is invalid until `mediaServicesWereReset`.
    case mediaServicesWereLost
    /// Media services restarted; audio objects must be rebuilt and the session reconfigured.
    case mediaServicesWereReset
}

public struct AudioSessionConfiguration: Sendable, Equatable {
    /// ~20 ms: short enough that `stopPlayback` silences output within one IO buffer and the
    /// capture path sees fresh audio, long enough to keep voice-processing CPU reasonable.
    public var preferredIOBufferDuration: TimeInterval = 0.02
    /// nil keeps the hardware rate (48 kHz on the built-in route). Forcing 16 kHz would save a
    /// resampling step but degrade Kokoro's 24 kHz output on the loudspeaker.
    public var preferredSampleRate: Double?
    /// Lets output-only Bluetooth devices (speakers, some headphones) be used for playback.
    public var allowBluetoothA2DP = true
    /// Keeps UI haptics working while the microphone is live.
    public var allowHapticsAndSystemSoundsDuringRecording = true

    public init() {}
}

public enum AudioSessionError: Error, Sendable, Equatable {
    case configurationFailed(code: Int)
    case activationFailed(code: Int)
}

/// Owner of the process-wide audio session. Abstracted so the engine (and tests) do not depend
/// on `AVAudioSession`, which does not exist on macOS.
public protocol AudioSessionManaging: AnyObject, Sendable {
    /// Applies category, mode, options and IO preferences. Idempotent.
    func configure() throws
    /// Activates the session. Blocking: call off the main thread.
    func activate() throws
    /// Deactivates with `.notifyOthersOnDeactivation` so interrupted apps (music) resume.
    func deactivate()
    /// A new subscription to session events (each caller gets its own stream).
    func events() -> AsyncStream<AudioSessionEvent>
    var currentRoute: AudioRoute { get }
    var isActive: Bool { get }
}

/// Configures and observes `AVAudioSession` for a full-duplex voice assistant.
///
/// ## Category, mode and voice processing (decision)
///
/// Category `.playAndRecord`, options `.defaultToSpeaker` (a phone held at arm's length must not
/// talk through the earpiece), `.allowBluetoothHFP` (the iOS 26 SDK deprecates `.allowBluetooth`
/// in favour of this identical-valued option; HFP carries the AirPods microphone) and
/// `.allowBluetoothA2DP` (output-only devices). Mode **`.voiceChat`**, **and** voice processing
/// enabled on the engine's input node (`AudioEngine` calls
/// `AVAudioInputNode.setVoiceProcessingEnabled(true)` before it starts).
///
/// Why both, rather than `.default` + voice processing:
/// - Echo cancellation comes only from the voice-processing I/O unit, and it can only subtract
///   what it plays itself. That is why TTS plays through an `AVAudioPlayerNode` in the *same*
///   `AVAudioEngine` whose input has voice processing on: the reference signal is exactly the
///   assistant's voice. The mode alone does nothing here — Apple documents that `.voiceChat`
///   without the voice-processing unit loads no echo cancellation and lowers output level.
/// - Once the voice-processing unit runs, iOS switches a non-chat session to voice-chat mode
///   implicitly. Declaring `.voiceChat` up front makes the configured state equal the running
///   state: no mode flip at engine start (which surfaces as a `categoryChange` route change and
///   a spurious engine configuration change right after start), deterministic VoIP routing
///   (Bluetooth over HFP, so AirPods use their own microphone), voice-optimised tuning, and the
///   system microphone modes (Voice Isolation) that only chat-mode apps get.
/// - Rejected alternatives: `.default` + `prefersEchoCancelledInput` (iOS 18.2) is tuned for
///   music, works only on 2024+ iPhones, and the reference device is an iPhone 15 Pro;
///   `.bluetoothHighQualityRecording` (iOS 26) requires mode `.default` and Apple warns it adds
///   input latency, so it is not suitable for real-time conversation.
///
/// Costs accepted: HFP narrows Bluetooth bandwidth (fine for 16 kHz ASR and speech TTS), the
/// system volume slider becomes the call volume, and other apps' audio is interrupted while the
/// session is active (it resumes on `deactivate()` thanks to `.notifyOthersOnDeactivation`).
///
/// ## Concurrency
/// `@unchecked Sendable`: the only mutable state (activity flag, observer tokens) is guarded by
/// `lock`; `AVAudioSession` itself is thread-safe and `Sendable` in the iOS 26 SDK.
/// Notifications are parsed synchronously on the posting thread into `Sendable` events and
/// fanned out to subscribers; no audio object is touched from the observer blocks.
public final class AudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    /// `AVAudioSession` is a process singleton; share one manager so observers are not duplicated.
    public static let shared = AudioSessionManager()

    public let configuration: AudioSessionConfiguration
    private let logger: PrivacySafeLogger?
    private let broadcaster = AsyncBroadcaster<AudioSessionEvent>(bufferingPolicy: .bufferingNewest(32))
    private let lock = NSLock()
    private var active = false
    private var observers: [NSObjectProtocol] = []

    public init(configuration: AudioSessionConfiguration = .init(), logger: PrivacySafeLogger? = .shared) {
        self.configuration = configuration
        self.logger = logger
        #if os(iOS)
        registerObservers()
        #endif
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        broadcaster.finish()
    }

    public var isActive: Bool {
        lock.withLock { active }
    }

    public func events() -> AsyncStream<AudioSessionEvent> {
        broadcaster.subscribe()
    }

    /// Delivers an event to every subscriber (also used by tests to simulate the system).
    func post(_ event: AudioSessionEvent) {
        broadcaster.yield(event)
    }

    private func setActive(_ value: Bool) {
        lock.withLock { active = value }
    }

    #if os(iOS)

    public var currentRoute: AudioRoute {
        AudioRoute(AVAudioSession.sharedInstance().currentRoute)
    }

    public func configure() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if configuration.allowBluetoothA2DP { options.insert(.allowBluetoothA2DP) }
        do {
            // Re-applying an identical category still posts a route change; skip it so a
            // `categoryChange` → reapply cycle cannot loop.
            if session.category != .playAndRecord || session.mode != .voiceChat
                || !session.categoryOptions.isSuperset(of: options) {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
            try session.setPreferredIOBufferDuration(configuration.preferredIOBufferDuration)
            if let rate = configuration.preferredSampleRate {
                try session.setPreferredSampleRate(rate)
            }
            if configuration.allowHapticsAndSystemSoundsDuringRecording,
               !session.allowHapticsAndSystemSoundsDuringRecording {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
        } catch {
            logger?.log(.error(domain: "audio_session", code: "configure_failed"))
            throw AudioSessionError.configurationFailed(code: (error as NSError).code)
        }
    }

    public func activate() throws {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            setActive(true)
        } catch {
            // e.g. AVAudioSession.ErrorCode.insufficientPriority while a phone call is active.
            logger?.log(.error(domain: "audio_session", code: "activate_failed"))
            throw AudioSessionError.activationFailed(code: (error as NSError).code)
        }
    }

    public func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger?.log(.error(domain: "audio_session", code: "deactivate_failed"))
        }
        setActive(false)
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let tokens: [NSObjectProtocol] = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                self?.handleInterruption(note.userInfo)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
                self?.handleRouteChange(note.userInfo)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: nil) { [weak self] _ in
                self?.setActive(false)
                self?.logger?.log(.error(domain: "audio_session", code: "media_services_lost"))
                self?.post(.mediaServicesWereLost)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                self?.setActive(false)
                self?.logger?.log(.error(domain: "audio_session", code: "media_services_reset"))
                self?.post(.mediaServicesWereReset)
            },
        ]
        lock.withLock { observers = tokens }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let info,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            setActive(false)
            var reason = AudioInterruptionReason.otherAudio
            if let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt,
               let systemReason = AVAudioSession.InterruptionReason(rawValue: rawReason) {
                switch systemReason {
                case .builtInMicMuted: reason = .builtInMicMuted
                case .routeDisconnected: reason = .routeDisconnected
                default: reason = .otherAudio
                }
            }
            logger?.log(.safety(check: "audio_interruption", outcome: SafeLabel(reason)))
            post(.interruptionBegan(reason: reason))
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            logger?.log(.safety(check: "audio_interruption", outcome: shouldResume ? "ended_resume" : "ended"))
            post(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ info: [AnyHashable: Any]?) {
        let reason = (info?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            .map(AudioRouteChangeReason.init) ?? .unknown
        let previous = (info?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map(AudioRoute.init)
        let current = currentRoute
        logger?.log(.audioRoute(kind: SafeLabel(current.output)))
        post(.routeChanged(reason: reason, previous: previous, current: current))
    }

    #else

    // macOS has no AVAudioSession: the system manages devices. These no-ops keep the engine
    // and the pure logic usable (and testable) on the Mac.

    public var currentRoute: AudioRoute { .unknown }

    public func configure() throws {}

    public func activate() throws {
        setActive(true)
    }

    public func deactivate() {
        setActive(false)
    }

    #endif
}
