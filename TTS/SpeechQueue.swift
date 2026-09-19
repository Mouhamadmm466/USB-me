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
    private var firstAudioObserver: (@Sendable (TimeInterval) -> Void)?

    private struct Lead {
        let text: String
        let generation: Int
        /// True when the lead-in played to the end.
        let playback: Task<Bool, Never>
    }

    private var lead: Lead?
    private var leadInterrupted = false
    /// `speak` calls in progress: a lead-in never starts over a reply already being spoken.
    private var activeSpeaks = 0

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

    /// Receives `ProcessInfo.systemUptime` at the moment each reply's first chunk starts playing
    /// (for end-of-speech → first-audio latency).
    public func observeFirstAudio(_ observer: (@Sendable (TimeInterval) -> Void)?) {
        firstAudioObserver = observer
    }

    /// Starts speaking `lead` before the rest of the reply exists (the lead-in of a confirmation
    /// whose recipient is already known, e.g. "Text Alex Kim:"). A following `speak` whose text
    /// starts with `lead` continues after it with the rest; any other `speak` cuts it.
    public func speakLead(_ lead: String) async {
        let text = lead.trimmingCharacters(in: .whitespaces)
        guard let synthesizer, let player, self.lead == nil, activeSpeaks == 0, !text.isEmpty else { return }
        generation += 1
        let myGeneration = generation
        leadInterrupted = false
        tracker.begin(text)
        let started = Stopwatch()
        let playback = Task { () -> Bool in
            guard let audio = try? await synthesizer.synthesize(SpeechTextNormalizer.normalize(text)),
                  await self.leadIsCurrent(myGeneration) else {
                await self.leadFinished(myGeneration)
                return false
            }
            await self.firstAudioStarting(synthesisMilliseconds: started.elapsedMilliseconds)
            let played: Bool
            do {
                try await player.play(audio)
                played = true
            } catch {
                played = false
            }
            await self.leadFinished(myGeneration)
            return played
        }
        self.lead = Lead(text: text, generation: myGeneration, playback: playback)
    }

    public func speak(_ text: String) async -> SpeechOutputResult {
        guard let synthesizer, let player else { return .finished }
        activeSpeaks += 1
        defer { activeSpeaks -= 1 }
        if let lead {
            self.lead = nil
            if leadInterrupted {
                // The user barged in over the lead-in: the rest of this reply is not spoken.
                leadInterrupted = false
                tracker.end()
                return .interrupted
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if lead.generation == generation, trimmed.hasPrefix(lead.text) {
                let rest = String(trimmed.dropFirst(lead.text.count)).trimmingCharacters(in: .whitespaces)
                return await continueAfter(lead, chunks: chunker.chunks(for: rest), text: text, synthesizer: synthesizer, player: player)
            }
            // A different reply than the lead-in announced: cut it and speak this one.
            lead.playback.cancel()
            await player.stopPlayback()
        }
        let chunks = chunker.chunks(for: text)
        generation += 1
        let myGeneration = generation
        guard !chunks.isEmpty else { return .finished }
        let started = Stopwatch()
        tracker.begin(text)
        defer { if generation == myGeneration || lead == nil { tracker.end() } }
        return await play(chunks, from: 0, generation: myGeneration, firstSynthesis: Task { try? await synthesizer.synthesize(chunks[0]) },
                          started: started, synthesizer: synthesizer, player: player)
    }

    /// The lead-in is (or was) playing: synthesize the rest's first chunk meanwhile, wait for the
    /// lead-in to finish, then play the rest in the lead's generation.
    private func continueAfter(
        _ lead: Lead, chunks: [String], text: String, synthesizer: any SpeechSynthesizer, player: any AudioPlaying
    ) async -> SpeechOutputResult {
        let myGeneration = lead.generation
        tracker.begin(text)
        defer { tracker.end() }
        guard !chunks.isEmpty else {
            _ = await lead.playback.value
            return result(for: myGeneration)
        }
        let next = Task { [chunk = chunks[0]] in try? await synthesizer.synthesize(chunk) }
        let leadPlayed = await lead.playback.value
        if !leadPlayed || isCancelled(myGeneration) {
            next.cancel()
            return result(for: myGeneration)
        }
        return await play(chunks, from: 0, generation: myGeneration, firstSynthesis: next, started: nil,
                          synthesizer: synthesizer, player: player)
    }

    /// Pipeline: always keep the next chunk's synthesis running while the current one plays.
    private func play(
        _ chunks: [String], from startIndex: Int, generation myGeneration: Int, firstSynthesis: Task<SynthesizedAudio?, Never>,
        started: Stopwatch?, synthesizer: any SpeechSynthesizer, player: any AudioPlaying
    ) async -> SpeechOutputResult {
        var pending: Task<SynthesizedAudio?, Never>? = firstSynthesis
        for index in startIndex..<chunks.count {
            guard let task = pending, let audio = await task.value else { return .finished }
            pending = index + 1 < chunks.count ? Task { [chunk = chunks[index + 1]] in try? await synthesizer.synthesize(chunk) } : nil
            if isCancelled(myGeneration) {
                pending?.cancel()
                return result(for: myGeneration)
            }
            if index == 0, let started {
                await firstAudioStarting(synthesisMilliseconds: started.elapsedMilliseconds)
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

    private func firstAudioStarting(synthesisMilliseconds: Double) async {
        firstAudioObserver?(ProcessInfo.processInfo.systemUptime)
        await metrics?.record(.ttsTimeToFirstAudio, milliseconds: synthesisMilliseconds)
    }

    private func leadIsCurrent(_ leadGeneration: Int) -> Bool { generation == leadGeneration }

    /// A lead-in that no `speak` picked up ends the audible text when it finishes.
    private func leadFinished(_ leadGeneration: Int) {
        if lead?.generation == leadGeneration, generation == leadGeneration {
            tracker.end()
        }
    }

    /// Barge-in: stop now and report `.interrupted` to the waiting `speak` (or to the `speak`
    /// that would have continued an interrupted lead-in).
    public func interrupt() async {
        interruptedGeneration = generation
        if lead != nil {
            leadInterrupted = true
            // Nobody else will end the audible text of a lead-in no `speak` picked up yet.
            if activeSpeaks == 0 { tracker.end() }
        }
        generation += 1
        await player?.stopPlayback()
    }

    public func stop() async {
        generation += 1
        if let lead {
            lead.playback.cancel()
            self.lead = nil
            if activeSpeaks == 0 { tracker.end() }
        }
        leadInterrupted = false
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
