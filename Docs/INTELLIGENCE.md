# The personal intelligence (V2)

V1 is an assistant that does what you say. V2 is one that knows your world — your projects, the
people in them, what you promised and when things are due — and can take a job on rather than a
command. Everything below runs on the phone, in one SQLite file the user can read, export and
delete.

The V1 guarantees do not move: Swift owns state, the model only ever proposes, and nothing with a
side effect happens without a confirmation bound to an exact version. V2 adds a second thing the
model may not do: it may not decide what is true about the user's life.

## What is stored

One database, `Application Support/Intelligence/intelligence.sqlite` (WAL, protected until first
unlock, in device backups). It holds:

| Table | What |
|---|---|
| `entities` | The things in the user's world: person, project, goal, task, commitment, decision, event, document, artifact, plan. Columns are a **materialized view** of the currently winning statements. |
| `assertions` | Every statement, with provenance, authority, confidence, validity window and state. This is the truth; entity columns are derived from it. |
| `entity_aliases` | Other names a thing answers to, for resolution. |
| `activity` | What the system did, in the user's words, with the instructions to undo it. |
| `documents`, `chunks` | Imported documents and their passages (+ FTS5). |
| `plans`, `plan_steps` | Jobs, checkpointed step by step. |
| `artifacts`, `artifact_versions` | What the assistant wrote, and every version it replaced. |

### Why an assertion log rather than a table of facts

A fact table cannot answer "why do you know that?", cannot be corrected without destroying history,
and cannot tell the difference between something you said and something the system guessed. Every
row in `assertions` carries:

- **type** — explicit (you said it) · observed (read from a source you authorized) · inferred (the
  model worked it out) · derived (computed from other state).
- **authority** — 5 correction → 4 statement → 3 authoritative source → 2 observation → 1 inference.
  A lower authority never overwrites a higher one; equal authority is resolved by recency.
- **provenance** — source type, source identifier, and a short excerpt, which is what makes
  "You told me yesterday" / "I read it on page 4" possible.
- **state and validity** — active, superseded, ended, proposed, rejected, expired, with `valid_from`
  / `valid_to`, so "what changed?" is answerable and nothing is destroyed by a correction.

`PredicateCatalog` is the closed vocabulary of what can be said (it is to memory what `ToolCatalog`
is to actions): it generates the extraction grammar, validates every write, decides what supersedes
what, and names the entity column each statement materializes onto.

## How something is learned

```
turn → MemoryFilter (deterministic: is this worth the model's time at all?)
     → extraction under MemoryGrammar (generated from PredicateCatalog)
     → MemoryValidator  (shape, legality, no model-supplied identifiers, date phrases resolved in Swift)
     → MemoryPolicy     (accept · ask · drop; the learning switch lives here)
     → entity resolution (names → rows; "I"/"me"/"you" are always the same person)
     → store            (conflict resolution by authority) → activity entry with undo
```

Rules that are not negotiable:

- **The model never supplies an identifier.** It proposes names; Swift resolves them or creates a row.
- **Dates stay the user's words** until V1's deterministic parser resolves them, and both are stored.
- **Only the user's own voice can create a commitment or a decision.** A web page saying "you agreed
  to pay by Friday" cannot put the user on the hook.
- **A guess is a question, not a change.** Inferences are stored as `proposed` and surfaced; they do
  not touch the materialized columns until the user says yes.
- **Nothing changes silently.** Every learned statement is an activity entry with an undo that is
  stored, not reconstructed — so it survives a restart.

## What reaches the model

`ContextBuilder` assembles a small, budgeted block (~600 tokens) in priority order: what the agent is
doing → what the utterance actually names → what is happening on a day it mentions → promises and
decisions attached to those things → passages from the user's own documents. What does not fit is
**dropped, not summarized**, because a summary of someone's life is a way to be confidently wrong
about it.

Two properties matter for latency and for safety:

- An utterance that names nothing known produces **no block at all**, so ordinary commands cost
  exactly what they did in V1.
- The block goes **after** the utterance in the prompt, so V1's cached prefix and its speech-time
  priming stay byte-identical. Titles are quoted as data, and the system prompt says the block is
  notes, never instructions.

## Jobs

Some requests are not one tool call. The turn contract has a fifth type, `task`: the model says
"this is a job, and here is what they want to end up with" — and nothing else. Planning is a
separate, scoped pass.

