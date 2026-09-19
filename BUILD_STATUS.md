# BUILD_STATUS

Living status for the offline iPhone voice agent. Updated continuously while building.
Source of truth for requirements: `Offline_iPhone_Voice_Agent_PRD_and_Autonomous_Build_Prompt.docx` (PRD).

_Last updated: 2026-09-19 (session 1, evening)._

## Environment facts that shape the plan

| Fact | Consequence |
|---|---|
| Build Mac is an **Intel Core i7-1068NG7 (x86_64), 16 GB**, macOS 26.6.2, Xcode 26.5, Swift 6.3.2 | MLX (Kokoro) cannot run on this Mac or in the x86_64 Simulator, so TTS runs only on the iPhone. whisper.cpp and llama.cpp run here on the CPU: unit/fixture tests and small evaluation runs use the **real** models, but a turn takes 5–40 s, so full evaluation runs use the phone. |
| Device: **iPhone 15 Pro (iPhone16,1, 8 GB), iOS 26.6.1**, connected by cable (drops off `devicectl` intermittently) | All device results below come from this phone. |
| Signing: **free Personal Team 3MK9V84J42** | Device builds work (7-day profiles) and the Increased Memory Limit entitlement **was granted**. TestFlight/App Store need a paid team (human step). |
| Official llama.cpp b11046 XCFramework ships no iOS-simulator slice | Device + macOS slices are the official binaries byte-for-byte; the simulator slice is built from the same tag (`Scripts/bootstrap_dependencies.sh`). |

## Pinned components (verified)

| Component | Pin | Verification |
|---|---|---|
| Nemotron 3 Nano 4B Q4_K_M | `nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF` @ `1260a7780236524372acab3fdff3da563b611a2c`, 2,837,072,864 B | SHA-256 `be5d9a65…0b5ef2` ✅ (Mac and on device) |
| Whisper base.en | `ggerganov/whisper.cpp` @ `5359861c…58b1`, `ggml-base.en.bin`, 147,964,211 B | SHA-256 `a03779c8…c6d002` ✅ |
| Silero VAD v6.2.0 (ggml) | `ggml-org/whisper-vad` | SHA-256 in `Docs/MODEL_MANIFEST.md` ✅ |
| Kokoro 82M weights | `mlx-community/Kokoro-82M-bf16` @ `a71e4d38…c3c`, `kokoro-v1_0.safetensors`, 327,115,152 B | SHA-256 `4e9ecdf0…02acd8` ✅ |
| Kokoro voice | same repo/rev, `voices/af_heart.safetensors`, 522,320 B | SHA-256 `2c1c733b…136d094` ✅ |
| llama.cpp | tag `b11046` (commit `60081bb2`), XCFramework SHA-256 `b6c46399…49938` | ✅ |
| whisper.cpp | `v1.9.4`, XCFramework SHA-256 `033a43b0…6f231a` | ✅ |
| KokoroSwift | `mlalma/kokoro-ios` `1.0.11` (mlx-swift 0.30.2, MisakiSwift 1.0.6) | builds and runs on device ✅ |

## Phase checklist

- [x] **Phase 0 — bootstrap**: SwiftPM package + XcodeGen project (device + simulator targets), pinned runtimes, bootstrap/CI scripts, docs, git.
- [x] **Phase 1 — physical feasibility**: all three models resident on the iPhone 15 Pro, no jetsam (peak footprint 1.27 GB, 6.1 GB available); cold/warm latency, memory, thermal measured (`Docs/DEVICE_MATRIX.md`).
- [x] **Phase 2 — text-only agent**: grammar-constrained Nemotron (prefix-state cache, jump-forward, context priming), validator, prompt, state machine, PendingAction id/version, confirmation/clarification, coordinator. 3,249-case dataset + harness (Mac CLI and on-device `-RunEval`).
- [x] **Phase 3 — native tools**: 10 tools with resolver/executor/adapters (Contacts, EventKit, MessageUI, call flow, security-scoped files, app launching), fakes, permission manager; unit + integration tests. Real-API behaviour on device needs permission taps (human step).
- [x] **Phase 4 — streaming ASR**: whisper.cpp partial/final passes, Silero VAD endpointing, transcript stability, hallucination guard + speech gate, command-vocabulary prompt; fixture tests (clean, noisy, silence, echo) pass on the real models.
- [x] **Phase 5 — local TTS**: Kokoro on MLX with clause-first chunking, pipelined synthesis, cancellation (device).
- [~] **Phase 6 — spoken loop**: `VoiceSessionController` wired in the app; on-device self-test (`-VoiceSelfTest`, scripted spoken input through the real pipeline) written — result pending (phone disconnected).
- [~] **Phase 7 — barge-in/echo**: voice processing (AEC), strict barge-in onset, transcript echo verdict (≥ 2 novel words), final-transcript self-transcription guard; fixture tests pass except the documented no-AEC overlap case. Device self-test pending.
- [x] **Phase 8 — model manager**: resumable downloads, storage checks, SHA-256, atomic activation, manifests, corruption recovery, delete/redownload, offline import (used on device).
- [~] **Phase 9 — evaluation/hardening**: safety guards added from findings (see below); prompt v2; full on-device evaluation run pending.
- [ ] **Phase 10 — production candidate**: archive configuration without developer modes, clean-clone build proof, final docs audit.

