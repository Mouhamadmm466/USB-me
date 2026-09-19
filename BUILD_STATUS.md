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

- [ ] **Phase 0 — bootstrap**: repo, SwiftPM package + Xcode project, pinning, scripts, CI, docs skeleton
- [ ] **Phase 1 — physical feasibility**: exact Whisper + Nemotron + Kokoro on iPhone, benchmark report _(needs device)_
- [ ] **Phase 2 — text-only agent**: Nemotron + state machine + fake tools + structured output + confirmation; 2,500-case harness
- [ ] **Phase 3 — native tools**: Contacts, EventKit, MessageUI, calls, scoped files, apps + adapters + tests
- [ ] **Phase 4 — streaming ASR**: mic, VAD, endpointing, partial UI, final transcript, route changes
- [ ] **Phase 5 — local TTS**: Kokoro, fixed voice, chunking, cancellation, playback
- [ ] **Phase 6 — voice loop**: end-to-end spoken confirmation → voice confirmation → tool → spoken result
- [ ] **Phase 7 — barge-in/echo**
- [ ] **Phase 8 — model manager**: download/resume/checksum/version/storage/lifecycle/thermal/memory
- [ ] **Phase 9 — hardening**: adversarial, noisy audio, device matrix, battery/thermal, accessibility
- [ ] **Phase 10 — production candidate**: TestFlight-ready build, docs, release checklist

## Current failures / blockers

_None recorded yet._

## Measured results

_None yet._

## Human-only steps (exact instructions)

1. **Connect the iPhone 15 Pro** by cable (or same Wi-Fi after pairing), unlock it, tap *Trust*, and enable
   *Settings → Privacy & Security → Developer Mode*. Then run `Scripts/benchmark_device.sh`.
2. First install on device: *Settings → General → VPN & Device Management → Apple Development: Mouhamad Mamane → Trust*.
3. For TestFlight: enroll in the paid Apple Developer Program, set `DEVELOPMENT_TEAM` in `App/project.yml`, then archive.

## Next actions

- Finish Phase 0; start Phase 2 (Nemotron text agent on this Mac) in parallel with tools/model-manager/audio work packages.
