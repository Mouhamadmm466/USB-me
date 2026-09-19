import AVFAudio
import Foundation

public enum AudioResamplerError: Error, Sendable, Equatable {
    case unsupportedFormat
    case converterUnavailable
    case bufferAllocationFailed
    case formatMismatch
    case conversionFailed(code: Int)
}

/// Streaming format converter for the capture path: whatever PCM format the input node
/// delivers (48 kHz on the built-in mic, 16/24 kHz on Bluetooth HFP, mono or stereo) →
/// 16 kHz mono Float32, wrapping `AVAudioConverter`.
///
/// - The converter keeps its filter state between calls, so consecutive tap buffers are
///   resampled as one continuous stream (no discontinuity at buffer seams).
/// - Priming: `.none` for live capture (the converter never waits for look-ahead input, so each
///   call returns everything the supplied input allows; the filter's few-millisecond group delay
///   remains) and `.normal` for one-shot conversions (latency-compensated, exact output length).
/// - Input is handed to the converter in exactly the slices it requests (see `ConverterFeed`).
/// - Channels: stereo is downmixed; any other layout keeps channel 0 only (voice processing on
///   macOS can expose extra non-microphone channels that must not be mixed in).
///
/// Not thread-safe (`AVAudioPCMBuffer` is not `Sendable`): confine an instance to one thread or
/// queue. `AudioEngine` only uses it inside the input-tap callback, under its capture lock.
public final class StreamingResampler {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var outputBuffer: AVAudioPCMBuffer
    private let feed = ConverterFeed()

    public init(
        inputFormat: AVAudioFormat,
        outputSampleRate: Double = 16_000,
        primeMethod: AVAudioConverterPrimeMethod = .none
    ) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, outputSampleRate > 0 else {
            throw AudioResamplerError.unsupportedFormat
        }
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioResamplerError.unsupportedFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw AudioResamplerError.converterUnavailable
        }
        converter.primeMethod = primeMethod
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.downmix = inputFormat.channelCount == 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096) else {
            throw AudioResamplerError.bufferAllocationFailed
        }
        self.inputFormat = inputFormat
        outputFormat = output
        self.converter = converter
        outputBuffer = buffer
    }

    /// Output frames per input frame.
    public var ratio: Double { outputFormat.sampleRate / inputFormat.sampleRate }

    /// Converts one input buffer. `body` receives the converted mono samples; the pointer is
    /// only valid during the call. Pass `endOfStream: true` to flush the filter tail (the
    /// resampler must be `reset()` before it is used again).
    public func convert(
        _ buffer: AVAudioPCMBuffer,
        endOfStream: Bool = false,
        _ body: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
        guard buffer.format.isEqual(inputFormat) else { throw AudioResamplerError.formatMismatch }
        let needed = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        if outputBuffer.frameCapacity < needed {
            // Rare: only when a larger tap buffer than ever before arrives.
            guard let larger = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: needed) else {
                throw AudioResamplerError.bufferAllocationFailed
            }
            outputBuffer = larger
        }
        feed.load(buffer, endOfStream: endOfStream)
        defer { feed.clear() }

        let feed = self.feed
        while true {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { requested, inputStatus in
                feed.next(requested, inputStatus)
            }
            if status == .error {
                throw AudioResamplerError.conversionFailed(code: error?.code ?? -1)
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0, let channels = outputBuffer.floatChannelData {
                body(UnsafeBufferPointer(start: channels[0], count: produced))
            }
            // `.haveData` means the output buffer filled up and more output may be pending.
            if status != .haveData || produced == 0 { break }
        }
    }

    /// Convenience: converts `channels` (one array per input channel, equal lengths).
    public func convert(channels: [[Float]], endOfStream: Bool = false) throws -> [Float] {
        guard let buffer = Self.makeBuffer(format: inputFormat, channels: channels) else {
            throw AudioResamplerError.bufferAllocationFailed
        }
        var output: [Float] = []
        output.reserveCapacity(Int(Double(buffer.frameLength) * ratio) + 64)
        try convert(buffer, endOfStream: endOfStream) { output.append(contentsOf: $0) }
        return output
    }

    /// Clears the filter state (next input is treated as a new stream).
    public func reset() {
        converter.reset()
    }

    /// One-shot mono resampling (e.g. TTS audio whose rate differs from the player's format).
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard inputRate > 0, outputRate > 0 else { throw AudioResamplerError.unsupportedFormat }
        if inputRate == outputRate || samples.isEmpty { return samples }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioResamplerError.unsupportedFormat
        }
        let resampler = try StreamingResampler(inputFormat: format, outputSampleRate: outputRate, primeMethod: .normal)
        return try resampler.convert(channels: [samples], endOfStream: true)
    }

    /// Builds a non-interleaved Float32 buffer in `format` from per-channel sample arrays.
    /// Missing channels are filled with channel 0.
    static func makeBuffer(format: AVAudioFormat, channels: [[Float]]) -> AVAudioPCMBuffer? {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let first = channels.first,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, first.count))),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(first.count)
        for channel in 0 ..< Int(format.channelCount) {
            let source = channel < channels.count ? channels[channel] : first
            let count = min(source.count, first.count)
            source.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    destination[channel].update(from: base, count: count)
                }
            }
        }
        return buffer
    }
}

/// Feeds one input buffer to `AVAudioConverter`'s input block **in the slices it asks for**.
///
/// The converter consumes at most `inNumberOfPackets` frames of each buffer the block returns
/// and silently drops the rest (measured: a 4800-frame tap buffer loses 704 frames when the
/// converter asks for 4096), so the block copies exactly the requested frames into a scratch
/// buffer and keeps a read offset.
///
/// `@unchecked Sendable`: the block is invoked synchronously inside
/// `AVAudioConverter.convert(to:error:withInputFrom:)` on the calling thread, and the owning
/// `StreamingResampler` is confined to a single thread, so the fields are never touched
/// concurrently. The scratch buffer is only refilled on the next block call, as the converter
/// requires.
private final class ConverterFeed: @unchecked Sendable {
    private var source: AVAudioPCMBuffer?
    private var offset: AVAudioFrameCount = 0
    private var scratch: AVAudioPCMBuffer?
    private(set) var endOfStream = false

    func load(_ buffer: AVAudioPCMBuffer, endOfStream: Bool) {
        source = buffer
        offset = 0
        self.endOfStream = endOfStream
    }

    func clear() {
        source = nil
        offset = 0
    }

    func next(_ requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let source, offset < source.frameLength, requested > 0 else {
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        let count = min(requested, source.frameLength - offset)
        if scratch == nil || scratch!.frameCapacity < count || !scratch!.format.isEqual(source.format) {
            scratch = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: max(count, 4096))
        }
        guard let scratch else {
            status.pointee = .noDataNow
            return nil
        }
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        for index in 0 ..< min(from.count, to.count) {
            guard let input = from[index].mData, let output = to[index].mData else { continue }
            output.copyMemory(
                from: input.advanced(by: Int(offset) * bytesPerFrame),
                byteCount: Int(count) * bytesPerFrame
            )
        }
        scratch.frameLength = count
        offset += count
        status.pointee = .haveData
        return scratch
    }
}
