# Known limitations

Honest list of what V1 does not do, and where the implementation is bounded by Apple's platform,
the chosen models, or what could be verified in this environment.

## Product scope (by design, PRD §1.3)

- English only. No wake word or always-on listening; a session starts with a tap.
- Not a Siri replacement or a general phone controller. Only the 10 allow-listed tools exist.
- No payments, purchases, credentials, deletion, or device/security settings (risk 3 — no tool).
- No alarms/timers, email, social media, web browsing, or arbitrary URLs.
- Messages are composed in Apple's Messages sheet; **you tap Send**. The app cannot send silently.
- Calls open the system call flow; iOS may ask for its own confirmation.
- `open_supported_app` opens a fixed set of apps (Maps, Music, Messages, Mail, Calendar, Settings,
  App Store, Shortcuts). Only Maps accepts a search query. "Settings" opens this app's settings page
  (Apple does not allow deep links into other settings pages).
- Files: only folders you pick; search is by file name, not file contents.

## Platform

- Requires an 8 GB iPhone (iPhone 15 Pro/Pro Max and later) — the Info.plist declares
  `iphone-performance-gaming-tier`. The three models need ~3.4 GB on disk.
- Kokoro TTS runs on MLX, which only works on Apple-silicon GPUs: **no speech output in the iOS
  Simulator** (the `VoiceAgentSim` target shows replies as text). MLX also does not link for the
  x86_64 Simulator.
- A free (personal) Apple team can install on a device for 7 days at a time and may not grant the
  Increased Memory Limit entitlement; TestFlight needs a paid team.
- Background operation is not supported: a session stops when the app leaves the foreground;
  model downloads pause in the background and resume from the last byte on return.

## Models

- Whisper base.en can mis-hear uncommon names; the assistant always reads back the resolved full
  name and shows it on the card before any message or call. Contact names bias the final pass.
- Whisper is not a true streaming ASR: partial text is re-decoded every ~0.7 s and may revise;
  it is display-only.
- Nemotron 3 Nano 4B with reasoning disabled can still misread intent or dates in unusual
  phrasings. Dates are computed by a deterministic parser from the phrase the model copies; the
  spoken confirmation shows the exact date/time for the user to catch errors.
- Measured model quality and latency are in `Docs/EVALUATION.md` and `Docs/DEVICE_MATRIX.md`.

## Verification status

See `BUILD_STATUS.md` for what has been verified on this build machine (Intel Mac, CPU inference)
versus what still requires the physical iPhone (Metal performance, memory/thermal behaviour,
speech output, real-world echo cancellation).
