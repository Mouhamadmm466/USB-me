import Foundation
import Models
import Testing

@Suite("Model manifest")
struct ModelManifestTests {
    @Test func v1PinsAreExact() throws {
        let manifest = ModelManifest.v1
        #expect(manifest.manifestVersion == 1)
        #expect(manifest.packs.map(\.id) == ["whisper-base.en", "nemotron-3-nano-4b-q4_k_m", "kokoro-82m"])

        let whisper = try #require(manifest.pack(id: ModelPackID.whisperBaseEn))
        #expect(whisper.role == .asr && whisper.displayName == "Speech recognition" && whisper.license == "MIT")
        #expect(whisper.files.map(\.filename) == ["ggml-base.en.bin", "ggml-silero-v6.2.0.bin"])
        #expect(whisper.files.map(\.bytes) == [147_964_211, 885_098])
        #expect(whisper.files.map(\.sha256) == [
            "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
            "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
        ])
        #expect(whisper.files.map(\.repository) == ["ggerganov/whisper.cpp", "ggml-org/whisper-vad"])
        #expect(whisper.files.map(\.revision) == ["5359861c739e955e79d9a303bcbc70fb988958b1", "9ffd54a1e1ee413ddf265af9913beaf518d1639b"])

        let nemotron = try #require(manifest.pack(id: ModelPackID.nemotronNano4B))
        #expect(nemotron.role == .llm && nemotron.displayName == "Language model")
        #expect(nemotron.license == "NVIDIA Nemotron Open Model License")
        let gguf = try #require(nemotron.file(named: ModelFileName.nemotronNano4B))
        #expect(gguf.bytes == 2_837_072_864)
        #expect(gguf.sha256 == "be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2")
        #expect(gguf.repository == "nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF")
        #expect(gguf.revision == "1260a7780236524372acab3fdff3da563b611a2c")

        let kokoro = try #require(manifest.pack(id: ModelPackID.kokoro82M))
        #expect(kokoro.role == .tts && kokoro.displayName == "Voice" && kokoro.license == "Apache-2.0")
        #expect(kokoro.files.map(\.filename) == ["kokoro-v1_0.safetensors", "af_heart.safetensors"])
        #expect(kokoro.files.map(\.bytes) == [327_115_152, 522_320])
        #expect(kokoro.files.map(\.sha256) == [
            "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8",
            "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094",
        ])
        #expect(kokoro.files.allSatisfy { $0.repository == "mlx-community/Kokoro-82M-bf16" && $0.revision == "a71e4d38b236d968966a2002c4c895dbd12b1c3c" })
        let voice = try #require(kokoro.file(named: ModelFileName.kokoroVoiceAfHeart))
        #expect(voice.sourceURL.absoluteString.hasSuffix("/voices/af_heart.safetensors"))

        for pack in manifest.packs {
            #expect(pack.minimumAppVersion == "1.0.0")
            #expect(pack.minimumIOSVersion == "18.0")
            #expect(pack.minimumPhysicalMemoryGB == 7.5)
        }
    }

    @Test func sourceURLsArePinnedToTheirRevision() {
        for file in ModelManifest.v1.allFiles {
            let url = file.sourceURL.absoluteString
            #expect(file.sourceURL.scheme == "https", "\(file.filename)")
            #expect(file.sourceURL.host == "huggingface.co", "\(file.filename)")
            #expect(url.hasPrefix("https://huggingface.co/\(file.repository)/resolve/\(file.revision)/"), "\(url)")
            #expect(url.contains(file.revision), "\(url)")
            #expect(url.hasSuffix("/" + file.filename), "\(url)")
            #expect(file.revision.count == 40 && file.revision.allSatisfy(\.isHexDigit) && file.revision == file.revision.lowercased())
        }
    }

    @Test func checksumsAreLowercase64Hex() {
        for file in ModelManifest.v1.allFiles {
            #expect(file.sha256.count == 64, "\(file.filename)")
            #expect(file.sha256.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }, "\(file.filename)")
            #expect(file.bytes > 0)
        }
        #expect(Set(ModelManifest.v1.allFiles.map(\.sha256)).count == ModelManifest.v1.allFiles.count)
    }

    @Test func manifestJSONMirrorsSwiftConstant() throws {
        let url = try repositoryFile("Scripts/model_manifest.json")
        let data = try Data(contentsOf: url)

        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded == ModelManifest.v1)

        // Same keys and values, nothing extra (Decodable alone would ignore unknown keys).
        let mirror = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelManifest.v1)) as? NSDictionary
        #expect(mirror != nil && mirror == encoded)
    }

    @Test func v1ValidatesAndRolesCoverThePipeline() throws {
        try ModelManifest.v1.validate()
        for role in ModelRole.allCases {
            #expect(ModelManifest.v1.packs.filter { $0.role == role }.count == 1, "\(role)")
            #expect(ModelManifest.v1.pack(for: role) != nil)
        }
    }

    @Test func validationRejectsUnsafeOrWeakPins() {
        let good = ModelManifest.v1.packs[0].files[0]
        func pack(_ files: [ModelFile], id: String = "pack") -> ModelPack {
            ModelPack(id: id, role: .asr, displayName: "x", license: "MIT", files: files,
                      minimumAppVersion: "1.0.0", minimumIOSVersion: "18.0", minimumPhysicalMemoryGB: 7.5)
        }
        func file(name: String = "model.bin", url: String = "https://huggingface.co/a/b/resolve/c/model.bin", bytes: Int64 = 10, sha: String? = nil) -> ModelFile {
            ModelFile(filename: name, sourceURL: URL(string: url)!, repository: "a/b", revision: "c", bytes: bytes, sha256: sha ?? good.sha256)
        }

        #expect(throws: ModelManifestError.invalidFilename(packID: "pack", filename: "../escape.bin")) { try pack([file(name: "../escape.bin")]).validate() }
        #expect(throws: ModelManifestError.invalidFilename(packID: "pack", filename: ".hidden")) { try pack([file(name: ".hidden")]).validate() }
        #expect(throws: ModelManifestError.invalidFilename(packID: "pack", filename: "dir/model.bin")) { try pack([file(name: "dir/model.bin")]).validate() }
        #expect(throws: ModelManifestError.invalidPackID("..")) { try pack([file()], id: "..").validate() }
        #expect(throws: ModelManifestError.invalidChecksum(packID: "pack", filename: "model.bin")) { try pack([file(sha: String(repeating: "A", count: 64))]).validate() }
        #expect(throws: ModelManifestError.invalidChecksum(packID: "pack", filename: "model.bin")) { try pack([file(sha: "abc")]).validate() }
        #expect(throws: ModelManifestError.insecureSourceURL(packID: "pack", filename: "model.bin")) { try pack([file(url: "http://huggingface.co/model.bin")]).validate() }
        #expect(throws: ModelManifestError.invalidSize(packID: "pack", filename: "model.bin")) { try pack([file(bytes: 0)]).validate() }
        #expect(throws: ModelManifestError.duplicateFilename(packID: "pack", filename: "model.bin")) { try pack([file(), file()]).validate() }
        #expect(throws: ModelManifestError.emptyPack(packID: "pack")) { try pack([]).validate() }
        #expect(throws: ModelManifestError.duplicatePackID("pack")) {
            try ModelManifest(manifestVersion: 1, packs: [pack([file()]), pack([file()])]).validate()
        }
    }

    /// Pack revisions name the on-disk directories. If this test fails, the canonical form changed
    /// and every installed pack would look like a different revision (a full re-download).
    @Test func packRevisionsAreStableAndContentDerived() throws {
        let revisions = Dictionary(uniqueKeysWithValues: ModelManifest.v1.packs.map { ($0.id, $0.revision) })
        #expect(revisions == [
            "whisper-base.en": "e01e970685c7f145",
            "nemotron-3-nano-4b-q4_k_m": "10686bb1f7ee339c",
            "kokoro-82m": "d6bf05800f79c50d",
        ])

        let pack = try #require(ModelManifest.v1.pack(id: ModelPackID.kokoro82M))
        let cosmetic = ModelPack(id: pack.id, role: pack.role, displayName: "Renamed", license: "Other",
                                 files: pack.files.map { ModelFile(filename: $0.filename, sourceURL: URL(string: "https://mirror.example/\($0.filename)")!, repository: "mirror/x", revision: "0000", bytes: $0.bytes, sha256: $0.sha256) },
                                 minimumAppVersion: "2.0", minimumIOSVersion: "19.0", minimumPhysicalMemoryGB: 12)
        #expect(cosmetic.revision == pack.revision, "cosmetic edits and mirrors keep the revision")

        var files = pack.files
        files[1] = ModelFile(filename: files[1].filename, sourceURL: files[1].sourceURL, repository: files[1].repository, revision: files[1].revision, bytes: files[1].bytes, sha256: String(repeating: "0", count: 64))
        let changed = ModelPack(id: pack.id, role: pack.role, displayName: pack.displayName, license: pack.license, files: files,
                                minimumAppVersion: pack.minimumAppVersion, minimumIOSVersion: pack.minimumIOSVersion, minimumPhysicalMemoryGB: pack.minimumPhysicalMemoryGB)
        #expect(changed.revision != pack.revision, "any content change is a new revision")
        #expect(pack.revision.count == 16 && pack.revision.allSatisfy(\.isHexDigit))
    }

    @Test func totalsAndLookups() throws {
        let manifest = ModelManifest.v1
        #expect(manifest.pack(id: ModelPackID.whisperBaseEn)?.totalBytes == 148_849_309)
        #expect(manifest.pack(id: ModelPackID.nemotronNano4B)?.totalBytes == 2_837_072_864)
        #expect(manifest.pack(id: ModelPackID.kokoro82M)?.totalBytes == 327_637_472)
        #expect(manifest.totalBytes == 3_313_559_645)
        #expect(manifest.allFiles.count == 5)
        #expect(manifest.pack(for: .llm)?.id == ModelPackID.nemotronNano4B)
        #expect(manifest.file(packID: ModelPackID.whisperBaseEn, filename: ModelFileName.sileroVAD)?.bytes == 885_098)
        #expect(manifest.pack(id: "unknown") == nil)
        #expect(manifest.file(packID: ModelPackID.kokoro82M, filename: "missing.bin") == nil)
    }
}

