# V2 — Local Personal Intelligence: implementation plan

Source of truth for requirements: the V2 PRD ("Local Personal Intelligence"). This document is the
engineering plan: what V1 gives us, the architecture of the additions, the decisions that everything
else depends on, the device budget that constrains them, and the phase order.

_Branch: `v2` (V1 stays on `main`, tagged `v1.0.0-build1` = TestFlight build 1.0.0 (1))._

## 0. What V1 already provides (audit)

| V1 system | Where | V2 use |
|---|---|---|
| Nemotron runtime (llama.cpp + Metal), grammar-constrained greedy decoding, prefix-state cache, jump-forward, context priming | `LLM/NemotronRuntime.swift` | Reused. Gains a **session-continuation API** (§4) and larger context. |
| Prompt + grammar generated from a typed catalog, strict output validation | `LLM/PromptBuilder`, `GrammarBuilder`, `OutputAutomaton`, `OutputValidator` | Generalized from `ToolCatalog` to the **Capability Registry**, plus new output contracts. |
| Deterministic conversation brain: state machine, session state, PendingAction (id/version/digest), confirmation + clarification managers, Swift-authored read-backs | `Agent/AgentCoordinator.swift`, `Core/` | Reused unchanged as the *command* path and as the confirmation layer for agent steps. |
| 10 native tools with native resolution (contacts, EventKit, MessageUI, call flow, scoped files, apps) | `Tools/` | Wrapped as capabilities; resolver/executor untouched. |
| Permissions (just-in-time), model manager, audio/ASR/TTS, voice loop with barge-in and echo guards | `Permissions/`, `Models/`, `Audio/`, `ASR/`, `TTS/`, `Agent/VoiceLoop/` | Reused. |
| SwiftData store for conversation turns, settings, model metadata | `Storage/` | Kept for V1 data. V2's intelligence uses its own store (§2). |
| Evaluation harness (3,249 cases), device benchmark, UI tests | `Tests/` | Kept as the V1 regression suite; V2 adds its own harness (§10). |
| Design system (DM Sans, orb, cards), assistant/settings/onboarding screens | `App/UI/` | Extended into the V2 information architecture (§8). |

Baseline verified on this commit: `swift test` 637 tests pass; clean clone builds; Release archive
uploaded to TestFlight. One rename lands first: V1's `CapabilityRegistry` (device telephony /
messaging availability) becomes `DeviceCapabilities`, freeing the PRD's name.

## 1. Architecture

```
            Voice / Text / UI            Share extension        Connections
                      │                        │                     │
                      ▼                        ▼                     ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │                     IntelligenceCoordinator                      │
        │        (extends V1 AgentCoordinator: turns, confirmation)        │
        └───────┬───────────────────┬──────────────────┬──────────────────┘
                │                   │                  │
        ContextBuilder        AgentRuntime        MemoryPipeline
        (budgeted)            (plans, steps)      (propose→validate→policy→resolve)
                │                   │                  │
                ▼                   ▼                  ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │   Personal Intelligence store (SQLite): entities · assertions ·   │
        │   provenance · plans · artifacts · knowledge chunks · activity    │
        └──────────────────────────────────────────────────────────────────┘
                │                   │                  │
                ▼                   ▼                  ▼
          Nemotron (one          Capability         Network policy
          cached prefix,         Registry           (mode · connectivity ·
          many contracts)        (local │ connected) permission · ledger)
```

Rules that do not bend: Nemotron proposes, Swift executes; the model never sees credentials, never
writes persistent state directly, never receives more context than a task needs; external content is
data, never instruction.

## 2. Personal Intelligence store — the assertion log

One SQLite database (`Application Support/Intelligence/intelligence.sqlite`, WAL, protected
`completeUntilFirstUserAuthentication`, included in device backups; the knowledge index and model
files are not). Raw SQLite (system `libsqlite3`) rather than SwiftData because V2 needs FTS5,
relationship queries, explicit migrations and a portable export.

**Entities** carry identity and materialized current values:

```
entities(id TEXT PK, kind TEXT, title TEXT, subtitle TEXT, status TEXT,
         project_id TEXT, starts_at, ends_at, due_at, importance REAL,
         attributes JSON, created_at, updated_at, archived_at)
```

`kind ∈ {person, project, goal, task, commitment, decision, event, document, artifact,
source, connection, plan, plan_step, conversation}`.

**Assertions** are the single mechanism for facts, relationships and provenance. Every statement the
system holds about the world is one row; entity columns above are a materialized view of the
currently winning assertions:

```
assertions(id TEXT PK, subject_id TEXT, predicate TEXT, object_id TEXT NULL,
           value JSON NULL, kind TEXT,              -- relationship | attribute | note
           type TEXT,                               -- explicit | observed | inferred | derived
           authority INT,                           -- 5 correction … 1 inference
           confidence REAL, importance REAL, user_confirmed INT,
           state TEXT,                              -- proposed | active | superseded | ended | rejected | expired
           superseded_by TEXT, source_type TEXT, source_id TEXT, source_excerpt TEXT NULL,
           valid_from, valid_to, expires_at, created_at, updated_at, last_accessed_at)
```

