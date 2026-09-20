# What would make this a product, not a demo

An honest assessment of where V2 stands, what is actually novel about it, and what has to be true
before "a personal AGI owned by the individual" is a claim rather than a slogan.

## What we have built, stated without flattery

A voice assistant that runs entirely on an iPhone, keeps a structured model of the user's world in
an assertion log with provenance and authority, answers from their own documents, and can take a
multi-step job on after showing them the plan. 779 tests. Nothing leaves the device.

That is a strong engine. It is not yet a product, for one reason: **the world model is starved and
silent.** It only learns what the user types or says inside one app, and it only speaks when
spoken to. A model of someone's life that has to be hand-fed, and that never notices anything, is a
notebook with extra steps.

## Where the competition actually is

| | What they do | What they cannot do |
|---|---|---|
| ChatGPT / Claude memory | Remember strings across chats, in the cloud | No structure, no provenance, no correction beyond deletion, not yours, not private |
| Apple Intelligence | On-device, system-wide, app intents | No persistent model of *your* world; no agency past one intent; you cannot inspect what it thinks |
| Rewind / Limitless | Capture everything (screen, audio), search it later | Passive recall of raw material; no world model; enormous privacy surface; no agency |
| Notion AI / Mem / Reflect | Structure you maintain by hand, AI on top | *You* do the modelling work; the AI is a feature, not a mind |

The gap none of them fills: **a structured model of your life that maintains itself, is accountable
for everything it believes, acts only inside a scope you approved, and belongs to you.** That is the
position. Everything below is in service of making that literally true.

## The thesis, sharpened

> **A world model you own.**
>
> Not a chatbot with memory. A structured, inspectable, correctable model of your life that
> (1) maintains itself from the signals you authorize, (2) can explain and undo every belief it
> holds, (3) acts under a scope you approved before it ran, and (4) is portable and revocable.
>
> The assistant is a *view* onto that model. The model is the product.

Five properties follow from that, and they are the roadmap. Each one is something a competitor
structurally cannot copy without giving up their architecture.

### 1. It feeds itself (from what you authorize, visibly)

Today the model only learns from turns in this app. That ceiling is low. What it should learn from,
with explicit permission and a visible record:

- **Calendar and reminders** — who you meet, what recurs, what you said you would do. Already
  permissioned in V1; today they are only read for one tool call and thrown away.
- **Anything you share** — the share sheet is the highest-value, lowest-creepiness ingestion path
  in iOS. A PDF, a page, a message thread, a screenshot of a whiteboard: the user is choosing, each
  time, to hand something over.
- **What a job reads** — a document read during a job should leave what it taught behind.

The discipline that makes this not-surveillance is already in the store: observed statements carry
lower authority than the user's own voice, every one shows where it came from, and the whole thing
is one switch away from off. **Ingestion without that discipline is Rewind. With it, it is a world
model.**

### 2. It notices (and interrupts almost never)

Attention rules exist; nothing uses them unless the app is open. A personal AGI has to bring value
without being summoned — a morning brief, "the thing you promised Sarah is due tomorrow", "the
review moved and your prep is now due tonight".

The risk is obvious: proactive assistants become noise and get muted. So this ships with an
**interruption budget**: a small, fixed number of notifications per day, silence as the default,
every notification carrying its reason, and a running score of whether they were acted on — if a
kind of nudge is repeatedly ignored, it stops. Earning the right to interrupt is a product feature,
not a setting.

### 3. It becomes *yours* (learns its own parameters from your corrections)

Every assistant is the same assistant for everyone. This one has something almost nobody has: a
stream of explicit corrections — confirmed, rejected, undone, edited. Those should tune the system
itself, visibly:

- **Attention weights** — you keep dismissing "gone quiet" nudges? They fall.
- **Confirmation thresholds** — you always approve reminder steps? Stop asking for those.
- **Your voice** — drafts should sound like you write, learned from what you actually send.
- **Your vocabulary** — project and people names bias the speech recognizer, so it stops mishearing
  the words that matter most to you.

All of it shown on one screen, all of it resettable. "It adapts to you" is the oldest claim in the
category; being able to *show the user exactly what adapted* is the novel part.

### 4. It is portable (or it is a sandcastle)

Today: lose the phone, lose the world model. "You own it" is not true if it cannot leave. It needs
an encrypted, versioned archive the user holds — restorable onto a new device, readable without this
app, and small enough to keep in iCloud Drive or on a stick. This is the cheapest feature on this
list and the one that makes the ownership claim honest.

### 5. It lives in the system, not in an app

An agent you have to open is an app. An agent in the system is infrastructure: Shortcuts and App
Intents (Action button, Siri, Spotlight), a widget showing what needs you, a Live Activity while a
job runs, the share sheet. On iOS this is the difference between a thing people try and a thing
people use.

## What I am deliberately *not* proposing

- **Capture everything.** No screen recording, no always-on audio. The entire trust position rests
  on the user choosing what to hand over. It would also be a worse world model: signal, not volume.
- **A bigger model.** The 4B is not the bottleneck; the bottleneck is what it knows about you and
  what it is allowed to do. Swift owning control flow is why a 4B can do this at all.
- **A cloud "sync" that is really a server.** Portability, yes. A copy of your life on someone
  else's computer, no.

## One architectural question worth raising now

iOS 26 exposes Apple's on-device model to apps (FoundationModels, guided generation). Ours is a
2.8 GB download and ~1.3 GB resident. Apple's is already on the phone, NPU-accelerated, and free.

It is not obviously better for our contracts — we depend on GBNF grammars and a prefix-state cache
that we control — but for the *background* contracts (memory extraction, artifact prose) it could
cut RAM and battery and make first launch instant, with no download at all. `LanguageModel` already
abstracts the runtime, so this is an adapter, not a rewrite. Worth doing as an option, once the
above is real, and worth measuring rather than assuming.

## Order of work, and why

1. **Network policy and web research** *(in progress)* — the user asked for it, and it is the spine
   for anything that touches the world: modes, a per-capability gate, and a visible log of what left
   the device, why, and to whom. The novel part is not "it can search"; it is that the user can see
   every byte that left and the payload is built from tool arguments alone, never from their world.
2. **Ingestion** — calendar/reminders observers and the share extension, feeding the world model
   under observation authority.
3. **Proactivity with an interruption budget** — notifications, the morning brief, Live Activity.
4. **Adaptation from corrections** — visible parameters that the user's own behaviour tunes.
5. **Portable encrypted archive** — the ownership claim, made true.
6. **System surfaces** — App Intents, widget, Action button.

Each one is shippable on its own, and each one is measured by the same evaluation harness, extended
with the suites it needs (network routing matrix, ingestion authority, interruption budget,
restore fidelity).
