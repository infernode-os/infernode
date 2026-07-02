# Message & integration architecture — the contract

**Status:** convention. This is the contract every messaging/sensor/integration
feature follows so they compose instead of each inventing their own shape. For
where a mount lives (`/mnt` vs `/n`) see [NAMESPACE-LAYOUT.md](NAMESPACE-LAYOUT.md);
this doc is about *how an integration plugs into the agent*.

## Three planes — keep them separate

An integration touches up to three distinct planes. Conflating them is the
mistake this document exists to prevent.

| Plane | Where | What it is |
|-------|-------|------------|
| **Notification** | `msg9p` → `/mnt/msg` | "Something happened that may warrant attention." One unified stream the agent watches. SMS, email, a doorbell, a burglar alarm, a calendar reminder — all emit a `Notification` here. |
| **Depth** | each service's own `/mnt/<x>` | Rich, protocol-specific control. `mail9p` (`/mnt/mail`), `calendar9p` (`/mnt/cal`), a future `whatsapp9p`. Bound as a capability when an agent needs to do heavy work in that domain. |
| **Actuation** | the device's own `/mnt/<x>/ctl` | Side effects on the world: unlock the door, silence the siren. **Not** `msg9p` — you do not "reply" to an alarm. |

The notification plane **converges** (one inbox); the depth and actuation planes
stay **per-service**. `msg9p` is the hub for *attention and conversation*, never
the bus for *device control*.

## The notification plane: `msg9p` + `MsgSrc`

`msg9p` (`appl/veltro/msg9p.b`) aggregates every registered source into one
stream. A **source** implements the `MsgSrc` interface
(`module/msgsrc.m`) — "Email, WhatsApp, Telegram, trading signals, sensors —
all implement this interface. The agent never knows or cares about the
underlying protocol." Sources live in `appl/veltro/sources/` (`sms.b`,
`email.b`, …) and are loaded by `msg9p` at runtime.

### Namespace surface (`/mnt/msg/`)

```
/mnt/msg/
    ctl       (rw)  register <name> <dispath> [k=v...]   add a source
                    unregister <name>
                    send <src> <recipient>\n<body...>    new message via source
                    flag <src> <origid> <word>           set/clear a flag
    notify    (r)   blocking read: one Notification record per event
    status    (r)   human-readable per-source status
    reply     (w)   <src>\n<origid>\n<body...>           queue immutable reply request
    flag      (w)   <src> <origid> <word>                message flag capability
    pending   (r)   request IDs and metadata              trusted controller only
    approve   (w)   approve <id>                          trusted, one shot
    deny      (w)   deny <id>                             trusted, one shot
    sources/  (dir) one entry per registered source
```

The agent's action vocabulary is deliberately tiny and protocol-agnostic:

- **request a reply** → write `<src>\n<origid>\n<body>` to `/mnt/msg/reply`. The
  write reports that approval is required and does not send.
- **send an approved reply** → a trusted controller reviews `/mnt/msg/pending`
  and writes `approve <id>` to `/mnt/msg/approve`. The immutable request is
  consumed before dispatch, so an ID cannot be replayed.
- **send a new message** → write `send <src> <recipient>\n<body>` to `/mnt/msg/ctl`.
- **flag a message** → write `<src> <origid> <word>` to `/mnt/msg/flag`,
  where `<word>` ∈ `seen | unseen | flagged | unflagged | urgent | draft`.
  `seen` marks read (archives-in-place for email); sources that have no flag
  semantics (SMS) treat it as a no-op rather than erroring.

The same three verbs work whether the message is email, SMS, or a future
protocol — that is the whole point of the layer.

### Capabilities — not every source is conversational

A doorbell is not a chat channel. `MsgSrc` is one interface, but a source
**declares what it actually supports** via `capabilities(): int`, a bitmask
(`module/msgsrc.m`):