- "Abdou works on the app" → relationship assertion (`works_on`, object = project).
- "The beta is due next Friday" → attribute assertion (`due_at`, value = resolved date + the phrase
  the user actually said).
- "Sarah isn't on the project anymore" → the previous relationship gets `state = ended`,
  `valid_to = now`, and the new correction wins by authority.
- "Why do you know that?" reads `type`, `source_type`, `source_id`, `created_at` off the row.

Authority: 5 explicit correction → 4 explicit statement → 3 authoritative connected source →
2 observation → 1 model inference. A lower authority never overwrites a higher, newer one; equal
authority is resolved by recency; functional predicates (deadline, status, role) supersede, set-valued
predicates (works_on, has_goal) accumulate.

Supporting tables: `plans` / `plan_steps` (agent state and checkpoints), `artifacts` (metadata; the
content is a versioned Markdown file), `documents` / `chunks` + `chunks_fts` (knowledge, §6),
`activity` (what the system did, with undo payloads), `network_log` (provider, capability, data
categories, reason — never content), `connections` (provider, scopes, per-operation permission),
`schema_version`. FTS5 virtual tables over entity titles/aliases and assertion text.

## 3. Memory pipeline

```
turn (user words + what the assistant did)
   → is it memory-worthy? (deterministic pre-filter: entities, deadlines, commitment/decision verbs, corrections)
   → Nemotron continuation, memory grammar  →  MemoryMutationProposal[]
   → MutationValidator   (schema, predicate legality, no model-supplied ids, source authority)
   → MemoryPolicy        (auto-accept · confirm · drop; learning switch; importance threshold)
   → EntityResolver      (names → existing entities, fuzzy, or new)
   → ConflictResolver    (authority, supersession, dedup, corrections)
   → store + activity entry ("Learned: Abdou works on Offline App") + undo
```

Proposals reference entities **by kind + name**, never by identifier, and dates **by the phrase the
user said**, resolved by V1's deterministic date parser. Inference-typed proposals and anything
derived from tool or web content are marked with that provenance and get lower authority; a
commitment or decision can only be created from the user's own words.

## 4. Nemotron: one prefix, several contracts, cheap multi-step

V2 multiplies prompt work, so three things change in the runtime:

1. **One unified cached prefix** (system rules + capability catalogue + few-shot examples for every
   contract) so mode switches cost nothing. Context 4K → 12K (KV grows 64 → 192 MB; only 4 of 42
   layers are attention, so this is cheap on this model). The prefix is evaluated once and its state
   is cached to disk exactly as in V1.
2. **Session continuation** (`NemotronRuntime.continueSession`): evaluate only new tokens on top of
   the current sequence state. The agent loop then pays for each step's *observation*, not for the
   whole history, and memory extraction after a turn pays ~20 tokens instead of re-reading the turn.
3. **Priority scheduling**: one GPU, several consumers. A user turn preempts background work
   (extraction, agent steps) through cancellation between decode calls.

Output contracts, each a generated GBNF grammar plus a mirrored automaton for jump-forward:

| Contract | Output |
|---|---|
| `turn` | `answer` · `clarification` · `proposed_action` (any capability) · `task` (an outcome for the runtime) · `unsupported` |
| `plan` | ordered steps: capability, description, dependencies, network flag |
| `agent_step` | `tool_request` · `finish` · `ask_user` · `blocked` |
| `memory` | mutation proposals |
| `write` | artifact Markdown within a section skeleton |
| `queries` | search queries for research (topic only — no personal context) |

Capability *descriptions* live in the prefix (regenerated only when a connector is added or removed);
*availability* travels in the per-turn suffix and, decisively, in the grammar: a capability that is
unavailable right now cannot be generated at all.

## 5. Agent runtime

```
task → context → plan (validated: known capabilities, acyclic, network flags, risk)
     → step: capability + arguments (schema-validated)
       → policy gate: permission · network mode · connectivity · connector permission · risk
       → confirmation if risk ≥ 1 (V1 PendingAction, scoped to this step or this approved plan)
       → execute (Swift) → observation (summarized into the budget)
     → update plan / replan → … → finish | blocked | needs user | cancelled
```

Hard limits: steps, tool calls, wall clock, tokens. Every step writes a checkpoint, so a job survives
app suspension and resumes with "Continue?". **Capability scoping**: each job carries an allowlist
derived from the request (a research job cannot reach `compose_message` even if a web page asks for
it). Playbooks (meeting prep, project update, research, study plan, "what should I work on") give the
4B model a strong prior; it fills parameters, Swift owns control flow.

## 6. Knowledge layer

