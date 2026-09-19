import Core
import Foundation
import Testing
@testable import Models

/// Downloads the smallest pinned file (Silero VAD, 885 KB) from its real Hugging Face URL through
/// the app's own downloader (range transfer, SHA-256, atomic activation) and loads it back through
/// `verifiedFileURL`. Opt-in because it needs the network: `VOICEAGENT_LIVE_DOWNLOAD=1 swift test
/// --filter LiveDownloadTests`.
@Suite struct LiveDownloadTests {
    static let enabled = ProcessInfo.processInfo.environment["VOICEAGENT_LIVE_DOWNLOAD"] == "1"

    @Test(.enabled(if: enabled)) func smallestPinnedFileDownloadsVerifiesAndActivates() async throws {
        let asr = try #require(ModelManifest.v1.pack(for: .asr))
        let silero = try #require(asr.file(named: ModelFileName.sileroVAD))
        let pack = ModelPack(id: "live-download-test", role: .asr, displayName: "Silero VAD (live test)", license: asr.license,
                             files: [silero], minimumAppVersion: asr.minimumAppVersion, minimumIOSVersion: asr.minimumIOSVersion,
                             minimumPhysicalMemoryGB: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(root: root)
        _ = try await manager.install(pack)
        let url = try await manager.verifiedFileURL(for: pack, filename: silero.filename)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        #expect(size == silero.bytes)
    }
}
