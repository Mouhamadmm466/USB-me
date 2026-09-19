import Foundation

/// Minimal RIFF/WAVE reader for test fixtures: PCM 8/16/24/32-bit integer or 32-bit float,
/// any channel count (returned per channel), skips unknown chunks (LIST, fact…).
struct WAVFile: Equatable {
    let sampleRate: Double
    let bitsPerSample: Int
    let isFloat: Bool
    /// One array per channel, samples in [-1, 1].
    let channels: [[Float]]

    var channelCount: Int { channels.count }
    var mono: [Float] { channels.first ?? [] }
    var duration: TimeInterval { sampleRate > 0 ? Double(mono.count) / sampleRate : 0 }
}

enum WAVReaderError: Error, Equatable {
    case notRIFF
    case notWAVE
    case missingFormat
    case missingData
    case unsupportedFormat(tag: Int, bits: Int)
    case truncated
}

enum WAVReader {
    static func read(_ url: URL) throws -> WAVFile {
        try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> WAVFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw WAVReaderError.truncated }
        guard String(decoding: bytes[0 ..< 4], as: UTF8.self) == "RIFF" else { throw WAVReaderError.notRIFF }
        guard String(decoding: bytes[8 ..< 12], as: UTF8.self) == "WAVE" else { throw WAVReaderError.notWAVE }

        var offset = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var payload: ArraySlice<UInt8>?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
            let size = Int(readUInt32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count else { throw WAVReaderError.truncated }
            switch id {
            case "fmt ":
                guard size >= 16 else { throw WAVReaderError.missingFormat }
                var tag = Int(readUInt16(bytes, body))
                let channels = Int(readUInt16(bytes, body + 2))
                let rate = Int(readUInt32(bytes, body + 4))
                let bits = Int(readUInt16(bytes, body + 14))
                if tag == 0xFFFE, size >= 40 {
                    // WAVE_FORMAT_EXTENSIBLE: the sub-format GUID starts with the real tag.
                    tag = Int(readUInt16(bytes, body + 24))
                }
                format = (tag, channels, rate, bits)
            case "data":
                payload = bytes[body ..< body + size]
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        guard let format, format.channels > 0 else { throw WAVReaderError.missingFormat }
        guard let payload else { throw WAVReaderError.missingData }

        let bytesPerSample = format.bits / 8
        let isFloat = format.tag == 3
        guard (format.tag == 1 && [8, 16, 24, 32].contains(format.bits)) || (isFloat && format.bits == 32) else {
            throw WAVReaderError.unsupportedFormat(tag: format.tag, bits: format.bits)
        }
        let frameBytes = bytesPerSample * format.channels
        let frameCount = payload.count / frameBytes
        var channels = Array(repeating: [Float](repeating: 0, count: frameCount), count: format.channels)
        let base = payload.startIndex
        for frame in 0 ..< frameCount {
            for channel in 0 ..< format.channels {
                let at = base + frame * frameBytes + channel * bytesPerSample
                channels[channel][frame] = decode(bytes, at: at, bits: format.bits, isFloat: isFloat)
            }
        }
        return WAVFile(sampleRate: Double(format.rate), bitsPerSample: format.bits, isFloat: isFloat, channels: channels)
    }

    private static func decode(_ bytes: [UInt8], at index: Int, bits: Int, isFloat: Bool) -> Float {
        switch (bits, isFloat) {
        case (8, false):
            return (Float(bytes[index]) - 128) / 128
        case (16, false):
            return Float(Int16(bitPattern: readUInt16(bytes, index))) / 32_768
        case (24, false):
            let value = Int32(bytes[index]) | Int32(bytes[index + 1]) << 8 | Int32(Int8(bitPattern: bytes[index + 2])) << 16
            return Float(value) / 8_388_608
        case (32, false):
            return Float(Int32(bitPattern: readUInt32(bytes, index))) / 2_147_483_648
        default:
            return Float(bitPattern: readUInt32(bytes, index))
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
