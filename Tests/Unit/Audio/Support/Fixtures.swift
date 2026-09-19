import Foundation
import Testing

/// `Tests/Audio/Fixtures/manifest.json` (written by `Scripts/generate_audio_fixtures.sh`).
struct FixtureManifest: Decodable {
    let version: Int
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let fixtures: [Fixture]

    func fixtures(ofKind kind: String) -> [Fixture] {
        fixtures.filter { $0.kind == kind }
    }

    func fixture(named file: String) -> Fixture? {
        fixtures.first { $0.file == file }
    }
}

struct Fixture: Decodable, CustomTestStringConvertible {
    let file: String
    let kind: String
    let text: String?
    let voice: String?
    let snr: Double?
    let noise: String?
    let durationSeconds: Double
    /// [start, end] seconds of speech.
    let speechWindows: [[Double]]
    let userText: String?
    let userVoice: String?
    let userStartSeconds: Double?
    let assistantWindows: [[Double]]?
    let userWindows: [[Double]]?

    var windows: [ClosedRange<Double>] { speechWindows.compactMap(Self.range) }
    var userRanges: [ClosedRange<Double>] { (userWindows ?? []).compactMap(Self.range) }
    var assistantRanges: [ClosedRange<Double>] { (assistantWindows ?? []).compactMap(Self.range) }

    var testDescription: String { file }

    private static func range(_ pair: [Double]) -> ClosedRange<Double>? {
        guard pair.count == 2, pair[0] <= pair[1] else { return nil }
        return pair[0] ... pair[1]
    }
}

enum Fixtures {
    /// `Tests/Audio/Fixtures`, located relative to this source file (no bundle resources).
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // Audio
        .deletingLastPathComponent() // Unit
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Audio/Fixtures", isDirectory: true)

    static func url(_ file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    static func manifest() throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url("manifest.json")))
    }

    /// All fixtures from the manifest (empty if it cannot be read; the manifest test reports why).
    static var all: [Fixture] {
        (try? manifest().fixtures) ?? []
    }

    static func all(ofKind kind: String) -> [Fixture] {
        all.filter { $0.kind == kind }
    }

    static func samples(_ file: String) throws -> [Float] {
        try WAVReader.read(url(file)).mono
    }
}
