# Architecture

A private, English-only voice agent for iPhone. Speech recognition (whisper.cpp), reasoning
(NVIDIA Nemotron 3 Nano 4B Q4_K_M on llama.cpp + Metal) and speech synthesis (Kokoro 82M on
MLX Swift) all run on the device. Swift owns every decision that has a side effect.

## Principles (non-negotiable)

1. **Swift owns state.** `AgentStateMachine` (Core) is an explicit transition table. The model's
   output is an untrusted *proposal*.
2. **Partial ASR is UI-only.** `PartialTranscript` and `FinalTranscript` are distinct types. The
   agent API accepts only `UserUtterance` (`.speech(FinalTranscript)` or `.typed(String)`), and
   `FinalTranscript` can only be constructed inside the package by ASR finalization.
3. **Constrained output.** Nemotron decodes under a GBNF grammar generated from `ToolCatalog`;
   every output is re-validated by `OutputValidator` (unknown type/tool, missing field, bad enum,
   oversize value, malformed JSON ⇒ reject and recover, never execute).
4. **Native resolution.** The model never supplies identifiers. Contacts, phone numbers, events and
   files are resolved by Swift against native stores (`ActionResolving`). Dictated phone numbers must
   appear in the user's own words.
5. **Confirmation binds to a version.** Risk ≥ 1 actions become an immutable `PendingAction`
   (id, version, SHA-256 argument digest, expiry). Approval yields a `ConfirmationToken`; the
   executor re-checks it immediately before the side effect. Any change creates version n+1 and
   clears approval.
6. **Swift speaks consequential actions.** The confirmation prompt and action card are rendered
   deterministically from the resolved action (`ActionSummarizer`), not from model prose, so the
   user hears exactly what will run.
7. **Tool content is data.** Calendar titles, file names and contact fields never authorize actions;
   only the user's direct input (voice/typed/tap) can.
8. **Report only what happened.** Results are spoken from the native API's actual return value.

## Module map (SwiftPM package `VoiceAgentKit` + iOS app target)

| Module | Folder | Responsibility |
|---|---|---|
| Telemetry | `Telemetry/` | `PrivacySafeLogger` (typed, content-free events), `PerformanceMetrics` (P50/P95, memory, thermal) |
| Core | `Core/` | `AgentState` + state machine, `SessionState`, `PendingAction`, `RiskLevel`, `ToolCatalog`, `ResolvedAction`, transcripts, runtime protocols, configuration |
| Permissions | `Permissions/` | Just-in-time `PermissionManager` over a testable backend |
| Storage | `Storage/` | SwiftData session/settings/model-metadata stores |
| Models | `Models/` | Manifest, resumable download manager, SHA-256 integrity, atomic activation, lifecycle |
| Tools | `Tools/` | Resolver + executor; Contacts, EventKit, MessageUI, calls, scoped files, allow-listed apps; fakes |
| Intelligence | `Intelligence/` | V2: the personal intelligence — assertion store, memory pipeline, context builder, knowledge, plans, artifacts, attention (see [INTELLIGENCE.md](INTELLIGENCE.md)) |
| LLM | `LLM/` | `NemotronRuntime` (llama.cpp), `PromptBuilder`, grammar, `AgentOutput`, `OutputValidator`, `ContextManager` |
| ASR | `ASR/` | `WhisperRuntime` (whisper.cpp), Silero VAD via whisper.cpp, transcript buffer |
| TTS | `TTS/` | `KokoroRuntime` (KokoroSwift/MLX), `SpeechChunker`, `SpeechQueue`, playback |
| Audio | `Audio/` | `AVAudioSession`/`AVAudioEngine` (voice processing), router, energy VAD, `EndpointDetector`, `EchoBargeInController` |
| Agent | `Agent/` | `AgentCoordinator`, `ConfirmationManager`, `ClarificationManager`, `CapabilityRegistry`, `ActionSummarizer`, voice session |
| App | `App/` | SwiftUI app (`AppEntry/`, `UI/`), composition root, Xcode project |
| AgentEval | `Tests/AgentEval/` | 2,500+ case dataset, fixtures, runner CLI (`agent-eval`), scoring, reports |
| DeviceBenchmark | `Tests/Benchmarks/` | On-device feasibility benchmark (Phase 1) |

Dependency direction: `Telemetry ← Core ← {Permissions, Storage, Models, Tools, LLM, ASR, TTS, Audio} ← Agent ← App`.
`Agent` depends only on protocols for ASR/TTS/audio, so the entire conversation logic is testable
with fakes on macOS.

## Turn pipeline

