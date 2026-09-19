import Foundation

/// Knows when assistant audio is — or was very recently — coming out of the speaker, so the
/// capture path can flag frames (`AudioFrame.assistantWasSpeaking`).
///
/// Times are seconds on one monotonic clock (the engine uses host time, the same clock as the
/// input tap's `AVAudioTime`, so a buffer captured 100 ms before the tap callback runs is still
/// judged at its real capture time). An *episode* runs from the first scheduled buffer until
/// the last one has been played back (or playback is stopped); audio is considered audible
/// during the episode and for `echoTail` afterwards (room reverberation, acoustic path and AEC
/// re-convergence). Episodes that start within the tail of the previous one are merged.
public struct PlaybackActivityTracker: Sendable, Equatable {
    public var echoTail: TimeInterval
    /// Buffers scheduled but not yet played back.
    public private(set) var outstandingBuffers = 0
    private var activeSince: TimeInterval?
    private var lastEpisode: ClosedRange<TimeInterval>?

    public init(echoTail: TimeInterval = 0.25) {
        self.echoTail = max(0, echoTail)
    }

    public var isPlaying: Bool { outstandingBuffers > 0 }

    public mutating func bufferScheduled(at time: TimeInterval) {
        if outstandingBuffers == 0 {
            if let episode = lastEpisode, time <= episode.upperBound + echoTail {
                activeSince = episode.lowerBound
            } else {
                activeSince = time
            }
        }
        outstandingBuffers += 1
    }

    /// One scheduled buffer finished playing back.
    public mutating func bufferFinished(at time: TimeInterval) {
        guard outstandingBuffers > 0 else { return }
        outstandingBuffers -= 1
        if outstandingBuffers == 0 { closeEpisode(at: time) }
    }

    /// Playback was stopped: every outstanding buffer is gone.
    public mutating func allStopped(at time: TimeInterval) {
        guard outstandingBuffers > 0 else { return }
        outstandingBuffers = 0
        closeEpisode(at: time)
    }

    public func isAssistantAudible(at time: TimeInterval) -> Bool {
        isAssistantAudible(from: time, to: time)
    }

    /// True if any part of `[start, end]` overlaps playback or its echo tail.
    public func isAssistantAudible(from start: TimeInterval, to end: TimeInterval) -> Bool {
        if let since = activeSince, end >= since { return true }
        if let episode = lastEpisode, end >= episode.lowerBound, start < episode.upperBound + echoTail {
            return true
        }
        return false
    }

    public mutating func reset() {
        outstandingBuffers = 0
        activeSince = nil
        lastEpisode = nil
    }

    private mutating func closeEpisode(at time: TimeInterval) {
        let start = activeSince ?? time
        lastEpisode = start ... max(start, time)
        activeSince = nil
    }
}