| Bit | Meaning |
|-----|---------|
| `CAP_WATCH` | pushes notifications (`watch`) — every source has this |
| `CAP_ENUMERATE` | history listing (`enumerate`) |
| `CAP_FETCH` | fetch a full message by id (`fetch`) |
| `CAP_SEND` | originate a new message (`send`) |
| `CAP_REPLY` | threaded reply (`reply`) |
| `CAP_SETFLAG` | read/flag state (`setflag`) |

So an **event-only** source (doorbell, alarm, toaster-done) implements `watch`
and advertises `CAP_WATCH` alone; `msg9p` and agents check the bit instead of
calling a method that returns "not supported". A **conversational** source
(email) advertises the full set. The fat interface stays one type — Limbo
modules must declare every member — but the bitmask makes the honest subset
introspectable, so source #20 need not lie about being a chat channel.

### Notifications are not all LLM-triaged

`msgwatch` (the secretary) classifies ambiguous notifications with the LLM, but
the design must leave room for **deterministic routing first**: a burglar alarm
should escalate by rule, not wait on a model. Treat LLM triage as the handler
for the ambiguous middle, not a mandatory gate on every event.

## The depth plane: per-service `/mnt/<x>`

When an agent needs more than triage — manage folders, search archives, walk a
schedule, read an HTML body — it uses the domain's own filesystem:

- **email depth:** `mail9p` → `/mnt/mail` (IMAP/SMTP as files; see `man/4/mail9p`).
- **calendar depth:** `calendar9p` → `/mnt/cal` (CalDAV as files).

These synthesize their own schema, so by the schema-provenance rule they live
under `/mnt`, and they are bound into an agent's namespace as a capability only
when that agent needs them. A source on the notification plane and a depth
service can both speak to the same backend (e.g. the email `MsgSrc` and `mail9p`
both read `service=imap` creds from factotum) — they are different altitudes,
not duplicates. On a resource-constrained node you may run only one; longer term
a depth service can expose its own notify channel and a thin `MsgSrc` can bridge
to it so a single connection feeds both.

## Setup: secrets in keyring, config in Settings

Provisioning an integration is **never** hand-editing `factotum` from a shell.
Two existing UIs, each a thin shell over file I/O:

| Need | UI | Mechanism |
|------|----|-----------|
| **Secrets** (app password, API token) | **keyring** (`/dis/wm/keyring`) | writes a `key proto=pass …` to `/mnt/factotum/ctl`, persisted to secstore. keyring never stores the secret itself. The "Email Account" type already emits `service=imap` + `service=smtp` keys — and that one entry feeds both the email source and `mail9p`. |
| **Config + enable/disable** | **Settings** (`/dis/wm/settings`) | reads/writes the service's `ctl`/`status`. For message sources that is `/mnt/msg/ctl` (`register`/`unregister`); for a depth service it is that service's own ctl. See [SETTINGS-CONVENTIONS.md](SETTINGS-CONVENTIONS.md). |

So a new integration author adds, at most: a `MsgSrc` source (or depth service),
a keyring key-type if it needs a secret, and a Settings toggle over its `ctl`.
Nothing bespoke, and the same `ctl` writes work headlessly from a shell.

## Checklist for a new integration

1. **Notification:** implement `MsgSrc` in `appl/veltro/sources/<x>.b`; return an
   honest `capabilities()` bitmask. Event-only? `CAP_WATCH` and stop.
2. **Depth (optional):** if it needs rich control, add a `/mnt/<x>` service that
   synthesizes its own schema (mount under `/mnt` per NAMESPACE-LAYOUT.md).
3. **Actuation (optional):** side effects go through the device's own `ctl`,
   never through `msg9p`.
4. **Secrets:** if it needs credentials, add a keyring key-type (or reuse one).
5. **Config:** add a Settings control over the relevant `ctl`/`status`.
6. **Register:** wire it into boot (`lib/lucifer/boot.sh`) next to the SMS line,
   soft-failing when prerequisites are absent.
