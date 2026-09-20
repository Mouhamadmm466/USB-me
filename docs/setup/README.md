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
out KokoroSwift 1.0.11 + MisakiSwift 1.0.6 with the packaging patch (see `docs/setup/dependencies.md`).
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

**If `swift test` dies with `signal code 10` / `11`** (a bus or segmentation fault, no failing
assertion, an unsymbolicated one-frame crash report), it is an incremental-build artifact, not a
test failure: adding or removing a defaulted parameter changes a function's mangled name, and a
dependent module that was not rebuilt calls the symbol that is no longer there. `swift package
clean` and re-run, it reproduces deterministically until you do, and disappears completely after.

## 4. Agent evaluation (real Nemotron on this Mac)

```bash
Scripts/run_agent_eval.sh                 # full suite, all cases, real model
Scripts/run_agent_eval.sh --limit 200     # quick stratified subset
Scripts/run_agent_eval.sh --pipeline      # deterministic oracle model (pipeline logic only)
```

Reports land in `Tests/AgentEval/Results/`. See `docs/evaluation/agent_tests.md`.

## 5. iOS app

```bash
open App/VoiceAgent.xcodeproj
```

- Scheme **VoiceAgent**, the real app for a physical iPhone (links Kokoro/MLX; MLX cannot build
  for the Simulator). Set your team in *Signing & Capabilities* (or `DEVELOPMENT_TEAM` in
  `App/project.yml` and re-run `xcodegen generate --spec App/project.yml`).
- Scheme **VoiceAgentSim**, the same app for the Simulator, without TTS (speech is shown as
  text), used for UI work and UI tests. Ad-hoc signed rather than unsigned, so that the App Group
  entitlement is present and the share extension can be exercised there.
- Target **VoiceAgentShare**, the share sheet extension, embedded in both apps. It links only the
  `ShareInbox` library, and both it and the app carry the App Group
  `group.com.mouhamadmamane.voiceagent`, which is the only thing they share.

**One-time account step for device and TestFlight builds:** the App Group has to exist on the
developer account. Xcode's automatic signing registers it the first time it signs the app (or
`xcodebuild ... -allowProvisioningUpdates`). If an archive fails with a provisioning error naming
the group, add it once in *Certificates, Identifiers & Profiles → Identifiers → App Groups* as
`group.com.mouhamadmamane.voiceagent`, then enable it on both `com.mouhamadmamane.voiceagent` and
`com.mouhamadmamane.voiceagent.share`.

Command line:

```bash
# Simulator build + UI tests
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgentSim \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Device build (automatic signing)
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Build configurations of the `VoiceAgent` scheme:

| Configuration | Optimization | Developer launch modes | Used for |
|---|---|---|---|
| Debug | none | yes | Xcode runs |
| Profile | release (`-O`) | yes | device benchmarks, on-device evaluation, voice self-test |
| Release | release (`-O`) | **no** (compiled out) | archive / TestFlight / App Store |

Developer launch modes (Debug/Profile only; pass after `--` with `devicectl`):
`-RunBenchmark`, `-RunEval [-EvalRun NAME] [-EvalLimit N] [-EvalCategory C]`, `-VoiceSelfTest`,
`-DesignGallery [-GalleryPage ID]`, `-DemoMode`.

## 6. Physical-device runs

```bash
Scripts/benchmark_device.sh     # builds (Profile), installs, sideloads models, runs the benchmark, pulls the report
Scripts/eval_device.sh          # all 3,249 evaluation cases on the phone (~2 h), scored on the Mac
Scripts/device_suite.sh         # unattended: voice self-test → benchmark → full evaluation;
                                # waits for the phone to be unlocked and resumes after it locks
```

Requires the iPhone connected, trusted and unlocked with Developer Mode on (the app keeps the screen
awake while a run is in progress). Benchmark reports go to `Tests/Benchmarks/Results/` and are
summarized in `docs/evaluation/device_results.md`; evaluation runs go to `Tests/AgentEval/Results/<run>/`.

The voice self-test (`-VoiceSelfTest`) drives the complete spoken loop on the phone, VAD,
streaming Whisper, primed Nemotron, confirmation, Kokoro through the speaker, barge-in, with
scripted user lines spoken by Kokoro in place of the microphone and the evaluation's fake contacts
and calendar; its report is `Documents/SelfTest/latest.json` in the app container.

## 7. Archive / TestFlight

Prerequisites (done for team 3MK9V84J42): paid Apple Developer Program team in `App/project.yml`
(`DEVELOPMENT_TEAM`), App ID `com.mouhamadmamane.voiceagent` with the *Increased Memory Limit*
capability, an App Store Connect app record for that bundle ID, and the account signed into Xcode.

```bash
# 1. Bump the build number for every upload (App/project.yml → CURRENT_PROJECT_VERSION), then:
xcodegen generate --spec App/project.yml
# 2. Archive (Release: no developer launch modes)
xcodebuild -project App/VoiceAgent.xcodeproj -scheme VoiceAgent -configuration Release \
  -destination 'generic/platform=iOS' -archivePath .build/archive/VoiceAgent.xcarchive \
  -allowProvisioningUpdates archive
# 3. Re-sign for App Store Connect and upload (creates the distribution signing assets if needed)
xcodebuild -exportArchive -archivePath .build/archive/VoiceAgent.xcarchive \
  -exportOptionsPlist App/ExportOptions-AppStore.plist -exportPath .build/export -allowProvisioningUpdates
```

Then App Store Connect → TestFlight: internal testers need no review; external testers need Beta
App Review. Export compliance is answered by `ITSAppUsesNonExemptEncryption = NO` (HTTPS only, for
model downloads). Privacy: `App/Resources/PrivacyInfo.xcprivacy`; App Store label "Data Not
Collected".
