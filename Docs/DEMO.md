# Demo script (5 minutes)

Shows the core promise: speech in, spoken confirmation, voice answer, a real action through Apple's
UI — with the network off. Uses your own contacts and calendar, so pick a contact you can safely
text (e.g. yourself, saved as a contact).

## Before you start

1. iPhone 15 Pro or later with the models installed (onboarding, or `Scripts/benchmark_device.sh`,
   which also sideloads them). Launch once so the models warm up (~6 s; ~1 min the very first time).
2. Turn on **Airplane Mode** (Wi-Fi off too). Everything below runs on the phone.
3. Volume up; hold the phone at arm's length (the speaker is used, with echo cancellation).

## 1. A message, confirmed by voice

- Tap the orb. The first time, the app explains the microphone, then iOS asks — allow it.
- Say: **"Text Sam that I'll be 20 minutes late."**
- Watch: live transcript while you speak; the orb turns amber.
- Hear: **"Text Sam Lee: “I'll be 20 minutes late.” Should I send it?"** — the first words start
  while the model is still writing the message. The card shows name, number and the exact text.
- Say: **"Yes."** → Messages opens with the text filled in. **You tap Send** (the app never sends
  silently). Then: "Sent to Sam Lee."

## 2. A correction before confirming

- Say: **"Remind me to call the dentist tomorrow at 10."**
- Hear the read-back with the exact date and time.
- Say: **"Actually make it 11."** → a new version of the reminder is read back (the old approval
  is gone). Say **"Yes"** → it is in Reminders.

## 3. Reading the calendar, and interrupting

- Say: **"What's on my calendar tomorrow?"** — it reads your events (read-only, no confirmation).
- While it is talking, say: **"Stop — call Mom instead."** The voice stops within a moment and it
  asks: "Should I call Mom on mobile?"
- Say: **"No."** → nothing happens.

## 4. What it refuses

- Say: **"Send 200 dollars to Alex."** → "I can't handle payments or money transfers."
- Say: **"Delete my dentist appointment."** → it says it can't delete things; deleting is not a
  capability at all (no tool exists for it).

## What to point out

- Airplane Mode stayed on the whole time: speech recognition (Whisper), understanding (Nemotron 3
  Nano 4B) and the voice (Kokoro) all ran on the iPhone.
- The model only proposed; Swift looked up the contact, wrote the read-back, and acted only after an
  explicit "yes" to that exact version.
- Settings → Diagnostics runs the on-device benchmark; Settings → About lists every model and its
  license.
