import Synchronization

/// Fans values out to any number of `AsyncStream` subscribers. Each subscriber gets its own
/// buffer (policy chosen at init), and a subscriber that stops iterating is dropped
/// automatically. Used for session events and UI levels, which several components observe.
final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id: UInt64? = state.withLock { state in
            guard !state.finished else { return nil }
            defer { state.nextID += 1 }
            return state.nextID
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        state.withLock { $0.continuations[id] = continuation }
        return stream
    }

    func yield(_ value: Element) {
        let targets = state.withLock { Array($0.continuations) }
        for (id, continuation) in targets {
            if case .terminated = continuation.yield(value) { remove(id) }
        }
    }

    /// Finishes every subscriber; later `subscribe()` calls return finished streams.
    func finish() {
        let targets = state.withLock { state in
            state.finished = true
            let values = Array(state.continuations.values)
            state.continuations.removeAll()
            return values
        }
        for continuation in targets { continuation.finish() }
    }

    private func remove(_ id: UInt64) {
        _ = state.withLock { $0.continuations.removeValue(forKey: id) }
    }
}
