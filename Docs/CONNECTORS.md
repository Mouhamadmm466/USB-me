# Connected services

The assistant can reach three things the user owns elsewhere: their Gmail, their Google Drive and
their GitHub. Nothing is connected until they connect it, and a service that is connected is still
only allowed to do the specific things they left switched on.

The design goal was that **the intelligence never learns that Gmail exists**. A connector describes
what it can do in the same vocabulary as the phone's own tools, the capability registry publishes
those descriptions, and the runtime executes them through the same gate as everything else. Adding a
service is writing an adapter; it is not a change to the agent.

## The shape of it

```
Nemotron
   │  asks for a capability by name ("gmail.search")
   ▼
CapabilityRegistry ── built-in capabilities + whatever is connected and switched on
   │
   ▼
ConnectorStepExecutor
   │  grant → network mode → host allowlist → online? → approval → log
   ▼
Connector (adapter)  ── Gmail · Drive · GitHub
   │  one bearer-token HTTP call
   ▼
ConnectorResult ── an observation, labelled as a source
```

`Connectors/` holds the protocol, the permission model, the Keychain token store, the OAuth flow and
the three adapters. It depends on `Core` and nothing else: an adapter cannot reach the store, the
model or the network policy directly, because it is not the adapter's business whether it is allowed
to run.

## What the user decides

Per **capability**, not per service — "read my email" and "send email as me" are different decisions
and the second is not implied by the first:

| | |
|---|---|
| **Off** | Not offered to the model at all. It cannot ask for what it has never been told about, which is stronger than refusing it afterwards. |
| **Ask every time** | Offered, but every use stops and shows exactly what it would do, in the service's own terms, before anything happens. |
| **On** | Offered and runs, inside a job the user approved. |

A service starts at reading on, writing asking, and nothing else. Reconnecting after a token expires
keeps whatever the user chose; a re-authentication is not a reason to re-open something they turned
off. Disconnecting removes the token first, so the worst case is an account with no way to use it —
never a token with no account to show for it.

## What leaves, and what is written down

Every connector request goes through the same `NetworkPolicy` as a web search: the mode, the host
allowlist (only the hosts of *connected* services), connectivity, and the approval. Every attempt is
written to the network log, refusals included, and appears under *Settings → Internet → What left
this iPhone*.

One rule differs, deliberately. The leak check — which refuses to send a name the system knows
unless the user's own request contained it — is **off for the user's own accounts**. That check
exists to stop the user's world being handed to a stranger; searching Wikipedia for a project nobody
outside the phone has heard of tells Wikipedia something. Searching the user's own Gmail for the
same project tells Gmail nothing it does not already hold, and applying it there would make "what did
Sarah send me about Guard?" impossible to answer. `NetworkRequestDescriptor.isPersonalAccount` says
which kind of destination it is.

**Tokens live in the Keychain and nowhere else** — not in the intelligence database (which the user
can export), not in a settings snapshot, not in a log line. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
usable in the background after one unlock, and it does not travel in a backup to another device.

**Nothing is copied into the world model.** A search returns the few results that matched, as text
the model reasons over and the user can be shown. The mailbox stays in the mailbox. If something in
it is worth keeping, it goes through the same memory pipeline as anything else — proposed, attributed
to its source, and confirmable.

## Reading is not writing

A plan that only reads runs when the user approves the plan. A write — sending an email, opening an
issue — is a separate yes every time, showing the exact message first. "Find Sarah's email" and
"reply to it" are not the same decision, and approving the first has never been treated as approving
the second.

## Setting one up

Both Google services need an OAuth client of the user's own: Google will not let an app reach an
account without one, and a client shipped inside the app would belong to whoever built it rather than
to whoever uses it. The user makes a project at `console.cloud.google.com`, adds an iOS OAuth client
for the app's bundle id, and pastes the client ID into the service's screen. It is not a secret — it
is in every authorization URL — so it lives in a plain file next to the account list. There is no
client *secret* anywhere, which is what PKCE is for.

GitHub uses a fine-grained personal access token instead. An OAuth app would need a client secret,
and a secret shipped inside an app is not a secret; for one person, a token they create with exactly
the repositories and scopes they want is both simpler and tighter.

Sign-in happens in Safari, on the service's own page, through `ASWebAuthenticationSession`. The app
never sees a password.
