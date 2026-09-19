# Voice Agent — a private, on-device voice assistant for iPhone

You speak; your iPhone understands, talks back to confirm, and does the task — without sending
your voice or words to any server.

- **Speech recognition:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Whisper
  `base.en`, plus Silero VAD for endpointing.
- **Understanding:** [NVIDIA Nemotron 3 Nano 4B](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF)
  (Q4_K_M GGUF) on [llama.cpp](https://github.com/ggml-org/llama.cpp) + Metal, decoding under a
  grammar generated from the tool catalog.
- **Speech:** [Kokoro 82M](https://huggingface.co/mlx-community/Kokoro-82M-bf16) through
  [KokoroSwift](https://github.com/mlalma/kokoro-ios) on MLX, one fixed voice (`af_heart`).
- **Actions:** Contacts, EventKit (calendar and reminders), MessageUI, the system call flow,
  user-selected folders, and a fixed list of apps. Public APIs only.

The model only *proposes*. Swift validates every proposal, looks up people/events/files itself,
reads back exactly what it will do, and acts only after you confirm that exact version.

```
"Text Alex that I'll be 20 minutes late."
  → "Text Alex Kim: “I'll be 20 minutes late.” Should I send it?"   [card: To / Number / Message]
"Yes."
  → Messages opens with the text; you tap Send → "Sent to Alex Kim."
```

## Quick start

> **Run `Scripts/bootstrap_dependencies.sh` once after cloning, before opening the Xcode project.**
> The pinned llama.cpp / whisper.cpp XCFrameworks and the Kokoro packages are downloaded and
> SHA-256-verified by that script, not stored in git (~7 minutes). Without them Xcode reports
> "Missing package product 'VoiceAgentKit'"; `Package.swift` stops with the same instruction.

```bash
Scripts/bootstrap_dependencies.sh   # pinned runtimes (verified)
Scripts/download_models.sh          # pinned models into ModelCache/ (verified)
swift test                          # unit + integration + eval-dataset tests
open App/VoiceAgent.xcodeproj       # scheme VoiceAgent (device) or VoiceAgentSim (Simulator)
```

Full instructions: [Docs/BUILD.md](Docs/BUILD.md).

## Documentation

| Doc | What it covers |
|---|---|
| [BUILD_STATUS.md](BUILD_STATUS.md) | Live status: phases, measured results, blockers, human-only steps |
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | Modules, state machine, turn pipeline, scheduling |
| [Docs/MODEL_MANIFEST.md](Docs/MODEL_MANIFEST.md) | Exact model sources, revisions, sizes, SHA-256, integrity policy |
| [Docs/SECURITY.md](Docs/SECURITY.md) | Threat model and controls |
| [Docs/PRIVACY.md](Docs/PRIVACY.md) | What stays on device (everything) |
| [Docs/EVALUATION.md](Docs/EVALUATION.md) | 2,500+ case agent evaluation, audio test plan, metrics, results |
| [Docs/DEVICE_MATRIX.md](Docs/DEVICE_MATRIX.md) | Supported devices, memory budget, benchmarks |
| [Docs/THIRD_PARTY.md](Docs/THIRD_PARTY.md) | Pinned dependencies and licenses |
| [Docs/KNOWN_LIMITATIONS.md](Docs/KNOWN_LIMITATIONS.md) | What V1 does not do |
| [Docs/DEMO.md](Docs/DEMO.md) | Five-minute demo script (Airplane Mode on) |

## Repository layout

```
App/            iOS app (SwiftUI): AppEntry/, UI/, Resources/, VoiceAgent.xcodeproj (XcodeGen: project.yml)
Core/           state machine, session state, PendingAction, risk policy, tool catalog, protocols
Audio/          AVAudioSession/AVAudioEngine, VAD, endpointing, echo/barge-in
ASR/            whisper.cpp runtime, Silero VAD, transcript stability
LLM/            Nemotron runtime, prompt, grammar, output validator, context manager
TTS/            chunking, speech queue, playback tracking; TTS/Kokoro/ (device-only engine)
Agent/          coordinator, confirmation, clarification, summaries, capabilities
Tools/          resolver, executor, native adapters (Contacts, EventKit, MessageUI, calls, files, apps), fakes
Models/         manifest, resumable downloads, SHA-256 integrity, lifecycle
Permissions/    just-in-time permission manager
Storage/        SwiftData session/settings stores
Telemetry/      privacy-safe logger, performance metrics
Tests/          Unit/, Integration/, Audio/, AgentEval/ (dataset, harness, runner), Benchmarks/, E2E/
Scripts/        bootstrap, model download/verify, eval, device benchmark, CI
Docs/           the documents above
```
