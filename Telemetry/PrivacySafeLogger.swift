import Foundation
import os

/// A label that is safe to write to production logs.
///
/// It can only be created from a string *literal* (compile-time constant) or from a type that
/// explicitly opts into `SafeLabelConvertible` (closed enums such as `AgentState`). There is no
/// initializer that accepts a runtime `String`, so transcripts, contact names, message bodies,
/// calendar titles and file names cannot reach the logger by accident.
public struct SafeLabel: Sendable, Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let description: String

    public init(stringLiteral value: StaticString) {
        description = value.description
    }

    public init<T: SafeLabelConvertible>(_ value: T) {
        description = value.safeLabelText
    }
}

/// Opt-in for closed vocabularies (enums) whose values are known at compile time.
public protocol SafeLabelConvertible {
    var safeLabelText: String { get }
}

extension SafeLabelConvertible where Self: RawRepresentable, RawValue == String {
    public var safeLabelText: String { rawValue }
}

/// Production telemetry vocabulary: event type, timing, status and anonymized codes only.
public enum TelemetryEvent: Sendable, Equatable {
    case stateTransition(from: SafeLabel, to: SafeLabel, reason: SafeLabel)
    case stageLatency(stage: LatencyStage, milliseconds: Int)
    case modelLifecycle(model: SafeLabel, phase: SafeLabel, milliseconds: Int?)
    case toolExecution(tool: SafeLabel, status: SafeLabel)
    case permission(kind: SafeLabel, status: SafeLabel)
    case error(domain: SafeLabel, code: SafeLabel)
    case memory(footprintMB: Int, availableMB: Int?)
    case thermal(state: SafeLabel)
    case audioRoute(kind: SafeLabel)
    case safety(check: SafeLabel, outcome: SafeLabel)
    case download(model: SafeLabel, status: SafeLabel, bytes: Int64?)
    case counter(name: SafeLabel, value: Int)

    /// Rendered with no user content; safe to mark `.public` in os_log.
    public var renderedLine: String {
        switch self {
        case let .stateTransition(from, to, reason): "state \(from) -> \(to) [\(reason)]"
        case let .stageLatency(stage, ms): "latency \(stage.rawValue)=\(ms)ms"
        case let .modelLifecycle(model, phase, ms): "model \(model) \(phase)" + (ms.map { " \($0)ms" } ?? "")
        case let .toolExecution(tool, status): "tool \(tool) \(status)"
        case let .permission(kind, status): "permission \(kind)=\(status)"
        case let .error(domain, code): "error \(domain).\(code)"
        case let .memory(footprint, available): "memory footprint=\(footprint)MB" + (available.map { " available=\($0)MB" } ?? "")
        case let .thermal(state): "thermal \(state)"
        case let .audioRoute(kind): "audio-route \(kind)"
        case let .safety(check, outcome): "safety \(check)=\(outcome)"
        case let .download(model, status, bytes): "download \(model) \(status)" + (bytes.map { " bytes=\($0)" } ?? "")
        case let .counter(name, value): "counter \(name)=\(value)"
        }
    }
}

/// Stages measured for the PRD §13 performance budget.
public enum LatencyStage: String, Sendable, Codable, CaseIterable, SafeLabelConvertible {
    /// End of the user's last speech frame → first assistant audio (includes endpoint silence).
    case endOfSpeechToFirstAudio
    /// Endpoint decision → first assistant audio (ASR final + LLM + resolution + first TTS chunk).
    case endpointToFirstAudio
    case endpointToFinalTranscript
    case partialTranscript
    case llmPromptEval
    case llmTimeToFirstToken
    case llmStructuredResult
    case llmTotal
    case ttsTimeToFirstAudio
    case ttsSynthesis
    case toolExecution
    case bargeInToSilence
    case modelLoadASR
    case modelLoadLLM
    case modelLoadTTS
    case contactResolution
    /// Linking an utterance to the user's own world and building the notes block (V2).
    case personalContext
}

/// Privacy-safe logger. Production output contains only `TelemetryEvent`s.
public final class PrivacySafeLogger: @unchecked Sendable {
    public static let shared = PrivacySafeLogger()

    private let logger = Logger(subsystem: "app.voiceagent", category: "agent")
    private let lock = NSLock()
    private var ring: [TimedEvent] = []
    private let ringCapacity: Int
    private var sinks: [@Sendable (TimedEvent) -> Void] = []

    public struct TimedEvent: Sendable, Equatable {
        public let date: Date
        public let event: TelemetryEvent
    }

    public init(ringCapacity: Int = 500) {
        self.ringCapacity = ringCapacity
    }

    public func log(_ event: TelemetryEvent) {
        let line = event.renderedLine
        logger.info("\(line, privacy: .public)")
        let timed = TimedEvent(date: Date(), event: event)
        lock.lock()
        ring.append(timed)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        let currentSinks = sinks
        lock.unlock()
        for sink in currentSinks { sink(timed) }
    }

    /// Recent events for the on-device diagnostics screen (never leaves the device).
    public func recentEvents() -> [TimedEvent] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    /// Test hook: observe events as they are logged.
    public func addSink(_ sink: @escaping @Sendable (TimedEvent) -> Void) {
        lock.lock(); sinks.append(sink); lock.unlock()
    }

    public func removeAllSinks() {
        lock.lock(); sinks.removeAll(); lock.unlock()
    }

    public func clear() {
        lock.lock(); ring.removeAll(); lock.unlock()
    }

    /// Debug-only diagnostics that may contain user content. Compiled out of release builds and
    /// always redacted in the unified log.
    public func debugSensitive(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .private)")
        #endif
    }
}
