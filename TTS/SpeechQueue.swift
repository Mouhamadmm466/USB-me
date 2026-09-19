import Core
import Foundation
import Telemetry

/// Speaks text through a synthesizer and a player with chunked, pipelined synthesis
/// (chunk N+1 is synthesized while chunk N plays) and fast cancellation (PRD §6.1, §6.3).
///
/// Implements `SpeechOutput` for the coordinator. `interrupt()` is the barge-in path (the waiting
/// `speak` returns `.interrupted`); `stop()` silences without signalling barge-in.
public actor SpeechQueue: SpeechOutput {
    private let synthesizer: (any SpeechSynthesizer)?
    private let player: (any AudioPlaying)?
    private let chunker: SpeechChunker
    private let metrics: PerformanceMetrics?
    private let tracker: SpokenTextTracker
    private var generation = 0
    private var interruptedGeneration: Int?

    /// - Parameters:
    ///   - synthesizer: nil when no TTS engine is available (simulator): speech is shown, not played.
    ///   - tracker: records what is currently being spoken so barge-in detection can tell the
    ///     assistant's own echo from the user.
    public init(
        synthesizer: (any SpeechSynthesizer)?,
        player: (any AudioPlaying)?,
        chunker: SpeechChunker = SpeechChunker(),
        tracker: SpokenTextTracker = SpokenTextTracker(),
        metrics: PerformanceMetrics? = nil
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.chunker = chunker
        self.tracker = tracker
        self.metrics = metrics
    }

    public nonisolated var spokenText: SpokenTextTracker { tracker }

    public func speak(_ text: String) async -> SpeechOutputResult {
        generation += 1
        let myGeneration = generation
        guard let synthesizer, let player else { return .finished }
        let chunks = chunker.chunks(for: text)
        guard !chunks.isEmpty else { return .finished }
        let started = Stopwatch()
        tracker.begin(text)
        defer { tracker.end() }

        // Pipeline: always keep the next chunk's synthesis running while the current one plays.
        var pending: Task<SynthesizedAudio?, Never>? = Task { try? await synthesizer.synthesize(chunks[0]) }
        for index in chunks.indices {
            guard let task = pending, let audio = await task.value else { return .finished }
            pending = index + 1 < chunks.count ? Task { [chunk = chunks[index + 1]] in try? await synthesizer.synthesize(chunk) } : nil
            if isCancelled(myGeneration) {
                pending?.cancel()
                return result(for: myGeneration)
            }
            if index == 0 {
                await metrics?.record(.ttsTimeToFirstAudio, milliseconds: started.elapsedMilliseconds)
            }
            do {
                try await player.play(audio)
            } catch {
                pending?.cancel()
                return result(for: myGeneration)
            }
            if isCancelled(myGeneration) {
                pending?.cancel()
                return result(for: myGeneration)
            }
        }
        return .finished
    }

    /// Barge-in: stop now and report `.interrupted` to the waiting `speak`.
    public func interrupt() async {
        interruptedGeneration = generation
        generation += 1
        await player?.stopPlayback()
    }

    public func stop() async {
        generation += 1
        await player?.stopPlayback()
    }

    public func setDucked(_ ducked: Bool) async {
        await player?.setDucked(ducked)
    }

    private func isCancelled(_ myGeneration: Int) -> Bool { generation != myGeneration }

    private func result(for myGeneration: Int) -> SpeechOutputResult {
        interruptedGeneration == myGeneration ? .interrupted : .finished
    }
}
