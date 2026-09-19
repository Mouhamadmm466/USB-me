import Core
import Foundation

/// Deterministic stand-in for Nemotron used by unit/integration tests and the harness's
/// "pipeline" mode. It sees exactly the request the real model would and returns scripted JSON.
public final class ScriptedLanguageModel: LanguageModel, @unchecked Sendable {
    public let modelIdentifier = "scripted"
    private let lock = NSLock()
    private let responder: @Sendable (LLMRequest) -> String
    private var _requests: [LLMRequest] = []

    /// - Parameter responder: returns the raw model output for a request (use
    ///   `ScriptedLanguageModel.utterance(in:)` to read the user's words).
    public init(responder: @escaping @Sendable (LLMRequest) -> String) {
        self.responder = responder
    }

    /// Replies by exact (case-insensitive) utterance; unknown utterances get `fallback`.
    public convenience init(_ table: [String: String], fallback: String = #"{"type":"answer","speech":"Okay."}"#) {
        let lowered = Dictionary(uniqueKeysWithValues: table.map { ($0.key.lowercased(), $0.value) })
        self.init { request in
            lowered[ScriptedLanguageModel.utterance(in: request).lowercased()] ?? fallback
        }
    }

    public var requests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    public func prepare(cacheablePrefix: String) async throws {}

    private var _primedHeads: [String] = []

    /// Suffix heads passed to `prime`, in order.
    public var primedHeads: [String] {
        lock.lock(); defer { lock.unlock() }
        return _primedHeads
    }

    public func prime(cacheablePrefix: String, suffixHead: String) async {
        lock.withLock { _primedHeads.append(suffixHead) }
    }

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock(); _requests.append(request); lock.unlock()
        let output = responder(request)
        return AsyncThrowingStream { continuation in
            // Stream in small chunks like a real decoder would.
            var index = output.startIndex
            while index < output.endIndex {
                let next = output.index(index, offsetBy: 7, limitedBy: output.endIndex) ?? output.endIndex
                continuation.yield(.text(String(output[index..<next])))
                index = next
            }
            var stats = LLMGenerationStats()
            stats.stoppedReason = "scripted"
            continuation.yield(.completed(stats))
            continuation.finish()
        }
    }

    /// The final "User: …" line of the request suffix.
    public static func utterance(in request: LLMRequest) -> String {
        let lines = request.suffix.components(separatedBy: "\n")
        guard let line = lines.last(where: { $0.hasPrefix("User: ") }) else { return "" }
        var text = String(line.dropFirst("User: ".count))
        if let end = text.range(of: "<|im_end|>") { text = String(text[..<end.lowerBound]) }
        return text
    }
}
