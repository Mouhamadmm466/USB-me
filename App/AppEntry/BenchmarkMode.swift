import Core
import DeviceBenchmark
import Foundation
import LLM
import Models
import SwiftUI
import Telemetry
import TTS
#if KOKORO_TTS
import KokoroTTS
#endif

/// Phase 1 physical-device feasibility benchmark, started with the `-RunBenchmark` launch argument
/// (see `Scripts/benchmark_device.sh`). Uses model files sideloaded into Documents/ModelImport/,
/// verifies every file's size and SHA-256 against the pinned manifest before loading, runs
/// `DeviceBenchmarkRunner`, and writes the JSON report to Documents/BenchmarkReports/.
@MainActor
@Observable
final class BenchmarkController {
    enum Phase: Equatable {
        case idle
        case verifying(String)
        case running(String, Double)
        case finished(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: BenchmarkReport?
    private(set) var verificationLines: [String] = []

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var importDirectory: URL { documents.appendingPathComponent("ModelImport", isDirectory: true) }
    static var reportsDirectory: URL { documents.appendingPathComponent("BenchmarkReports", isDirectory: true) }

    func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let files = try await verifyImportedModels()
            let audio = try Self.loadBundledUtterance()
            var configuration = BenchmarkConfiguration(
                whisperModel: files[ModelFileName.whisperBaseEn]!,
                vadModel: files[ModelFileName.sileroVAD],
                nemotronModel: files[ModelFileName.nemotronNano4B]!,
                synthesizer: nil,
                synthesizerLoader: nil,
                utteranceAudio: audio,
                utteranceReference: "text alex that i will be twenty minutes late",
                iterations: 5
            )
            #if KOKORO_TTS
            if let weights = files[ModelFileName.kokoroWeights], let voice = files[ModelFileName.kokoroVoiceAfHeart] {
                let kokoro = KokoroRuntime(modelURL: weights, voiceURL: voice)
                configuration.synthesizer = kokoro
                configuration.synthesizerLoader = {
                    let watch = Stopwatch()
                    try await kokoro.warmUp()
                    return watch.elapsedMilliseconds
                }
            }
            #endif
            let runner = DeviceBenchmarkRunner(configuration: configuration)
            var result = await runner.run { progress in
                Task { @MainActor in
                    if case let .stage(name, fraction) = progress { self.phase = .running(name, fraction) }
                }
            }
            result.notes.append(contentsOf: verificationLines)
            report = result
            try FileManager.default.createDirectory(at: Self.reportsDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = Self.reportsDirectory.appendingPathComponent("benchmark-\(result.environment.deviceModel)-\(stamp).json")
            try result.jsonData.write(to: url, options: .atomic)
            try result.jsonData.write(to: Self.reportsDirectory.appendingPathComponent("latest.json"), options: .atomic)
            phase = .finished(url)
        } catch {
            phase = .failed(String(describing: error))
            let failure = Self.reportsDirectory.appendingPathComponent("latest-error.txt")
            try? FileManager.default.createDirectory(at: Self.reportsDirectory, withIntermediateDirectories: true)
            try? String(describing: error).write(to: failure, atomically: true, encoding: .utf8)
        }
    }

    /// Size + full SHA-256 check of every imported file against `ModelManifest.v1`.
    private func verifyImportedModels() async throws -> [String: URL] {
        var verified: [String: URL] = [:]
        for pack in ModelManifest.v1.packs {
            for file in pack.files {
                let url = Self.importDirectory.appendingPathComponent(file.filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                phase = .verifying(file.filename)
                let watch = Stopwatch()
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size == file.bytes else { throw BenchmarkModeError.sizeMismatch(file.filename) }
                let digest = try await ModelIntegrity.sha256(of: url)
                guard digest == file.sha256 else { throw BenchmarkModeError.checksumMismatch(file.filename) }
                verificationLines.append("sha256 verified \(file.filename) in \(Int(watch.elapsedMilliseconds)) ms")
                verified[file.filename] = url
            }
        }
        for required in [ModelFileName.whisperBaseEn, ModelFileName.nemotronNano4B] where verified[required] == nil {
            throw BenchmarkModeError.missing(required)
        }
        return verified
    }

    static func loadBundledUtterance() throws -> [Float] {
        guard let url = Bundle.main.url(forResource: "benchmark_utterance", withExtension: "wav") else {
            throw BenchmarkModeError.missing("benchmark_utterance.wav")
        }
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
                return body.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 } }
            }
            offset += 8 + size + (size % 2)
        }
        throw BenchmarkModeError.missing("wav data chunk")
    }
}

enum BenchmarkModeError: Error, CustomStringConvertible {
    case missing(String)
    case sizeMismatch(String)
    case checksumMismatch(String)

    var description: String {
        switch self {
        case let .missing(name): "missing \(name)"
        case let .sizeMismatch(name): "size mismatch for \(name)"
        case let .checksumMismatch(name): "SHA-256 mismatch for \(name)"
        }
    }
}

struct BenchmarkView: View {
    @State private var controller = BenchmarkController()

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(statusText).font(.body.monospaced())
                }
                if let report = controller.report {
                    Section("Results (P50 / P95)") {
                        ForEach(Array(report.metrics.enumerated()), id: \.offset) { _, metric in
                            HStack {
                                Text("\(metric.stage).\(metric.name)").font(.caption.monospaced())
                                Spacer()
                                Text("\(format(metric.p50)) / \(format(metric.p95)) \(metric.unit)").font(.caption.monospaced())
                            }
                        }
                        Text("peak footprint \(Int(report.peakFootprintMB)) MB").font(.caption.monospaced())
                        Text("thermal \(report.thermalStates.joined(separator: " → "))").font(.caption.monospaced())
                    }
                    if !report.errors.isEmpty {
                        Section("Errors") { ForEach(report.errors, id: \.self) { Text($0).font(.caption) } }
                    }
                }
            }
            .navigationTitle("Device benchmark")
        }
        .task { await controller.run() }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: "Starting…"
        case let .verifying(file): "Verifying \(file)…"
        case let .running(stage, fraction): "\(stage) (\(Int(fraction * 100))%)"
        case let .finished(url): "Done: \(url.lastPathComponent)"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private func format(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}
