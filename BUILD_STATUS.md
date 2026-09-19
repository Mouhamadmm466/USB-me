# BUILD_STATUS

Living status for the offline iPhone voice agent. Updated continuously while building.
Source of truth for requirements: `Offline_iPhone_Voice_Agent_PRD_and_Autonomous_Build_Prompt.docx` (PRD).

_Last updated: 2026-09-19 (session 1)._

## Environment facts that shape the plan

| Fact | Consequence |
|---|---|
| Build Mac is an **Intel Core i7-1068NG7 (x86_64), 16 GB**, macOS 26.6.2, Xcode 26.5, Swift 6.3.2 | MLX (KokoroSwift) cannot run on this Mac or in the x86_64 iOS Simulator. Kokoro TTS can only execute on a physical iPhone. whisper.cpp and llama.cpp run here on CPU, so the text agent + 2,500-case evaluation run against the **real** Nemotron model on this Mac. |
| Registered device: **iPhone 15 Pro (iPhone16,1, 8 GB)**, currently `unavailable` in `devicectl` | Physical-device gates (Phase 1 benchmark, voice loop, barge-in, TTS) need the phone connected, unlocked, Developer Mode on. |
| Signing: **free Personal Team 3MK9V84J42** only | Device builds work (7-day profiles). TestFlight/App Store need a paid Apple Developer Program team. The increased-memory-limit entitlement may be rejected by free provisioning — to be verified on device. |
| Official llama.cpp b11046 XCFramework ships **no iOS-simulator slice** | Device + macOS slices are the official release binaries byte-for-byte; the simulator slice is built from the same tag with the official `build-xcframework.sh ios-sim` and merged (`Scripts/bootstrap_dependencies.sh`). |

## Pinned components (verified)

| Component | Pin | Verification |
|---|---|---|
| Nemotron 3 Nano 4B Q4_K_M | `nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF` @ `1260a7780236524372acab3fdff3da563b611a2c`, 2,837,072,864 B | SHA-256 `be5d9a65…0b5ef2` ✅ |
| Whisper base.en | `ggerganov/whisper.cpp` @ `5359861c…58b1`, `ggml-base.en.bin`, 147,964,211 B | SHA-256 `a03779c8…c6d002` ✅ |
| Kokoro 82M weights | `mlx-community/Kokoro-82M-bf16` @ `a71e4d38…c3c`, `kokoro-v1_0.safetensors`, 327,115,152 B | SHA-256 `4e9ecdf0…02acd8` ✅ (identical to KokoroTestApp's file) |
| Kokoro voice | same repo/rev, `voices/af_heart.safetensors`, 522,320 B | SHA-256 `2c1c733b…136d094` ✅ |
| llama.cpp | tag `b11046` (commit `60081bb2`), XCFramework SHA-256 `b6c46399…49938` | ✅ |
| whisper.cpp | `v1.9.4` = build `b5130`, XCFramework SHA-256 `033a43b0…6f231a` | ✅ |
| KokoroSwift | `mlalma/kokoro-ios` `1.0.11` (mlx-swift 0.30.2, MisakiSwift 1.0.6) | builds for iOS device ✅; macOS x86_64 compiles ✅ |

## Phase checklist

- [x] **Phase 0 — bootstrap**: SwiftPM package + Xcode project (device + simulator targets), pinned runtimes,
      bootstrap/CI scripts, docs skeleton, git. Kokoro/Misaki packaging patch for codesign.
- [ ] **Phase 1 — physical feasibility**: `DeviceBenchmarkRunner` written (load, latency, RTF, WER, memory,
      thermal, battery); **blocked on the iPhone being connected**.
- [~] **Phase 2 — text-only agent**: Nemotron runtime (prefix-state cache, grammar, jump-forward) verified on
      the real model on this Mac; validator, prompt, state machine, confirmation/clarification, coordinator done
      with unit tests; 2,500-case dataset + harness in progress (sub-agent).
- [~] **Phase 3 — native tools**: resolver/executor/adapters/fakes in progress (sub-agent); integration tests written.
- [~] **Phase 4 — streaming ASR**: Whisper runtime + Silero VAD + transcript stability done; audio capture,
      endpointing, route handling in progress (sub-agent); fixture tests written.
- [~] **Phase 5 — local TTS**: Kokoro runtime, chunker, pipelined queue with cancellation done (device-only engine).
- [~] **Phase 6 — voice loop**: `VoiceSessionController` written; tests pending audio module completion.
- [~] **Phase 7 — barge-in/echo**: controller logic (sub-agent) + integration in the voice loop.
- [~] **Phase 8 — model manager**: download/resume/checksum/activation in progress (sub-agent).
- [ ] **Phase 9 — hardening**
- [ ] **Phase 10 — production candidate**

## Current failures / blockers

- iPhone 15 Pro not connected (`devicectl`: unavailable) → Phase 1 benchmark and on-device voice/TTS verification pending.
- Free Personal Team → no TestFlight; increased-memory-limit entitlement acceptance to be verified at first device install.
- MLX (Kokoro) cannot link for the x86_64 Simulator (`MTLTensorDomain`/`MTLIOErrorDomain` missing) and does not run
  in any simulator → the `VoiceAgentSim` target omits TTS by design.

## Measured results

| What | Where | Result |
|---|---|---|
| Nemotron Q4_K_M loads and emits schema-valid JSON under grammar | Intel Mac, CPU, 4 threads | ✅ 7/7 smoke utterances valid |
| Prefix (system + few-shot, ~1.5K tokens) cold eval | Intel Mac CPU (contended) | 180 s once; then state loaded from disk cache |
| Jump-forward decoding | Intel Mac CPU | sampled tokens 39→17 (message), 29→8 (calendar read) |

## Human-only steps (exact instructions)

1. **Connect the iPhone 15 Pro** by cable (or same Wi-Fi after pairing), unlock it, tap *Trust*, and enable
   *Settings → Privacy & Security → Developer Mode*. Then run `Scripts/benchmark_device.sh`.
2. First install on device: *Settings → General → VPN & Device Management → Apple Development: Mouhamad Mamane → Trust*.
3. For TestFlight: enroll in the paid Apple Developer Program, set `DEVELOPMENT_TEAM` in `App/project.yml`, then archive.

## Next actions

- Finish Phase 0; start Phase 2 (Nemotron text agent on this Mac) in parallel with tools/model-manager/audio work packages.
