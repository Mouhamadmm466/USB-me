# BUILD_STATUS

Living status for the offline iPhone voice agent. Updated continuously while building.
Source of truth for requirements: `Offline_iPhone_Voice_Agent_PRD_and_Autonomous_Build_Prompt.docx` (PRD).

_Last updated: 2026-09-19 (session 2: V2 — the personal intelligence)._

## Environment facts that shape the plan

| Fact | Consequence |
|---|---|
| Build Mac is an **Intel Core i7-1068NG7 (x86_64), 16 GB**, macOS 26.6.2, Xcode 26.5, Swift 6.3.2 | MLX (Kokoro) cannot run on this Mac or in the x86_64 Simulator, so TTS runs only on the iPhone. whisper.cpp and llama.cpp run here on the CPU: unit/fixture tests and small evaluation runs use the **real** models, but a turn takes 5–40 s, so full evaluation runs use the phone. |
| Device: **iPhone 15 Pro (iPhone16,1, 8 GB), iOS 26.6.1**, connected by cable (drops off `devicectl` intermittently) | All device results below come from this phone. |
| Signing: team **3MK9V84J42** (Mouhamad Mamane), Xcode-managed development profile created 2026-09-19, valid until 2027-09-19 | A one-year development profile indicates a paid Apple Developer Program membership (free teams get 7-day profiles). Device builds work and the Increased Memory Limit entitlement is granted. TestFlight upload needs an Apple Distribution certificate and an App Store Connect app record — account changes left to the owner. |
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
- [~] **Phase 6 — spoken loop**: `VoiceSessionController` wired in the app, with the early "Text <name>:" lead-in. The on-device self-test (`-VoiceSelfTest`, scripted spoken input through the real pipeline) is written but **was not run to completion**: the phone stayed locked, and the one run that started was killed by a launch-watchdog bug in the self-test itself (fixed since). Testing was stopped at the owner's request.
- [~] **Phase 7 — barge-in/echo**: voice processing (AEC), strict barge-in onset, transcript echo verdict (≥ 2 novel words), final-transcript self-transcription guard; fixture tests pass except the documented no-AEC overlap case. Device self-test pending.
- [x] **Phase 8 — model manager**: resumable downloads, storage checks, SHA-256, atomic activation, manifests, corruption recovery, delete/redownload, offline import (used on device).
- [~] **Phase 9 — evaluation/hardening**: safety guards added from findings (see below); prompt up to 2026-09-19.4. The full 3,249-case run was **not run** (testing stopped at the owner's request); measured so far: 30-case stratified subsets on the Mac, 76.7% → 86.7% case pass, 0 false consequential executions.
- [x] **Phase 10 — production candidate**: Release configuration without developer modes (verified in the binary), privacy manifest, clean-clone build proof, full `swift test` pass, UI tests, docs. Archive/upload are owner steps (distribution certificate, App Store Connect record).

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
2. **Talk to it** (the parts no script can do: your voice through the real microphone, iOS permission
   prompts, Apple's own sheets). Launch Voice Agent normally and follow `Docs/DEMO.md`, ideally in
   Airplane Mode. Checklist:
   - [ ] Onboarding shows the models as installed; "Start" reaches the assistant.
   - [ ] First mic tap: the explainer sheet, then the iOS microphone prompt; the session starts.
   - [ ] "Text <contact> that I'll be late": live transcript, spoken read-back starting with
         "Text <name>:", card with name/number/text; "yes" opens Messages pre-filled; you tap Send.
   - [ ] Contacts, Calendar and Reminders prompts appear only on the first request that needs them.
   - [ ] Interrupting the assistant mid-sentence stops it and handles what you said.
   - [ ] Speaker playback does not trigger the assistant itself (no self-replies) at normal volume.
3. First install on a device: *Settings → General → VPN & Device Management → Apple Development:
   Mouhamad Mamane → Trust*.
4. TestFlight: enroll in the paid Apple Developer Program, set `DEVELOPMENT_TEAM` in `App/project.yml`,
   archive the `VoiceAgent` scheme (Release) and upload from Xcode Organizer.

## Final handoff (PRD checklist)

| # | Item | Where |
|---|---|---|
| 1 | Repository structure | `README.md` (layout), `Docs/ARCHITECTURE.md` (modules, dependency direction) |
| 2 | Build / run | `Docs/BUILD.md` (Debug / Profile / Release, simulator, device, archive) |
| 3 | Model download / install | In-app downloader (Settings → Models, onboarding); `Scripts/download_models.sh` + sideload via `Scripts/benchmark_device.sh`; pins in `Docs/MODEL_MANIFEST.md` |
| 4 | Supported devices | `Docs/DEVICE_MATRIX.md` |
| 5 | Benchmarks / evaluation | `Docs/DEVICE_MATRIX.md`, `Docs/EVALUATION.md`, `Tests/Benchmarks/Results/`, `Tests/AgentEval/Results/` |
| 6 | Human-only steps | this file, below |
| 7 | Known limitations | `Docs/KNOWN_LIMITATIONS.md` |
| 8 | Security / privacy review | `Docs/SECURITY.md`, `Docs/PRIVACY.md`, `App/Resources/PrivacyInfo.xcprivacy` |
| 9 | Demo script | `Docs/DEMO.md` |
| 10 | Tests and clean build | `swift test` (unit, integration, ASR/VAD fixtures on the real models, eval-dataset integrity), `xcodebuild test` (UI flows in the simulator), clean-clone build log — see "Verification" below |

## Verification

- `swift test` on the build Mac (2026-09-19, commit 3da03ae+): **637 tests in 79 suites passed**
  in 202 s, 1 known issue (barge-in over the assistant without echo cancellation, documented).
  Includes the ASR/VAD fixture tests on the real Whisper base.en and Silero models and the
  evaluation-dataset integrity checks.
- Clean clone (fresh `git clone` → `Scripts/bootstrap_dependencies.sh` → `swift build` →
  `xcodebuild -scheme VoiceAgent -configuration Release`): **all succeeded** (6.6 + 5 + 9 min).
- UI tests (simulator, demo mode): launch; confirm a message from the card; cancel a call from the
  card; Settings → Licenses shows the NVIDIA notice — all pass.
- Live model download through the app's downloader (opt-in): passes.
- Release (App Store) configuration builds for iOS with no developer launch modes in the binary.
- Networking: only `Models/` (the model downloader) uses URLSession; nothing else can reach the network.

## TestFlight

- **2026-09-19: build 2.0.0 (2) uploaded to App Store Connect** — the V2 build (personal
  intelligence, jobs, artifacts, attention). Archive validated and uploaded with
  `xcodebuild -exportArchive`; App Store Connect accepted the package and began processing.
  779 tests pass, the Release configuration builds free of developer launch modes, and the privacy
  manifest already covers the disk-space and file-timestamp reads the intelligence store makes.
- **2026-09-19: build 1.0.0 (1) uploaded to App Store Connect** (`xcodebuild -exportArchive` with
  `App/ExportOptions-AppStore.plist`; upload-time package and SPI analysis passed with no warnings).
  App record and internal testing are managed by the owner in App Store Connect.
- Before the upload: app icons re-encoded without an alpha channel (rejected otherwise), privacy
  manifest added, Release configuration verified free of developer launch modes.
- Next upload: bump `CURRENT_PROJECT_VERSION` in `App/project.yml` (build numbers must increase).

## V2 — the personal intelligence (this session)

Built on branch `v2`, extending V1 rather than replacing it. See
[Docs/INTELLIGENCE.md](Docs/INTELLIGENCE.md) and `V2_IMPLEMENTATION_PLAN.md`.

- [x] **Intelligence store** — entities + an assertion log with provenance, authority, validity and
  state; entity columns are a materialized view of the winning statements (schema v1–v5, FTS5).
- [x] **Memory pipeline** — deterministic pre-filter, grammar generated from the predicate catalog,
  validator, policy (accept · ask · drop), entity resolution, conflict resolution, activity + undo.
- [x] **Personal context** — entity linking, budgeted retrieval, knowledge passages; empty for any
  utterance that names nothing known, so V1's latency path is untouched.
- [x] **Knowledge** — PDF/text/Markdown/RTF/DOCX/HTML parsing in-process, heading-aware chunking,
  FTS5 BM25 retrieval with recency and project nudges.
- [x] **Capabilities, playbooks, plans** — a registry over V1's tools plus V2's own, scope decided
  before the model runs, plan grammar built from that scope, plans persisted and resumable.
- [x] **Agent runtime** — one step at a time, checkpointed, with step/attempt/wall-clock/thermal
  limits; a question to the user is a stopping point, not a guess.
- [x] **Artifacts** — Markdown in a Swift-owned skeleton, versioned, with sources.
- [x] **UI** — five tabs (Home, Projects, Ask, Memory, Activity), job cards, artifact reader,
  entity detail with provenance, export and delete.
- [x] **Attention** — deterministic rules for what needs the user, shared by Home and the spoken
  answer.
- [x] **Evaluation** — `Tests/IntelligenceEval`: 28 hand-written cases across six suites, runnable
  deterministically or against the real model (`agent-eval intelligence`).
- [x] **Network policy and web research** (PRD 9–10) — off / ask / approved, a per-capability gate,
  a leak check that refuses to send a name the user did not put in their own request, and a log of
  every attempt including the refusals (Settings → "What left this iPhone"). 18 tests.
- [x] **Ingestion** (first half of PRD 12) — calendar and reminders observers, off by default, each
  behind its own switch and its own permission. Everything they write is an observation, which loses
  to the user's own words; they link to people and items the user already has and invent neither;
  they cannot create a commitment or a decision; and switching one off takes back what it created.
  17 tests.
- [ ] **Not built yet**: connected services (PRD 11), the share extension and App Group inbox (the
  second half of 12). Everything else V2 does is local.

## Not done (testing stopped at the owner's request)

- Voice self-test on the phone, the updated benchmark (per-command end-to-end, lead-in effect) and
  the full 3,249-case on-device evaluation. All three run unattended with `Scripts/device_suite.sh`
  once the phone is unlocked and left on the desk (~2 h 10 min).

## Next actions

- Collect the voice self-test result; run the full evaluation on the phone and document it.
- Iterate the prompt on evaluation findings (tool selection for calendar/reminders/files).
- Release configuration without developer launch modes; clean-clone build; docs audit.
