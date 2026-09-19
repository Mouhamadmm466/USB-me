# Privacy

Voice Agent runs speech recognition, language understanding and speech synthesis entirely on the
iPhone. After the one-time model download, the core path works with the network disabled.

## What stays on the device

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Microphone audio | In memory while a session is active; never written to disk | Never |
| Transcripts and assistant replies | In memory; persisted in the app's SwiftData store only if "Keep history" is on | Never |
| Contacts, calendar, reminders | Read through Apple's frameworks when a request needs them | Never |
| Files | Only folders you choose; read on request | Never |
| Messages you send | Handed to Apple's Messages composer; you tap Send | Sent by Messages, as you would yourself |
| Model files | App container, excluded from iCloud backup | Never uploaded |

## Network use

- **Model downloads only**: the exact pinned files from Hugging Face (NVIDIA, ggerganov,
  ggml-org, mlx-community). Requests carry no user data.
- No analytics SDKs, no crash reporters, no cloud ASR/LLM/TTS, no accounts.

## Telemetry

Diagnostics are on-device only and contain event types, timings, status and anonymized error
codes — never audio, transcripts, contact names, phone numbers, message text, calendar titles or
file names. This is enforced by the logger's type system (`SafeLabel`), and the native runtimes'
own logging is silenced. Benchmark reports use fixed synthetic phrases, not user data.

Developer builds (Debug/Profile configurations) add launch modes for the benchmark, the on-device
evaluation and the voice self-test; they use synthetic phrases and fake contacts/calendars and write
their reports to the app's Documents folder for the developer's Mac to collect. The Release (App
Store) configuration compiles these modes out.

## Controls

- **Clear history** (Settings → Privacy) deletes all stored turns.
- **Keep history** off: nothing is persisted.
- **Retention**: stored turns older than the chosen number of days are pruned.
- **Delete models** (Settings → Models) removes model files; re-download is available.
- Permissions are requested just in time and can be revoked in iOS Settings at any time.

## Data protection

The SwiftData store and model directories use iOS Data Protection
(`completeUntilFirstUserAuthentication`) and are excluded from backups.

## App Store privacy label (expected)

"Data Not Collected". The app does not collect or transmit personal data.