## Measured results (iPhone 15 Pro)

Full tables and method: `Docs/DEVICE_MATRIX.md`. P50 / P95.

| Metric | Target | Measured |
|---|---|---|
| Endpoint → final transcript | < 500 ms | 196 / 199 ms |
| Nemotron → complete structured result (6 commands) | < 750 ms | 1285 / 1781 ms (not met; 2105 ms at first measurement) |
| TTS first chunk | < 300–500 ms | 365 / 443 ms |
| Endpoint → first audio, longest command | — | 2416 / 2441 ms |
| Peak memory, all models resident | no jetsam | 1.27 GB |
| Cold start (first launch) / warm launch | — | Whisper 17.5 s / 0.28 s · Nemotron 41 s / 4.5 s · Kokoro 5.6 s / 1.0 s |

Evaluation (Mac CPU smoke, 30 stratified cases, prompt v1): 76.7% case pass, release gate
**PASS** (0 false consequential executions, 100% confirmation classification). Full results:
`Docs/EVALUATION.md`.

## Safety findings fixed this session

1. **Self-confirmation through echo** — after a (false) barge-in the final transcript went to the
   agent unchecked; an echo like "send it yes" of "Should I send it? Please say yes or no" would
   have counted as a yes. Fixed: utterances that began over the assistant are dropped when they
   match what it said; barge-in needs ≥ 2 words the assistant is not saying.
2. **Silence/noise hallucinations** ("you", "Okay.") on clips longer than 1.2 s reached the agent;
   "okay" is an affirmation. Fixed with a Silero speech gate on hallucination-prone transcripts.
3. **Prompt repeated the current utterance** under "Recent conversation". Fixed.
4. **End-of-speech → first-audio metric** was recorded after the whole reply finished. Fixed.

## Current failures / blockers

- The phone intermittently disappears from `devicectl` (`unavailable`), interrupting device runs.
- Nemotron latency is above the PRD's 750 ms target on the A17 Pro (hardware-bound: 77 ms per
  sampled token; analysis in `Docs/DEVICE_MATRIX.md`).
- Barge-in without echo cancellation (raw capture fixture) misses the user's words; documented in
  `Docs/KNOWN_LIMITATIONS.md`.

## Human-only steps (exact instructions)

1. **Keep the iPhone connected, unlocked, trusted, Developer Mode on** for device runs:
   `Scripts/benchmark_device.sh`, `Scripts/eval_device.sh` (≈ 2 h for all 3,249 cases; keep the app
   in the foreground), `-VoiceSelfTest`.
2. **Talk to it.** Launch Voice Agent normally, finish onboarding, tap the orb, allow the microphone,
   and say "Text <a contact> that I'll be late", answer "yes", tap Send in Messages. Contacts,
   Calendar and Reminders permissions are requested the first time a request needs them.
3. First install on a device: *Settings → General → VPN & Device Management → Apple Development:
   Mouhamad Mamane → Trust*.
4. TestFlight: enroll in the paid Apple Developer Program, set `DEVELOPMENT_TEAM` in `App/project.yml`,
   archive the `VoiceAgent` scheme (Release) and upload from Xcode Organizer.

## Next actions

- Collect the voice self-test result; run the full evaluation on the phone and document it.
- Iterate the prompt on evaluation findings (tool selection for calendar/reminders/files).
- Release configuration without developer launch modes; clean-clone build; docs audit.