@Suite("Device requirements")
struct DeviceRequirementTests {
    @Test func eightGigabyteIPhonesAreSupported() {
        // An "8 GB" iPhone reports < 8 GiB; the threshold is in decimal GB so it still passes.
        #expect(ModelManifest.v1.checkRequirements(on: .iPhone8GB) == .supported)
        #expect(Double(DeviceProfile.iPhone8GB.physicalMemoryBytes) / 1_073_741_824 < 7.5, "fixture reports less than 7.5 GiB")
    }

    @Test func sixGigabyteIPhonesAreRejectedWithAClearReason() throws {
        let result = ModelManifest.v1.checkRequirements(on: .iPhone6GB)
        #expect(!result.isSupported)
        #expect(result.issues == [.insufficientMemory(requiredGB: 7.5, installedGB: 5.9)])
        #expect(result.userMessage == "Needs an iPhone with at least 8 GB of memory.")
    }

    @Test func operatingSystemAndAppVersionAreChecked() {
        var device = DeviceProfile.iPhone8GB
        device.operatingSystemVersion = SemanticVersion("17.6.1")!
        device.appVersion = SemanticVersion("0.9")
        let result = ModelManifest.v1.checkRequirements(on: device)
        #expect(result.issues == [
            .operatingSystemTooOld(required: "18.0", installed: "17.6.1"),
            .appVersionTooOld(required: "1.0.0", installed: "0.9"),
        ])
        #expect(result.issues[0].userMessage == "Needs iOS 18.0 or later.")
    }

    @Test func macDevelopmentHostsSkipTheIOSVersionCheck() {
        let mac = DeviceProfile(platform: .macOS, physicalMemoryBytes: 17_179_869_184, operatingSystemVersion: SemanticVersion("15.4")!, appVersion: nil)
        #expect(ModelManifest.v1.checkRequirements(on: mac) == .supported)
        #expect(DeviceProfile.current.physicalMemoryBytes > 0)
    }

    @Test func semanticVersionsCompareNumerically() throws {
        let v = { (s: String) in SemanticVersion(s)! }
        #expect(v("18") == v("18.0.0"))
        #expect(v("18.0") < v("18.0.1"))
        #expect(v("1.10") > v("1.9"))
        #expect(v("2.0.0-beta") == v("2"))
        #expect(v("1.2.3+45") == v("1.2.3"))
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1..2") == nil)
        #expect(SemanticVersion("v1") == nil)
        #expect(v("18.0").description == "18.0")
        #expect(AppVersionInfo(shortVersion: "1.2.0", buildNumber: "7").integrityStamp == "1.2.0 (7)")
        #expect(AppVersionInfo(shortVersion: nil, buildNumber: nil).integrityStamp == "development")
    }
}