Parse (PDFKit, text, Markdown, RTF/HTML, DOCX via zip+XML) → chunk (headings + ~800-character
windows, overlap) → store chunks with metadata → retrieve with SQLite FTS5 BM25 + metadata filters +
recency, then Nemotron reranking of the top candidates. No embedding model until FTS retrieval is
measured as insufficient *and* an embedding model is benchmarked for RAM/thermal cost on device
(PRD §43) — that benchmark is part of Phase 5, not an assumption.

## 7. Context builder and budget

Deterministic retrieval, assembled in priority order (PRD §45) and trimmed to a token budget
(~600 tokens for a turn, ~900 for an agent step): the request → current plan/action state → entities
linked from the utterance (people, projects, goals by name and alias) → temporal matches (today,
Friday, deadlines) → open commitments and recent decisions for those entities → knowledge chunks
when the question is about documents → recent conversation. Everything else is dropped, not
summarized. Nothing personal ever reaches a network capability: network payloads are built from tool
arguments alone.

## 8. Product surface

Tabs: **Home** (greeting, what needs attention, running jobs, recent artifacts), **Projects**
(workspaces: goals, people, tasks, decisions, documents, artifacts, activity), **Intelligence**
(people, goals, memories with provenance and edit/delete, knowledge, connections, export/delete),
**Activity** (timeline with undo). **Ask** stays one tap away on every screen (the V1 orb, voice or
text) and shows agent progress as a checklist of actions — never chain-of-thought.

## 9. Phases (PRD §82) and status

| Phase | Content | Status |
|---|---|---|
| 0 | Audit, plan, baseline | this document |
| 1 | Intelligence store: entities, assertions, provenance, projects/goals/people/decisions/commitments, migrations, tests | done — `Intelligence/Model`, `Intelligence/Store`, 22 tests |
| 2 | Memory extraction: grammar, validator, policy, conflict resolution, corrections | done — `Intelligence/Memory`, 26 tests (model-side wiring in phase 3) |
| 3 | Retrieval + ContextBuilder + budget; personal-context-aware conversation | |
| 4 | Intelligence UI: Home, Projects, My Intelligence, Activity | |
| 5 | Knowledge: import, parse, index, search, project association (+ benchmark) | |
| 6 | Goal planner: goals, plans, steps, dependencies, replanning | |
| 7 | Agent runtime: loop, checkpoints, failure recovery, limits, cancellation | |
| 8 | Artifacts: documents, reports, briefs, versions, viewer/export | |
| 9 | Network policy: modes, connectivity, per-capability requirements | |
| 10 | First online capability: web research (keyless sources + optional search key) | |
| 11 | Connected services: Gmail, Drive, GitHub — one at a time, mocks where credentials are human steps | |
| 12 | Share extension + App Group inbox | |
| 13 | Attention engine and "what needs my attention?" | |
| 14 | Full evaluation: memory, retrieval, planning, runtime, offline, network, safety, device benchmarks | |

## 10. Evaluation (built alongside, not at the end)

New harness next to the V1 one: memory extraction cases (history + utterance → expected assertions),
**long-horizon scenarios** (multi-day scripts, then questions that must reflect the *current* state),
retrieval relevance, planning validity, runtime behaviour against fake tools (limits, failure,
replanning), the network routing matrix (capability × mode × connectivity), an offline suite, and a
safety suite (injection from email/web/document/calendar, confirmation scoping, "delete everything").
Release gate stays: **zero false consequential executions**, extended to agent jobs.

## 11. Device budget (measured V1 numbers, the constraint on every design above)

| Fact (iPhone 15 Pro) | Consequence for V2 |
|---|---|
| 77 ms per sampled token; 9–32-token batches ~210–260 ms | Keep generated JSON short; jump-forward everything structural. |
| Prompt evaluation ≈ 135 tokens/s | Dynamic context is expensive: a 600-token context costs ~4.4 s. Budget it, cache the prefix, continue sessions instead of re-reading history. |
| Prefix state loads from disk in 0.16 s | Multiple contracts are free as long as they share one prefix. |
| All models resident: 1.27 GB peak, 6.1 GB available | Room for a 12K context (+128 MB), the database and the knowledge index; still no headroom for a second large model. |
| GPU work is not permitted while suspended | Agent jobs checkpoint and resume; no pretend background autonomy. |

## 12. Risks and how they are handled

| Risk | Handling |
|---|---|
| A 4B model plans badly | Playbooks + grammar-restricted capabilities + Swift-owned control flow; plans are proposals the user approves. |
| Latency creep from personal context | Context budget, continuation API, fast path for V1-style commands (no personal context unless the utterance links to entities). |
| Wrong memories accumulate | Provenance, authority, corrections, selective policy, user-visible and editable memory, undo. |
| Prompt injection from web/email/documents | Untrusted framing, capability scoping per job, confirmation for every consequential act, no credentials in prompts. |
| Connector credentials unavailable (human step) | Adapter + mock behind the same protocol; the connector stays hidden in the UI until configured; the capability registry reports the truth. |
| Battery/thermal from long jobs | Step limits, thermal checks between steps, pause at `.critical`, measured in the device benchmark. |
