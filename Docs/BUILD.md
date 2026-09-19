# Build, run and test

## Requirements

- macOS 15+ with **Xcode 26.5** (Swift 6.3) and the Metal Toolchain component
  (`xcodebuild -downloadComponent MetalToolchain`).
- `cmake`, `git`, `curl`, `shasum`, `python3` (all standard or via Homebrew), and
  [`xcodegen`](https://github.com/yonaskolb/XcodeGen) only if you change `App/project.yml`.
- For device runs: an iPhone with 8 GB RAM (iPhone 15 Pro or later) on iOS 18+, Developer Mode
  enabled, and an Apple development team.
- ~4 GB free disk for models (plus ~1 GB for build products).

## 1. Fresh clone → dependencies

```bash
Scripts/bootstrap_dependencies.sh
```

Downloads and SHA-256-verifies the official llama.cpp `b11046` and whisper.cpp `v1.9.4`
XCFrameworks, builds the llama.cpp iOS-simulator slice from the same commit, merges it, and checks
out KokoroSwift 1.0.11 + MisakiSwift 1.0.6 with the packaging patch (see `Docs/THIRD_PARTY.md`).
Idempotent; `--force` rebuilds.

## 2. Models (development machines)

```bash
Scripts/download_models.sh      # downloads every pinned file into ModelCache/, verifies SHA-256
Scripts/verify_models.sh        # re-verifies ModelCache/
```

The app itself downloads models on first run (Settings → Models); `ModelCache/` is for tests,
the evaluation harness and sideloading onto a device.

## 3. Package build and tests (macOS)

```bash
swift build
swift test                      # unit + integration + eval-dataset tests (no network, no user data)
```

Audio/ASR tests that need `ModelCache/ggml-base.en.bin` skip themselves when it is absent.

## 4. Agent evaluation (real Nemotron on this Mac)

```bash
Scripts/run_agent_eval.sh                 # full suite, all cases, real model
Scripts/run_agent_eval.sh --limit 200     # quick stratified subset
Scripts/run_agent_eval.sh --pipeline      # deterministic oracle model (pipeline logic only)
```

Reports land in `Tests/AgentEval/Results/`. See `Docs/EVALUATION.md`.

## 5. iOS app

```bash
open App/VoiceAgent.xcodeproj
```

- Scheme **VoiceAgent** — the real app for a physical iPhone (links Kokoro/MLX; MLX cannot build
  for the Simulator). Set your team in *Signing & Capabilities* (or `DEVELOPMENT_TEAM` in
  `App/project.yml` and re-run `xcodegen generate --spec App/project.yml`).
- Scheme **VoiceAgentSim** — the same app for the Simulator, without TTS (speech is shown as
  text), used for UI work and UI tests.

Command line:

```bash
# Simulator build + UI tests
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgentSim \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Device build (automatic signing)
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## 6. Physical-device benchmark (Phase 1 gate)

```bash
Scripts/benchmark_device.sh     # builds, installs, sideloads models, runs the benchmark, pulls the report
```

Requires the iPhone connected and unlocked. The report is written to
`Tests/Benchmarks/Results/<device>-<date>.json` and summarized in `Docs/DEVICE_MATRIX.md`.

## 7. Archive / TestFlight

1. Paid Apple Developer Program team in `App/project.yml` (`DEVELOPMENT_TEAM`).
2. Enable the *Increased Memory Limit* capability for the App ID.
3. `xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent -configuration Release -archivePath build/VoiceAgent.xcarchive archive`
4. Upload with Xcode Organizer (or `xcodebuild -exportArchive`), then complete App Store Connect
   steps (privacy label "Data Not Collected", export compliance: standard encryption only).
