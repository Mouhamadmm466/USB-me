import CryptoKit
import Foundation
import Telemetry

// MARK: - Roles and well-known identifiers

/// What a model pack does in the voice pipeline. V1 has exactly one pack per role.
public enum ModelRole: String, Codable, Sendable, CaseIterable, SafeLabelConvertible {
    /// Speech recognition (whisper.cpp) and its Silero voice-activity model.
    case asr
    /// Reasoning (NVIDIA Nemotron on llama.cpp).
    case llm
    /// Speech synthesis (Kokoro on MLX).
    case tts
}

/// Stable identifiers of the V1 packs, for the composition root and the runtimes.
public enum ModelPackID {
    public static let whisperBaseEn = "whisper-base.en"
    public static let nemotronNano4B = "nemotron-3-nano-4b-q4_k_m"
    public static let kokoro82M = "kokoro-82m"
}

/// On-disk names of the V1 files (each is unique within its pack).
public enum ModelFileName {
    public static let whisperBaseEn = "ggml-base.en.bin"
    public static let sileroVAD = "ggml-silero-v6.2.0.bin"
    public static let nemotronNano4B = "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"
    public static let kokoroWeights = "kokoro-v1_0.safetensors"
    public static let kokoroVoiceAfHeart = "af_heart.safetensors"
}

// MARK: - Manifest types

/// One pinned file: exact source, upstream revision, size and SHA-256 (PRD §12).
public struct ModelFile: Codable, Sendable, Hashable {
    /// Name inside the pack's revision directory. A single, non-hidden path component.
    public let filename: String
    /// Revision-pinned (immutable) HTTPS download URL.
    public let sourceURL: URL
    /// Upstream repository, "owner/name" on Hugging Face.
    public let repository: String
    /// Upstream commit that `sourceURL` resolves at.
    public let revision: String
    /// Exact size in bytes.
    public let bytes: Int64
    /// Lowercase hex SHA-256 of the complete file.
    public let sha256: String

    public init(filename: String, sourceURL: URL, repository: String, revision: String, bytes: Int64, sha256: String) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.repository = repository
        self.revision = revision
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// A set of files that is installed, verified, activated and deleted as one unit.
public struct ModelPack: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let role: ModelRole
    /// User-facing name ("Speech recognition").
    public let displayName: String
    public let license: String
    public let files: [ModelFile]
    public let minimumAppVersion: String
    public let minimumIOSVersion: String
    /// Decimal gigabytes (10^9 bytes) of `ProcessInfo.physicalMemory`; see `DeviceProfile`.
    public let minimumPhysicalMemoryGB: Double

    public init(
        id: String,
        role: ModelRole,
        displayName: String,
        license: String,
        files: [ModelFile],
        minimumAppVersion: String,
        minimumIOSVersion: String,
        minimumPhysicalMemoryGB: Double
    ) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.license = license
        self.files = files
        self.minimumAppVersion = minimumAppVersion
        self.minimumIOSVersion = minimumIOSVersion
        self.minimumPhysicalMemoryGB = minimumPhysicalMemoryGB
    }

    /// Sum of all file sizes.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public func file(named filename: String) -> ModelFile? {
        files.first { $0.filename == filename }
    }

    /// Content-derived identifier of this exact set of files (16 hex characters).
    ///
    /// It names the on-disk directory `<root>/<packID>/<revision>/`. It is a SHA-256 over the pack
    /// id, the role and each file's name, size and SHA-256, so it changes whenever any pinned
    /// content changes and never changes for cosmetic edits (display name, licence text, a mirror
    /// URL). Changing the canonical form below orphans every installed pack; `ModelsTests` pins the
    /// V1 values to catch that.
    public var revision: String {
        var canonical = "voiceagent.model-pack.v1\n\(id)\n\(role.rawValue)\n"
        for file in files.sorted(by: { $0.filename < $1.filename }) {
            canonical += "\(file.filename)\t\(file.bytes)\t\(file.sha256.lowercased())\n"
        }
        return HexEncoding.string(SHA256.hash(data: Data(canonical.utf8)).prefix(8))
    }

    /// Rejects anything that could escape the storage root or weaken verification.
    public func validate() throws {
        guard Self.isSafePathComponent(id) else { throw ModelManifestError.invalidPackID(id) }
        guard !files.isEmpty else { throw ModelManifestError.emptyPack(packID: id) }
        var seen = Set<String>()
        for file in files {
            guard Self.isSafePathComponent(file.filename) else {
                throw ModelManifestError.invalidFilename(packID: id, filename: file.filename)
            }
            guard seen.insert(file.filename).inserted else {
                throw ModelManifestError.duplicateFilename(packID: id, filename: file.filename)
            }
            guard HexEncoding.isSHA256(file.sha256) else {
                throw ModelManifestError.invalidChecksum(packID: id, filename: file.filename)
            }
            guard file.bytes > 0 else { throw ModelManifestError.invalidSize(packID: id, filename: file.filename) }
            guard file.sourceURL.scheme?.lowercased() == "https", file.sourceURL.host != nil else {
                throw ModelManifestError.insecureSourceURL(packID: id, filename: file.filename)
            }
        }
        guard minimumPhysicalMemoryGB >= 0, SemanticVersion(minimumAppVersion) != nil,
              SemanticVersion(minimumIOSVersion) != nil else {
            throw ModelManifestError.invalidRequirements(packID: id)
        }
    }

    /// Letters, digits, `.`, `_`, `-`; 1–128 characters; not hidden; never `.` or `..`.
    static func isSafePathComponent(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), !value.hasPrefix(".") else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}