```
mic ─▶ AudioEngine (VPIO AEC) ─▶ 16 kHz frames ─▶ VAD ─▶ EndpointDetector
                                                     │ partial every ~0.7 s ─▶ Whisper (UI only)
                                                     ▼ endpoint
                                               Whisper final ─▶ FinalTranscript
                                                     ▼
AgentCoordinator ──(pending action?)──▶ ConfirmationManager (deterministic) ─▶ approve/reject/modify
      │ (clarification?)──▶ ClarificationManager (deterministic candidate match)
      ▼ otherwise
PromptBuilder (cached prefix + compact state) ─▶ Nemotron (grammar) ─▶ OutputValidator
      ▼ proposed_action
ActionResolver (Contacts/EventKit/files, date parser) ─▶ clarification | PendingAction | read-only run
      ▼
ActionSummarizer ─▶ SpeechChunker ─▶ Kokoro ─▶ AudioEngine playback (barge-in aware)
```

## State machine

See `Core/AgentState.swift` (`AgentStateMachine.allowed`). `error` is reachable from every state;
all other transitions are enumerated and unit tested (`Tests/Unit/Core`).

## Nemotron runtime (LLM/NemotronRuntime.swift)

- **Prefix state cache.** The static prompt (system rules, tool list, few-shot examples, ~2.4K
  tokens) is evaluated once; the resulting sequence state (4 attention layers' KV cache + Mamba-2
  recurrent state) is snapshotted in memory and on disk, keyed by model, prompt and llama.cpp
  build. Every turn restores it and evaluates only the turn suffix (0.16 s load vs 17.7 s cold).
- **Priming.** At speech onset the voice loop asks the coordinator to `prime` the runtime with the
  turn context up to "User:" (clock, pending action, recent turns). After the endpoint only the
  utterance and the reply opening are evaluated; the primed state is used only when the final
  request starts with exactly the primed tokens. No partial transcript is involved.
- **Grammar + jump-forward.** Greedy decoding under a GBNF grammar generated from `ToolCatalog`.
  An NFA of the same language finds text the grammar forces (keys, punctuation, the rest of an enum
  value, `requires_confirmation` fixed per tool) and evaluates it in the same decode call as the
  sampled token; the reply opening `{"type":"` is evaluated with the prompt.
- **Speculative decoding (off).** Prompt-lookup drafting from the utterance with llama.cpp's
  recurrent-state rollback (`n_rs_seq`) is implemented and tested, but disabled: on the A17 Pro,
  2–8 token decode calls cost nearly linearly more than one token (`Docs/DEVICE_MATRIX.md`).

## Early confirmation lead-in (Agent/ConfirmationLead.swift, TTS/SpeechQueue.swift)

A message confirmation starts with the recipient ("Text Alex Kim: “…” Should I send it?"). While
Nemotron streams the proposal, the coordinator watches for a `compose_message` whose
`contact_query` value is complete, resolves it natively (read-only; skipped unless Contacts access
is already granted and exactly one contact matches) and has the speech queue start speaking
"Text Alex Kim:" while the model is still writing the body. When the complete output has been
validated, resolved and turned into a versioned `PendingAction`, the Swift-authored confirmation is
spoken: the queue continues after the lead-in if the text starts with it, otherwise cuts it. A
barge-in over the lead-in cancels the rest. Nothing is proposed or executed early.

## Voice loop safety (Agent/VoiceLoop/VoiceSessionController.swift)

- Utterances enter the agent only after endpointing, as `FinalTranscript`s.
- While the assistant speaks, frames go to `EchoBargeInController`: strict VAD onset → duck TTS →
  quick partial of the onset → confirm only for an interruption keyword the assistant is not saying
  or ≥ 2 words it is not saying; otherwise unduck.
- An utterance that began over the assistant (barge-in or echo tail) is compared again, on its final
  transcript, with the reply text and dropped if it matches: the assistant's own voice can never
  answer its own question.
- Whisper hallucinations on noise ("you", "Okay.") are dropped by length or by a Silero speech gate.

## Resource scheduling (PRD §14)

- While the user speaks: ASR partials; one short LLM priming call (~0.2 s GPU) at speech onset.
- After endpoint: Whisper final, then Nemotron (evaluated suffix only; system prefix state cached).
- While speaking: Kokoro synthesizes the next chunk; LLM generation is not run concurrently unless
  measured safe on the device.
- Nemotron stays resident during a session; a memory warning unloads Kokoro when it is not
  speaking (it reloads on the next reply, ~1 s). Measured peak with everything resident: 1.27 GB.
- Thermal `critical` ⇒ the session stops (the user can start it again); every change is logged.
  The on-device evaluation pauses at `critical` until the phone cools down.
