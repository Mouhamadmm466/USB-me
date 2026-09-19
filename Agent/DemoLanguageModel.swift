import Core
import Foundation

/// Deterministic keyword-based stand-in for Nemotron, used ONLY for UI tests and the Simulator's
/// explicit "demo mode" (the UI labels it). It emits the same JSON contract so the full
/// validator → resolver → confirmation → executor path is exercised. Never used on device builds
/// with installed models.
public struct DemoLanguageModel: LanguageModel {
    public let modelIdentifier = "demo-keyword-model"

    public init() {}

    public func prepare(cacheablePrefix: String) async throws {}

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let output = Self.respond(to: Self.utterance(in: request), hasPending: request.suffix.contains("Pending action"))
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(LLMGenerationStats()))
            continuation.finish()
        }
    }

    static func utterance(in request: LLMRequest) -> String {
        guard let line = request.suffix.components(separatedBy: "\n").last(where: { $0.hasPrefix("User: ") }) else { return "" }
        var text = String(line.dropFirst(6))
        if let end = text.range(of: "<|im_end|>") { text = String(text[..<end.lowerBound]) }
        return text
    }

    static func respond(to utterance: String, hasPending: Bool) -> String {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func json(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        if let range = lower.range(of: #"^(text|message|tell)\s+(\w+)\s+(that\s+)?"#, options: .regularExpression) {
            let parts = lower[range].split(separator: " ")
            let name = parts.count > 1 ? String(parts[1]).capitalized : "Alex"
            var body = String(text[range.upperBound...])
            if body.isEmpty { return #"{"type":"clarification","speech":"What should the message say?"}"# }
            body = body.prefix(1).uppercased() + body.dropFirst()
            return #"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"\#(json(name))","message":"\#(json(body))"},"requires_confirmation":true}"#
        }
        if let range = lower.range(of: #"^call\s+"#, options: .regularExpression) {
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return #"{"type":"proposed_action","tool":"initiate_call","arguments":{"contact_query":"\#(json(name))"},"requires_confirmation":true}"#
        }
        if lower.contains("calendar") || lower.contains("schedule") {
            let when = lower.contains("tomorrow") ? "tomorrow" : "today"
            return #"{"type":"proposed_action","tool":"get_calendar_events","arguments":{"when":"\#(when)"},"requires_confirmation":false}"#
        }
        if let range = lower.range(of: #"^remind me to\s+"#, options: .regularExpression) {
            let title = String(text[range.upperBound...])
            return #"{"type":"proposed_action","tool":"create_reminder","arguments":{"title":"\#(json(title))"},"requires_confirmation":true}"#
        }
        if lower.hasPrefix("open maps") {
            return #"{"type":"proposed_action","tool":"open_supported_app","arguments":{"app":"maps"},"requires_confirmation":false}"#
        }
        if hasPending {
            return #"{"type":"answer","speech":"Okay."}"#
        }
        return #"{"type":"answer","speech":"This is demo mode. Install the on-device models to talk to the real assistant."}"#
    }
}
