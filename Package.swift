// swift-tools-version: 6.0
// VoiceAgentKit — every non-UI module of the offline iPhone voice agent.
//
// The iOS app target lives in App/VoiceAgent.xcodeproj and links these products.
// Pure logic is testable on macOS with `swift test`; native runtimes use the
// pinned xcframeworks in Vendor/Frameworks (see Scripts/bootstrap_dependencies.sh).

import Foundation
import PackageDescription

// The pinned runtimes (llama.cpp / whisper.cpp XCFrameworks, Kokoro packages) are fetched and
// verified by Scripts/bootstrap_dependencies.sh, not committed. Without them SwiftPM only reports
// "binary target 'llama' could not be mapped to an artifact", so say what to do instead.
let missingVendor = ["Vendor/Frameworks/llama.xcframework", "Vendor/Frameworks/whisper.xcframework", "Vendor/Packages/kokoro-ios"]
    .filter { !FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + $0) }
if !missingVendor.isEmpty {
    fatalError("""
        Missing \(missingVendor.joined(separator: ", ")).
        Run Scripts/bootstrap_dependencies.sh from the repository root, then reopen the project (Docs/BUILD.md).
        """)
}

let package = Package(
    name: "VoiceAgentKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(
            name: "VoiceAgentKit",
            targets: [
                "Telemetry", "Core", "Permissions", "Storage", "Models", "Tools",
                "LLM", "ASR", "TTS", "Audio", "Agent", "VoiceLoop", "DeviceBenchmark",
                "Intelligence",
            ]
        ),
        // Kokoro/MLX is a separate product: MLX cannot link for (or run in) the iOS Simulator, so
        // only the device app target links it (see App/project.yml).
        .library(name: "KokoroTTS", targets: ["KokoroTTS"]),
        .library(name: "AgentEval", targets: ["AgentEval"]),
        .library(name: "IntelligenceEval", targets: ["IntelligenceEval"]),
        .executable(name: "agent-eval", targets: ["AgentEvalRunner"]),
    ],
    dependencies: [
        // Kokoro 82M TTS on MLX Swift: mlalma/kokoro-ios 1.0.11 + MisakiSwift 1.0.6, checked out at
        // their exact tags by Scripts/bootstrap_dependencies.sh with a packaging-only patch
        // (Vendor/Patches) so their resource bundles pass codesign. See Docs/THIRD_PARTY.md.
        .package(path: "Vendor/Packages/kokoro-ios"),
    ],
    targets: [
        // Pinned native runtimes (official release binaries; see Docs/MODEL_MANIFEST.md).
        .binaryTarget(name: "llama", path: "Vendor/Frameworks/llama.xcframework"),
        .binaryTarget(name: "whisper", path: "Vendor/Frameworks/whisper.xcframework"),

        .target(name: "Telemetry", path: "Telemetry"),
        .target(name: "Core", dependencies: ["Telemetry"], path: "Core"),
        .target(name: "Permissions", dependencies: ["Core", "Telemetry"], path: "Permissions"),
        .target(name: "Storage", dependencies: ["Core", "Telemetry"], path: "Storage"),
        .target(name: "Models", dependencies: ["Core", "Telemetry"], path: "Models"),
        // The personal intelligence: entities, assertions, provenance — the V2 memory substrate.
        .target(name: "Intelligence", dependencies: ["Core", "Telemetry"], path: "Intelligence"),
        .target(name: "Tools", dependencies: ["Core", "Permissions", "Telemetry"], path: "Tools"),
        .target(name: "LLM", dependencies: ["Core", "Telemetry", "llama"], path: "LLM"),
        .target(name: "ASR", dependencies: ["Core", "Telemetry", "whisper"], path: "ASR"),
        .target(name: "TTS", dependencies: ["Core", "Telemetry"], path: "TTS", exclude: ["Kokoro"]),
        .target(
            name: "KokoroTTS",
            dependencies: [
                "TTS", "Core", "Telemetry",
                .product(name: "KokoroSwift", package: "kokoro-ios"),
            ],
            path: "TTS/Kokoro"
        ),
        .target(name: "Audio", dependencies: ["Core", "Telemetry"], path: "Audio"),
        .target(
            name: "Agent",
            dependencies: ["Core", "Telemetry", "LLM", "Tools", "Permissions", "Intelligence"],
            path: "Agent",
            exclude: ["VoiceLoop"]
        ),
        // Real-time voice loop glue (capture → VAD → endpointing → ASR → coordinator → TTS, barge-in).
        .target(
            name: "VoiceLoop",
            dependencies: ["Agent", "Audio", "ASR", "TTS", "Core", "Telemetry"],
            path: "Agent/VoiceLoop"
        ),
        .target(
            name: "DeviceBenchmark",
            dependencies: ["Core", "Telemetry", "LLM", "ASR", "TTS"],
            path: "Tests/Benchmarks/DeviceBenchmark"
        ),

        // Evaluation harness (library + CLI) — runs the real agent against 2,500+ cases.
        .target(
            name: "AgentEval",
            dependencies: ["Core", "Telemetry", "Agent", "LLM", "Tools"],
            path: "Tests/AgentEval/Harness"
        ),
        .executableTarget(
            name: "AgentEvalRunner",
            dependencies: ["AgentEval", "IntelligenceEval", "Intelligence", "LLM", "Agent", "Core"],
            path: "Tests/AgentEval/Runner"
        ),

        // Tests (Swift Testing). None require private user data or network access.
        .testTarget(name: "CoreTests", dependencies: ["Core", "Telemetry"], path: "Tests/Unit/Core"),
        .testTarget(name: "PermissionsTests", dependencies: ["Permissions", "Core"], path: "Tests/Unit/Permissions"),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Core"], path: "Tests/Unit/Storage"),
        .testTarget(name: "ModelsTests", dependencies: ["Models", "Core", "Telemetry"], path: "Tests/Unit/Models"),
        .testTarget(name: "ToolsTests", dependencies: ["Tools", "Core", "Permissions"], path: "Tests/Unit/Tools"),
        .testTarget(name: "IntelligenceTests", dependencies: ["Intelligence", "Core", "Telemetry"], path: "Tests/Unit/Intelligence"),
        // V2 evaluation: memory, recall over time, retrieval, planning scope, attention.
        .target(
            name: "IntelligenceEval",
            dependencies: ["Intelligence", "Agent", "Core", "LLM"],
            path: "Tests/IntelligenceEval/Harness"
        ),
        .testTarget(
            name: "IntelligenceEvalTests",
            dependencies: ["IntelligenceEval", "Intelligence", "Agent", "AgentEval", "Core"],
            path: "Tests/IntelligenceEval/Tests",
            resources: [.copy("../Cases")]
        ),
        .testTarget(name: "DateParsingTests", dependencies: ["Tools", "Core"], path: "Tests/Unit/Dates"),
        .testTarget(name: "LLMTests", dependencies: ["LLM", "Core"], path: "Tests/Unit/LLM"),
        .testTarget(
            name: "AgentTests",
            dependencies: ["Agent", "Tools", "LLM", "Core", "Permissions", "AgentEval"],
            path: "Tests/Unit/Agent"
        ),
        .testTarget(name: "AudioUnitTests", dependencies: ["Audio", "Core"], path: "Tests/Unit/Audio"),
        .testTarget(name: "TTSTests", dependencies: ["TTS", "Core"], path: "Tests/Unit/TTS"),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Core", "Agent", "Tools", "LLM", "Permissions", "AgentEval"],
            path: "Tests/Integration"
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: ["Core", "Audio", "ASR", "Agent", "VoiceLoop", "TTS", "AgentEval", "Permissions"],
            path: "Tests/Audio",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AgentEvalTests",
            dependencies: ["AgentEval", "Agent", "Core", "LLM", "Tools"],
            path: "Tests/AgentEval/Tests"
        ),
    ]
)