/// The complete list of model packs this app version may install and load. Compiled into the
/// app (no remote manifest), mirrored in `Scripts/model_manifest.json`.
public struct ModelManifest: Codable, Sendable, Hashable {
    public let manifestVersion: Int
    public let packs: [ModelPack]

    public init(manifestVersion: Int, packs: [ModelPack]) {
        self.manifestVersion = manifestVersion
        self.packs = packs
    }

    public var totalBytes: Int64 { packs.reduce(0) { $0 + $1.totalBytes } }

    public var allFiles: [ModelFile] { packs.flatMap(\.files) }

    public func pack(id: String) -> ModelPack? {
        packs.first { $0.id == id }
    }

    /// The pack that fills a role (V1 has exactly one per role).
    public func pack(for role: ModelRole) -> ModelPack? {
        packs.first { $0.role == role }
    }

    public func file(packID: String, filename: String) -> ModelFile? {
        pack(id: packID)?.file(named: filename)
    }

    public func validate() throws {
        var ids = Set<String>()
        for pack in packs {
            try pack.validate()
            guard ids.insert(pack.id).inserted else { throw ModelManifestError.duplicatePackID(pack.id) }
        }
    }
}

public enum ModelManifestError: Error, Sendable, Equatable {
    case invalidPackID(String)
    case duplicatePackID(String)
    case emptyPack(packID: String)
    case invalidFilename(packID: String, filename: String)
    case duplicateFilename(packID: String, filename: String)
    case invalidChecksum(packID: String, filename: String)
    case invalidSize(packID: String, filename: String)
    case insecureSourceURL(packID: String, filename: String)
    case invalidRequirements(packID: String)
}

// MARK: - V1 pins

extension ModelManifest {
    /// Exact pins for V1. Every URL resolves at a fixed upstream commit; sizes and SHA-256 values
    /// were verified against the downloaded files (see docs/setup/models.md).
    public static let v1 = ModelManifest(
        manifestVersion: 1,
        packs: [
            ModelPack(
                id: ModelPackID.whisperBaseEn,
                role: .asr,
                displayName: "Speech recognition",
                license: "MIT",
                files: [
                    ModelFile(
                        filename: ModelFileName.whisperBaseEn,
                        sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin")!,
                        repository: "ggerganov/whisper.cpp",
                        revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
                        bytes: 147_964_211,
                        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
                    ),
                    ModelFile(
                        filename: ModelFileName.sileroVAD,
                        sourceURL: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")!,
                        repository: "ggml-org/whisper-vad",
                        revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
                        bytes: 885_098,
                        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
                    ),
                ],
                minimumAppVersion: "1.0.0",
                minimumIOSVersion: "18.0",
                minimumPhysicalMemoryGB: 7.5
            ),
            ModelPack(
                id: ModelPackID.nemotronNano4B,
                role: .llm,
                displayName: "Language model",
                license: "NVIDIA Nemotron Open Model License",
                files: [
                    ModelFile(
                        filename: ModelFileName.nemotronNano4B,
                        sourceURL: URL(string: "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF/resolve/1260a7780236524372acab3fdff3da563b611a2c/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf")!,
                        repository: "nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF",
                        revision: "1260a7780236524372acab3fdff3da563b611a2c",
                        bytes: 2_837_072_864,
                        sha256: "be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2"
                    ),
                ],
                minimumAppVersion: "1.0.0",
                minimumIOSVersion: "18.0",
                minimumPhysicalMemoryGB: 7.5
            ),
            ModelPack(
                id: ModelPackID.kokoro82M,
                role: .tts,
                displayName: "Voice",
                license: "Apache-2.0",
                files: [
                    ModelFile(
                        filename: ModelFileName.kokoroWeights,
                        sourceURL: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/a71e4d38b236d968966a2002c4c895dbd12b1c3c/kokoro-v1_0.safetensors")!,
                        repository: "mlx-community/Kokoro-82M-bf16",
                        revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
                        bytes: 327_115_152,
                        sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
                    ),
                    ModelFile(
                        filename: ModelFileName.kokoroVoiceAfHeart,
                        sourceURL: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/a71e4d38b236d968966a2002c4c895dbd12b1c3c/voices/af_heart.safetensors")!,
                        repository: "mlx-community/Kokoro-82M-bf16",
                        revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
                        bytes: 522_320,
                        sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"
                    ),
                ],
                minimumAppVersion: "1.0.0",
                minimumIOSVersion: "18.0",
                minimumPhysicalMemoryGB: 7.5
            ),
        ]
    )
}

// MARK: - Hex helpers

enum HexEncoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func string<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var characters: [UInt8] = []
        characters.reserveCapacity(64)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Exactly 64 lowercase hexadecimal characters.
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