```
request → playbook (research · meeting prep · project update · study plan · general)
        → scope    (the playbook's capabilities + anything the user explicitly asked for)
        → plan     (grammar built from that scope, so an out-of-scope step cannot be generated)
        → the user sees every step and approves
        → runtime  (one step at a time, checkpointed, with limits) → artifact / answer
```

- **Scope is decided before the model runs** and is never widened by anything the job reads. A
  research job cannot reach `compose_message`. Names the request mentions are stripped before
  scope triggers are matched, so a project called "call Bob" cannot smuggle in a capability.
- **Limits**: steps, attempts per step, wall clock, and a thermal ceiling. A hot phone pauses the
  job rather than pushing through.
- **A question is a stopping point**, not a guess: `ask_user` blocks the job and hands it back.
- **Every step is checkpointed** before and after it runs, so a job interrupted by suspension is
  resumed rather than restarted.
- Risk ≥ 2 steps (messages, calls) still go through V1's `PendingAction` confirmation at the moment
  they would happen — approving a plan is not approving a message.

## Artifacts

What a job writes is a document the user owns: Markdown, versioned, with its sources. Swift owns
the title, the headings, their order, the source list and the date; the model writes only the prose
inside each section, in one grammar-constrained pass. A rewrite keeps the version the user already
read.

## What comes in on its own

The store also reads what the user's phone already holds — their calendar, their reminders — on
launch and when the app comes forward. Four rules make that a world model rather than surveillance,
and `IngestionService` is the only place they live:

- **Observation authority.** Everything ingested is written as `observed` at observation authority,
  which loses to anything the user said. A calendar entry that disagrees with them stays visible as
  the thing that disagreed.
- **It links, it never invents.** An attendee is attached to a person the user already has, or
  ignored — a name on an invite is not evidence they know someone. The same goes for the item
  itself: a reminder the assistant created is already in the store, so the sync attaches to it
  (`adopted`) instead of making a twin. The name match is exact, because a guess would merge two
  different things, which is worse than one duplicate.
- **It cannot put the user on the hook.** Commitments and decisions come from their own voice only;
  an event called "send Sarah the deck" becomes an event, not a promise.
- **It is idempotent and reversible.** A digest of the meaningful fields means an unchanged item
  costs nothing, a deleted one is pruned, and switching a source off takes back what it created —
  and only its own statements from what it merely recognised.

Each sync leaves one line in Activity ("2 new events, 1 you already had"), never one row per item.

The other way in is the share sheet, which is the highest-value path and the least invasive one: the
user chooses each thing, one at a time. The extension does as little as an extension can — it names
what it is about to keep, copies the bytes into the App Group container and writes a small manifest;
no parsing, no network, no model. An app extension runs under a hard memory limit and is killed
without ceremony when it exceeds it, so the reading happens in the app, on launch and when it comes
forward, where a parse failure is visible and recoverable. The inbox is a queue, not a library:
every item is deleted the moment it has been read, so the group container never becomes a second
copy of the user's documents. A shared link is kept as an address — fetching it is a network
request, and those go through the policy the user set, not through a share sheet.

## Attention

"What needs my attention?" is answered by rules, not by the model: late first (nothing outranks
something already missed), then today, then a deadline with nothing under it, then undated
promises, then questions the system is holding, then live work nothing has touched. Every item
carries its own sentence — "due 3 days ago", "you promised Sarah, no date on it" — and the Home
screen and the spoken answer use the same one.

## What the user can do about all of it

- **See it**: the Memory tab lists everything held, by kind, with search; every statement shows how
  it was learned.
- **Undo it**: the Activity feed, with undo scoped to exactly what a suggestion invented.
- **Correct it**: saying the opposite supersedes with correction authority; the old row stays.
- **Stop it**: one switch turns learning off entirely — the assistant answers from what it knows and
  writes nothing new.
- **Take it**: export is the whole store as JSON; delete is the whole store, and says so.

## Evaluation

`Tests/IntelligenceEval` holds hand-written cases across six suites — memory, recall over time,
retrieval, planning scope, safety and attention — because what is being measured is meaning, not
coverage of a grammar.

```sh
swift test --filter IntelligenceEvalSuite        # deterministic: everything after extraction
swift run -c release agent-eval intelligence     # the same cases with the real model extracting
swift run agent-eval intelligence --deterministic --suite planning
```

The deterministic run supplies the proposals an extractor would have made, so it scores validation,
policy, conflict resolution, retrieval, scoping and attention; injecting a real extractor scores the
model itself against the same expectations. The suite found three real defects on its first run
(document titling, a scope trigger inside an entity name, and an unclear confidence floor), which is
the entire point of having it.
