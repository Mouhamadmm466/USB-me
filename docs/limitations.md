# Known limitations

Honest list of what V1 does not do, and where the implementation is bounded by Apple's platform,
the chosen models, or what could be verified in this environment.

## Product scope (by design, PRD §1.3)

- English only. No wake word or always-on listening; a session starts with a tap.
- Not a Siri replacement or a general phone controller. Only the 10 allow-listed tools exist.
- No payments, purchases, credentials, deletion, or device/security settings (risk 3, no tool).
- No alarms/timers, email, social media, web browsing, or arbitrary URLs.
- Messages are composed in Apple's Messages sheet; **you tap Send**. The app cannot send silently.
- Calls open the system call flow; iOS may ask for its own confirmation.
- `open_supported_app` opens a fixed set of apps (Maps, Music, Messages, Mail, Calendar, Settings,
  App Store, Shortcuts). Only Maps accepts a search query. "Settings" opens this app's settings page
  (Apple does not allow deep links into other settings pages).
- Files: only folders you pick; search is by file name, not file contents.

## Platform

- Requires an 8 GB iPhone (iPhone 15 Pro/Pro Max and later), the Info.plist declares
  `iphone-performance-gaming-tier`. The three models need ~3.4 GB on disk.
- Kokoro TTS runs on MLX, which only works on Apple-silicon GPUs: **no speech output in the iOS
  Simulator** (the `VoiceAgentSim` target shows replies as text). MLX also does not link for the
  x86_64 Simulator.
- Installing on a device needs an Apple development team; this build was signed by team 3MK9V84J42
  (one-year development profile) with the Increased Memory Limit entitlement. A free personal team
  would get 7-day profiles and may be refused that entitlement.
- Background operation is not supported: a session stops when the app leaves the foreground;
  model downloads pause in the background and resume from the last byte on return.

## Latency (measured on iPhone 15 Pro, `docs/evaluation/device_results.md`)

- Nemotron needs 1.3 s (P50) to produce a complete structured result, above the PRD's 750 ms
  target: each sampled token costs 77 ms on the A17 Pro GPU and a command needs 5, 15 of them.
  End of speech → first audio is about 2.9 s for a long dictated message. Speculative decoding
  was implemented and measured, and is off because it is slower on this GPU.
- The first launch after install spends ~1 minute compiling GPU shaders and evaluating the prompt
  prefix; later launches warm up in ~6 s.

## Voice interaction

- A reply spoken *over* the assistant that consists of words the assistant is saying ("yes" while
  it says "please say yes or no") is ignored as possible echo; answer after the question.
- Barge-in relies on iOS echo cancellation. On routes without it (some Bluetooth speakers) the
  assistant may not notice being interrupted; tapping the orb always stops it.
- Whisper base.en transcribes British spellings for British speakers ("mum"); contact matching is
  fuzzy enough for this, but exact-name matches rank higher.

## Models

- Whisper base.en can mis-hear uncommon names; the assistant always reads back the resolved full
  name and shows it on the card before any message or call. Contact names bias the final pass.
- Whisper is not a true streaming ASR: partial text is re-decoded every ~0.7 s and may revise;
  it is display-only.
- Nemotron 3 Nano 4B with reasoning disabled can still misread intent or dates in unusual
  phrasings. Dates are computed by a deterministic parser from the phrase the model copies; the
  spoken confirmation shows the exact date/time for the user to catch errors.
- Measured model quality and latency are in `docs/evaluation/agent_tests.md` and `docs/evaluation/device_results.md`.

## Verification status

See `docs/notes/status.md` for what has been verified on this build machine (Intel Mac, CPU inference)
versus what still requires the physical iPhone (Metal performance, memory/thermal behaviour,
speech output, real-world echo cancellation).
