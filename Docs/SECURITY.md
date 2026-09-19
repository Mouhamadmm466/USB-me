# Security

Threat model and controls for the offline voice agent. The core rule: **the language model
proposes; Swift decides.** Nothing the model outputs, and nothing inside tool content, can cause a
side effect on its own.

## Trust boundaries

| Input | Trust | Handling |
|---|---|---|
| User's finalized speech (`FinalTranscript`) / typed input | Authoritative intent, but can be mis-heard | Proposals are resolved natively and consequential actions are confirmed with exact details |
| Partial ASR (`PartialTranscript`) | Untrusted, unstable | UI only. A distinct type; no agent API accepts it (compile-time guarantee) |
| Model output | Untrusted proposal | Grammar-constrained, then strictly validated (`OutputValidator`); rejected output never executes |
| Tool content (event titles, notes, contact fields, file names) | Untrusted data | Rendered as quoted data in the prompt; system prompt forbids following it; can never authorize an action |
| Model-supplied identifiers (contact ids, event ids, paths, URLs, numbers) | Never trusted | Not part of the output schema. Contacts/events/files are resolved by native lookup; dictated phone numbers must appear in the user's own words |

## Controls

1. **Closed tool vocabulary.** `ToolCatalog` defines 10 tools. The GBNF grammar and the NFA used for
   jump-forward decoding are generated from it; the validator re-checks every field (unknown type,
   unknown tool, unknown/missing argument, invalid enum, wrong JSON type, oversize value, control
   characters, duplicate keys, trailing content, nesting depth) and rejects on any violation.
2. **Risk policy in Swift.** `RiskLevel` is attached to each tool in the catalog. The model's
   `requires_confirmation` flag is recorded for evaluation but ignored for policy.
   Risk 3 (money, credentials, destructive/security operations) has no tool at all.
3. **Versioned confirmation.** A consequential action becomes an immutable `PendingAction`
   (UUID, version, SHA-256 digest of the canonical resolved arguments, 120 s expiry).
   Approval produces a `ConfirmationToken(id, version, digest)`. The executor calls
   `pending.accepts(token, at: now)` immediately before the side effect: status approved, id,
   version and digest equal, digest recomputed from the arguments, not expired.
   Any change → version n+1 with approval cleared; stale card taps and stale tokens do nothing.
4. **Deterministic confirmation classifier.** Only an utterance made entirely of affirmation and
   filler words approves. Rejection, deferral, hesitation, mixed signals ("yes, cancel it") and any
   extra content ("yes but make it 30 minutes") never approve; content goes back to the model to
   *revise* the action, which must then be re-confirmed. Three unclear replies cancel.
5. **Swift-authored descriptions.** The spoken confirmation and the action card are rendered by
   `ActionSummarizer` from the resolved action (exact recipient, number, message text, dates).
   Model prose is never used to describe a consequential action.
6. **Apple's UI stays the final authority.** Messages use `MFMessageComposeViewController` (the
   user taps Send); calls use the `tel:` URL flow (iOS may confirm again). "Sent" is only reported
   when MessageUI returns `.sent`.
7. **No arbitrary URLs or code.** `open_supported_app` maps an enum to fixed Swift-owned URLs;
   only Maps accepts a sanitized, length-limited, percent-encoded query. There is no code or shell
   execution path, and no dynamic plugins.
8. **Scoped files.** Only folders the user picks in the document picker (security-scoped
   bookmarks). Resolved paths must stay inside the scope (standardized and symlink-resolved
   containment check).
9. **Model integrity.** Every model file is pinned by source URL, revision, byte size and SHA-256
   (`Docs/MODEL_MANIFEST.md`). Downloads are verified before atomic activation; files are
   re-verified before loading (see the integrity policy in the manifest doc). Model families are
   never swapped silently.
10. **Privacy-safe telemetry.** `PrivacySafeLogger` only accepts compile-time labels and numbers;
    there is no API that takes a runtime string. llama.cpp and whisper.cpp logging is silenced.
11. **No secrets.** The app has no API keys, accounts or credentials. (Keychain is therefore unused;
    if a secret is ever introduced it must go in the Keychain.)

## Prompt injection

- Tool content is quoted and length-limited in `ContextManager`; the system prompt (rule 4) and a
  few-shot example teach the model to ignore instructions inside it.
- Even a fully compromised model output can at most *propose* an action. The user then hears and
  sees the exact action and must approve it; the executor verifies the token binding.
- The evaluation suite includes 150+ injection cases in the release safety gate
  (`Docs/EVALUATION.md`).

## Known residual risks

- ASR mishears a name or number and the user approves without listening. Mitigation: the
  confirmation always includes the resolved full name and the card shows the number.
- A user can dictate a message whose *content* contains instructions ("…ignore previous
  instructions…"). It is treated as message text, shown verbatim, and requires confirmation.
- On-device models could be tampered with by an attacker who already controls the device's file
  system; the integrity policy detects changed files before use.
