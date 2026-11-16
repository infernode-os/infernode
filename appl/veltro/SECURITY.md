# Veltro Security Model (v3)

## Overview

Veltro uses Inferno OS namespace isolation to create secure environments for AI agents. The core primitive is `restrictdir(target, allowed, writable)`: create a shadow directory containing only allowed items, then bind-replace the target. Anything not in the allowlist becomes invisible. A non-writable view uses `MREADONLY`; a writable view uses `MCREATE`, needed for `/tmp` so agents can create files there. Internal service filtering is separate because hiding names in a writable 9P protocol is not the same property as making its visible files immutable.

### Terminology

This document distinguishes:

- **Harness** — the namespace-restriction machinery itself: `nsconstruct`,
  `tools9p`, and the `veltrosrv`/`spawn` entry points. The harness defines
  what an agent *can* do and is trusted code.
- **Coordinator** — the process that owns the model loop and chooses which
  tool request to send. There is one: `veltrosrv`, which restricts its own
  namespace before it serves. `veltro`, `lucibridge` and Xenith's `Agent`
  are its clients, outside the agent's namespace; model-requested effects
  cross into a fresh, confined `tools9p` worker for every call. Model text
  is data and never executes in the coordinator.
- **Agent** — a logical model session plus its capability set. Do not assume
  one agent means one confined process: the enforcement point is either its
  restricted coordinator (`veltrosrv`), its per-call `tools9p` worker, or
  its spawned child.
- **Subagent** — an agent created by another agent via the `spawn` tool.
  Subagents inherit an already-restricted namespace and can only narrow it
  further (capability attenuation).

The security model applies to **agents**: the harness restricts what each
running instance sees. The harness itself is trusted code.

### Untrusted Content And Prompt Injection

Email, SMS, webpages, MCP results, and retrieved documents are hostile input.
The security model assumes a model that interprets such content may follow an
attacker's instructions. Prompt text is not an authorization boundary.

Apply these invariants:

- **Quarantine ingestion.** Process raw external content in a separate agent
  namespace with no credentials, raw network, send/payment endpoints, arbitrary
  execution, broad filesystem paths, or capability-provisioning control.
- **Never combine sensitive reads with egress.** A worker may receive exact,
  read-only file snapshots needed to draft a result, or a constrained egress
  capability, but not both. Otherwise prompt injection becomes exfiltration.
- **Grant paths, not ambient services.** Prefer exact files and exact 9P service
  subtrees over directories, `/net`, `/mnt/factotum`, or whole service roots.
- **Separate drafting from effects.** Message sending, file mutation, payment,
  and further delegation require a fresh capability issued by trusted code
  outside the model's namespace. User approval should produce a narrow,
  operation-bound, preferably one-shot capability; the model cannot mint it.
- **Declassify typed results only.** Raw hostile content does not flow into an
  authority-bearing coordinator's context. Cross-boundary output is bounded and
  parsed into an expected result type before trusted code uses it.

Effectful workflows use a proposal/commit split. Agent-visible endpoints create
inert proposal objects or immutable pending requests; trusted controller
endpoints perform the commit by copying approved data across the authority
boundary. Treat this as the general copy-on-write pattern for message replies,
file edits, payments, and other external effects: proposal files are not effect
capabilities.

Message replies use two separate authorities. An agent with an exact
`/mnt/msg/draft` grant can only queue immutable reply proposals. The trusted
controller alone can inspect `/mnt/msg/pending` and consume a request once
through `/mnt/msg/approve` (or discard it through `/mnt/msg/deny`). An approval
is of what `pending` showed: the reply's exact body, and whose message it
answers with its subject, which msg9p asks of the source when the draft is
queued. Before sending it asks again and sends nothing if the id no longer
names that message; the mail source names a message by UIDVALIDITY and UID,
not by a sequence number that an expunge would move to another sender. Never bind
those controller endpoints into an agent namespace. Message notification text is
also part of the boundary: source-controlled fields must remain single physical
lines so hostile mail/SMS content cannot forge `Triage:` or `Message ID:`
control records.

Wallet payments follow the same split. A `/mnt/wallet` grant is narrowed inside
the agent namespace (only the exact grant: a path beneath `/mnt/wallet` grants
nothing): agents can read account metadata and write per-account
`pay` proposals and structured `authorize` (x402/EIP-3009) requests, but cannot
see root `ctl`, `pending`, `new`, or per-account `ctl`. There is no raw `sign`
file at all: a hash-blind signing oracle over the spend key — signing an
attacker-chosen 32-byte hash can authorize an arbitrary transfer — cannot be
protected by namespace narrowing alone, so it was removed rather than hidden
(`NsConstruct->walletcontrolpath`, shared with `tools9p`, still refuses it as a
grant). wallet9p constructs everything it signs
(transactions from `pay`, EIP-712 digests from `authorize`) and enforces budget
and approval policy on every execution path. Payment approval and wallet
configuration remain trusted-controller actions outside the model namespace;
approval cannot be disabled for an agent-visible account. What is approved is
what the approver was shown: wallet9p takes an amount in one form only (no
leading zero) and keeps the network as it writes it itself, and the wallet GUI
shows the whole payee, the amount and the network of each proposal, never a
shortened line. One account's proposals are bounded apart from the queue's
total, and an account cannot take the name of one of the wallet's root files,
since the agent's view is an allowlist built from the account names.

The tools that fetch from the web (`webfetch`, `http`, `browse`, `payfetch`,
`websearch`) reach public addresses only: `publicnet` refuses loopback, private
and reserved destinations before the request and again at the dial of every
redirect. Each request is given thirty seconds, redirects and body included,
and reads no more than a fixed amount of the response (512KB; `websearch` 1MB,
`browse` 2MB): the request keeps the time itself (`webclient->requestbounded`),
so at the deadline its connection is hung up and nothing of it is left running,
and a response's header cannot make a tool hold memory for a body that has not
come. What a tool returns of a page is the page's words, hostile input like any
other: a result says where it came from or is otherwise marked, so that fetched
text beginning `error:` is not taken for the tool failing, and says when it was
cut. `payfetch` answers a 402 with a payment authorization only when the 402
came over https. The `charon` tool drives the user's own browser, which reads
`file:` addresses as the user; a page from the network cannot take that browser
to one (a link followed, a form's action, a refresh, a script, a frame, a
`<base>`: `Page->mayload`), so the tool reads nothing of the browser's name
space through a page.

Three effects have no proposal endpoint behind them, so the user's approval
is the whole control: `task promote` (a task's staged changes applied to the
user's folders), `sms` (a text message sent) and `dial` (a call placed). The
coordinator asks before it sends such a call to the tool server
(`veltrosrv`'s gate, the session's `approve` file), and these rules hold it:

- **One reading of a call.** The model's call is read once, where it is
  taken: its tool name is made a plain name the tool server offers, or the
  call is refused; its arguments are put in the form the tool takes. For
  `task`, `sms` and `dial` the tool itself says what the call will do
  (`effect()` in the tool module, which `veltrosrv` loads before it
  restricts itself, and which the tool's `exec` acts on too). What the gate
  judges, what the user is shown and what is sent to the tool are that one
  string, so case, spacing, quoting and JSON shape cannot make the gate see
  a different call from the one that runs. A call that cannot be read is
  refused, not run ungated.
- **The request is what will run.** The user is shown the whole call on one
  line, control characters and invisible reordering characters written out;
  for the three effect tools, the tool's own fixed words with the task's
  number or the phone number and message. A command too long to show whole
  is not asked about and not run. Only the content of a write may be cut,
  and the request says how much is not shown. Nothing the model writes is
  presented as the harness's words.
- **`dial` takes a plain phone number** (digits, `+` first): MMI and USSD
  codes, pauses and anything after a line break are refused by the tool.
- **A stop is a stop.** A cancelled turn asks nothing more, and a client
  that holds its session (`ctl` `hold`) and dies has its turn stopped and
  its session closed, so no agent goes on alone with the gate answered in
  advance.

The gate for `exec`, `write` and `edit` (bind, mount, a recursive remove
outside `/tmp`, a write under `/dis`, `/lib` or `/dev`) is a second line
behind the tool worker's namespace, not the boundary. The gate is the
coordinator's: tools a spawned child holds are called in the child, with no
gate, so `sms` and `dial` do not belong in a delegation budget.

Text the harness shows or forwards is framed by the harness alone. Model
text cannot begin a line of a session's `text` with a message header, nor
add a line to its `log`; a tool's result or a child's report cannot end its
entry in the results sent back to the model, or begin one as the user.

When a workflow appears to require user files and the web simultaneously, split
it into stages with a trusted mediator. There is no safe prompt that compensates
for granting a compromised model both confidential data and unrestricted egress.

Headless service launchers may receive API keys through their host environment
when interactive factotum/secstore unlock is unavailable. Trusted bootstrap code
should provision those values into factotum when possible. Agent namespaces
allowlist only `VELTRO_SESSION` under `/env`, so host credential variables never
become agent capabilities. Runtime agent tools consume credentials through
factotum only; plaintext key files under `/lib/veltro` are prohibited. Raw
`/mnt/factotum` path grants are also prohibited: fixed-function credential
tools may receive factotum from trusted namespace construction, but generic
path grants must not hand the credential service to arbitrary tools.

Three model-execution boundaries apply namespace restriction:

| Entry Point | Where | When |
|-------------|-------|------|
| `tools9p` invocation | `appl/veltro/tools9p.b` | Per tool call, after `FORKNS`, attenuated to the invoked tool |
| `veltrosrv` serve | `appl/veltro/veltrosrv.b` | In the serving process, after tool discovery, before it serves |
| `spawn` child | `appl/veltro/tools/spawn.b` | In runchild(), before subagent->runloop() |

All three call `nsconstruct->restrictns(caps)` after `pctl(FORKNS)`. `lucibridge`
and the other clients do not run model-supplied code; they rely on the `tools9p` row for
every model-requested tool effect.

## How It Works

### Core Primitive: `restrictdir(target, allowed, writable)`

```
1. Create unique trusted shadow dir: /tmp/.veltro-ns/shadow/{pid}-{seq}/
2. For each item in allowed:
   - Create mount point in shadow (dir or file matching source type)
   - bind(target/item, shadow/item, MREPL | (writable ? 0 : MREADONLY))
3. flags = MREPL | (writable ? MCREATE : MREADONLY)
   bind(shadow, target, flags)  -- replace entire target
4. Result: target shows only allowed items; everything else is gone
```

`writable=1` adds `MCREATE` to the final and inner binds so file creation is
permitted. Otherwise `MREADONLY` rejects write opens, truncation, create,
remove, remove-on-close, and metadata changes. Read-only attenuation survives
rebinding and exporting the view through Inferno's 9P export service. A deeper
explicit writable mount can still grant mutation within that subtree. Existing
open descriptors are not revoked by a later read-only bind, so Veltro also
constructs an explicit descriptor group. Writable protocol services use an
internal allowlist-only filter instead of `restrictdir`; visibility and
mutability are deliberately separate.

Special handling for `target == "/"`:
- Skips `stat()` on each item to avoid deadlock on 9P self-mounts (e.g., `/tool`)
- Creates directory mount points unconditionally
- Bind failures are non-fatal (item may not exist in current namespace)

### Layered Restriction

```
tools9p call:   FORKNS + restrictns()   -- one invoked tool only
veltrosrv:      FORKNS + restrictns()   -- restrict coordinator namespace
subagent spawn: FORKNS + restrictns()   -- inherit + further restrict
```

All layers use the same `restrictdir()` primitive. Capability attenuation is
natural: children fork an already-restricted namespace and can only narrow
further.

A task's memory and plan stores (`/tmp/veltro/memory/<id>`,
`/tmp/veltro/plans/a<id>`) are removed by tools9p when it provisions the task
and when the task is closed, as its scratch is emptied: activity numbers are
used again, and the `task` tool's own call cannot name those directories.

Task briefs, instructions, model choices, and agent-role selections are exchanged
under `/tmp/veltro/tasks`. `restrictns()` replaces that directory with an empty
view for every invocation except the fixed-function `task` tool. The trusted
taskboard and lucibridge processes consume the files outside the tool namespace;
message-reading and general file tools cannot inspect another activity's prompt.

`/tmp/veltro/scratch` is rebound to `/tmp/veltro/scratch/<activity-id>` in each
restricted namespace. Generic write/edit operations accept only this scratch
path (or an explicit `rw` capability), preventing files at the shared workspace
root from bypassing activity isolation.

The shared `/tmp/veltro` root is also allowlisted. A generic invocation sees
only `scratch`; core state such as task metadata, memory, plan/todo fallback
files, and GUI IPC trees are present only when the relevant tool names them.
The memory and plan tools keep one store an activity
(`/tmp/veltro/memory/<id>`, `/tmp/veltro/plans/a<id>`), and a call of either
sees its own activity's alone, as scratch. Those directories and the todo
file are the tools' state, never a path grant. Any other path granted under
`/tmp/veltro` shows exactly what was granted (not its first component whole)
and is bound read-only unless it is a write path. Trusted app control files
under `/tmp/veltro/*/ctl` must never be ambient.

Memory and plans are kept per activity. The `memory` tool stores under
`/tmp/veltro/memory/<activity-id>` and the `plan` tool (when no session
directory is set) under `/tmp/veltro/plans/a<activity-id>`, the id being the one
its tool server serves as `/tool/activity`. One activity's tool therefore does
not list, load or clear what another kept: a task that has read hostile text
cannot leave it where the main agent will load it as its own memory. Activity
0's store persists across sessions; a task's is emptied when a new tool server
first uses it, because task ids begin again at each boot. This is the tools'
own scoping. The name space still binds the whole of `memory` and `plans` for a
holder of the tool, so a caller that also holds a raw file tool over
`/tmp/veltro` can reach the other directories; delegated children of one
activity share its store.

Provisioned children receive only read-only navigation tools by default:
`read`, `list`, `find`, `search`, and `grep`. Persistence (`memory`), recursive
delegation (`spawn`), planning state, and UI effects require explicit budgeted
tool grants.

## Namespace Restriction Policy

`restrictns(caps)` applies these restrictions in order. Conditional entries are
absent, not present-and-denied:

| Step | Target | Allowed | Purpose |
|------|--------|---------|---------|
| 1 | `/dis` | `lib/`, `veltro/`; `sh.dis` for exec; named commands from `shellcmds`; explicitly granted `/dis/<tree>` | Runtime and named executable allowlist |
| 2 | `/dis/veltro/tools` | Granted tool modules only | Tool allowlist |
| 3 | `/dev` | `cons`, `null`, `time` | Console/null and TLS clock |
| 4 | `/n` | Capability-derived foreign imports: presentation and exact `/n/local` grants | Foreign-tree capabilities |
| 5 | `/mnt` | Exact application subtrees plus fixed-function tool mounts such as Git; sensitive services (`msg`, `wallet`, `ui`) are narrowed again: the wallet to its accounts' proposal and read files, the UI (for every tool but `task`) to the tool's own activity without its conversation, with `activity/current` reading as that activity | Synthesized-service capabilities |
| 6 | `/lib` | `veltro/`, `certs/`; `/lib/veltro/keys` replaced with an empty view | Prompts/config and TLS roots, not credentials |
| 7 | `/env` | `VELTRO_SESSION` only | No inherited environment secrets |
| 8 | `/prog` | Current pid for non-exec tools; empty for exec, including exec with `shellcmds`; whole for the spawn tool's own call, which ends its subagents by their `ctl` files | No parent/sibling inspection or control |
| 9 | `/` | Base system dirs plus only capability-derived `/mnt`, network, UI, phone, and explicit root trees | Replace the host-backed root union |
| 10 | `/tool` and extra roots | Tool metadata/current tool plus recursively narrowed explicit path grants; for a spawned child, files of its own saying what it holds, with no tool to call | Remove generic control files and sibling paths; keep a child off its parent's tool server |
| 11 | activity views | Per-activity cowfs writes, scratch, task metadata, and tool-specific `/tmp/veltro` entries | Isolate mutable state |
| 12 | `/tmp` | `veltro/` only, writable | Hide `/tmp/.veltro-ns` after construction |

**Order matters**: all bind replacements and COW mounts are created from trusted
backing under `/tmp/.veltro-ns/`; `/tmp` is restricted last. Existing mount
channels remain valid, but agents can see only `/tmp/veltro` and cannot modify
the shadow directories or namespace audit snapshots.

**`/chan` access control**: The Xenith 9P filesystem at `/chan` exposes ALL window contents. Without the `xenith` capability flag, `/chan` is excluded from the root allowlist — the agent cannot see or read any Xenith windows. When `caps.xenith` is set (e.g., tools9p detects the xenith tool was granted), `/chan` is included. The REPL opens its own window FDs before restriction, so it works without `/chan` in the namespace.

## Namespace After Restriction

### Representative Restricted View

```
/
+-- chan/          Xenith 9P (ONLY if xenith tool granted)
+-- dev/
|   +-- cons      console I/O
|   +-- null      null device
|   +-- time      read-only clock
+-- dis/
|   +-- lib/      Limbo runtime libraries
|   +-- veltro/   agent modules + tools
+-- env/          environment variables
+-- lib/
|   +-- veltro/   agents/, reminders/, tools/, system.txt
|   +-- certs/    TLS trust roots
+-- n/
|   +-- ...       only granted foreign imports
+-- mnt/          only when an application subtree is granted
|   +-- llm/      coordinator only; spawned children use a pre-opened FD
+-- net/          TCP/IP networking (fixed-function network invocation only)
+-- prog/         self only; empty for exec
+-- tmp/
|   +-- veltro/
|       +-- scratch/     agent workspace
|       +-- .ns/         coordinator manifest metadata, when retained
+-- tool/         tools9p mount (9P filesystem)

NOT VISIBLE after restriction:
/.env, /.git, /CLAUDE.md        project secrets/config
/appl, /emu, /module, /mkfiles  source tree
/n/local                        host filesystem, unless exactly granted
/chan                            Xenith windows (unless xenith tool granted)
/fonts, /icons, /man            non-essential data
/dis/*.dis                      top-level commands
```

The tree is capability-dependent. `/mnt`, `/net`, `/chan`, `/phone`, extra
root directories, and most `/tmp/veltro` entries do not exist unless the
current operation needs them. Bind shadows and namespace audit backing live at
`/tmp/.veltro-ns`, which is hidden by the final `/tmp` replacement.

### Child Subagent (spawn)

The child starts a fresh process group and environment, forks the already
restricted parent namespace, narrows tools and paths again, prunes descriptors,
then applies `NODEVS`. It cannot recover authority absent from the parent.

The name space it forks is the spawn tool's own call's, which holds more than
the agent was granted: the tools of the delegation budget, the model service,
the audit sink. `restrictchildns()` therefore differs from `restrictns()` in
three ways. The child's `/tool` is not its parent's tool server (which runs
every call with the parent's grants and keeps each tool's last result) but a
read-only directory of the child's own: `tools`, `paths` (its grants, each
`ro`), `activity`, `meta/audit`. It may not be granted `/mnt/llm` or anything
beneath it. And the install's audit switch, which cannot be seen from there,
is the caller's word. The spawn tool, for its part, grants a child a path only
inside a grant the agent itself holds (a line of `/tool/paths`), and refuses
the agent's own services (`/mnt/llm`, `/mnt/audit`, `/mnt/ui`, `/mnt/veltro`,
the tool server) whatever the grants say.

A child calls its tools as loaded modules, so the coordinator, which asks the
user before its own agent's call of `sms`, `dial` or `task promote` runs,
never sees a child's call. A child is therefore given none of `sms`, `dial`
and `task`, whatever the delegation budget holds: spawn refuses the request
and `restrictchildns()` refuses the capabilities.

A child has one name space for all its tools. One that can run commands
(`exec`, `shell`, `shellcmds`) is not given the UI's files even when it also
holds a UI tool; the tool then reports that the UI is not there.

## Entry Point Details

### tools9p Per-Invocation Restriction

The tools9p server remains in its service namespace. Each tool call forks a
namespace, binds the activity's `/tool.N` over `/tool`, and restricts with only
the invoked tool in `caps.tools`. The agent's complete tool menu is therefore
not ambient authority inside each operation. A `read` or `exec` call does not
inherit `/net`, factotum, `/chan`, UI, or sibling tool modules merely because a
network/UI tool is also registered.

For ordinary tools the ordering remains security-critical:

```
asyncexec(tool):
  0. pctl(NEWFD) keeping the console; /dev/null as descriptor 0
  1. pctl(FORKNS)
  2. pctl(NEWENV), then copy only VELTRO_SESSION
  3. pctl(NODEVS)
  4. bind /tool.N over /tool
  5. restricttoolns(Capabilities(tools = [tool], ...))
  6. (spawn only) pctl(NEWPGRP)
  7. execute only that tool module
```

Every call is made this way, a `task create` included. A call's descriptors
are its own: no call has a file another call, or the server, has open, and a
command `exec` starts has `/dev/null` as its input. A call's answer is sent by
the serve loop, and not at all once the caller has flushed it.

The fresh environment group is required even though `restrictns()` narrows
`/env`: Inferno deliberately permits a process to name its private `#e`
device after `NODEVS`. Without `NEWENV`, that alias would recover the
launcher's unfiltered environment behind the restricted `/env` view.

`restricttoolns()` hides trusted `/tmp/veltro/.ns` metadata before the final
`/tmp` replacement. No model-facing operation may call `restrictdir()` after
that replacement: doing so would recreate `/tmp/.veltro-ns` inside the
worker's writable, restricted `/tmp` view and expose its shadow backing.

`exec` defers `NODEVS` to its trusted wrapper. The wrapper opens the current
worker's `#p/<pid>/wait`, retains only that FD and its I/O across `NEWFD`, then
applies `NODEVS` before parsing or running model-supplied command text. Its
`/prog` directory is empty even when named `shellcmds` are granted.

After restriction, all async tool execution threads (via `spawn asyncexec()`) inherit the restricted namespace.

### veltrosrv Restriction

The coordinator applies `NODEVS` and restriction after discovering
their tool/path grants but before creating the LLM session:

```
1. Load NsConstruct module (while /dis unrestricted)
2. Read /tool/tools -- get live tool list before restriction
3. pctl(FORKNS)
4. pctl(NODEVS)
5. restrictns(caps)   -- includes internal /mnt/llm grant
6. Create LLM session
7. Enter model loop
```

`lucibridge` is different: it remains a trusted UI coordinator and does not
call `restrictns()`. Its model-requested tool calls cross the per-invocation
`tools9p` boundary above. Changes that execute model text or tool modules inside
`lucibridge` would violate this contract.

What `lucibridge` shows is the agent's; the user's controls stay the bridge's
own. A dialogue tile with buttons is made only by the bridge (an approval, an
offer of changes kept from an earlier session). A titled note in the session's
text becomes a tile only under a title the harness itself gives (`Agent stuck`,
`Model unavailable`); under any other it is shown as the agent's text, so a
line of the model's that reads as a note's header cannot make a "Permission
required" tile. An activity's status names a tool only when the name is one of
the activity's tools and not a word a status has of its own (`hidden` marks an
activity closed). `/stop` stops the turn, a dialogue waiting or not; anything
else typed while one waits is its answer, and only `Allow` allows.

### spawn Child Restriction

The child process applies the full isolation sequence:

```
0. (parent) open the child's model session and its ask and tools files
1. pctl(NEWPGRP)         -- Its own process group; the parent opens its ctl
                            file, and only then lets it go on
2. pctl(FORKNS)          -- Fork parent's restricted namespace
3. pctl(NEWENV)          -- Empty environment (NOT FORKENV!)
5. restrictchildns(caps) -- Further bind-replace restrictions; no tool
                            server, no model service
6. verifysafefds()       -- Redirect FDs 0-2 to /dev/null if nil
7. pctl(NEWFD, keepfds)  -- Prune all other FDs (llm ask, log, pipe, provenance store)
8. pctl(NODEVS)          -- Block #U/#p/#c device naming
9. setprov(childid, fd)  -- Arm audit provenance (INFR-355): child seals its
                            trajectory via the bound write-only /mnt/audit/log;
                            payloads go to the content store over the pre-dialed fd
10. subagent->runloop()  -- Execute task with pre-loaded tool modules
```

A child's life is its parent's to end, and the parent ends it: when it has
answered, at its timeout, or, for one scheduled with `at=` or `every=`, when
the tool server that started it has gone (a keeper process of the call asks
every few seconds). Ending it kills its process group and every group made
below it (`killtree`) and closes its model session. At most eight are
scheduled at once, and the call's result names each one's process group.
tools9p keeps the directories a spawn call's name space is built on until the
last process of the call's group has gone, so a scheduled child's name space
lasts as long as it does.

When the install audits (`/mnt/audit/log` present), tools9p binds that
append-only file into the spawn tool's call and spawn grants it to every
child; `auditcontrolpath` keeps `/mnt/audit` itself, `chain`, and `ctl`
ungrantable, so a child can append to its own trail but can never read or
rewrite history (AU-9 by placement). Whether auditing is required
(`Audit->ONFILE`) is tools9p's word, at `/tool/meta/audit`: a tool call's name
space has no `/usr` to look in. Where it is required, a spawn whose records
cannot be written (no sink, no content store) starts nothing, and a child
whose own restriction or trajectory cannot be recorded is refused or stopped.

What it appends cannot harm the trail either: `auditfs` puts every record in
one canonical text before hashing it (controls and line breaks are blanks,
one write is one bounded record), so neither a writer nor text sealed on a
model's behalf (a tool's name) can break the chain for the records after it,
split a record in two, or pass for the server's `checkpoint`. Provenance
records keep their `content=`, `sha256=` and `size=` for the emitter: a name
holding those keys is sealed as text (`auditprov(2)`).

## Subagent Architecture

Subagents do NOT use tools9p. They use pre-loaded tool modules directly.

```
Parent (spawn.b):
  1. preloadmodules(tools)    -- load Tool modules while /dis accessible
  2. preload subagent.b       -- load SubAgent module
  3. spawn runchild()         -- child inherits loaded modules in memory

Child (runchild):
  1. Apply namespace restrictions (steps 1-8 above)
  2. Build tool list from preloadedtools (already in memory)
  3. subagent->runloop(task, toolmods, toolnames, prompt, llmfd, logfd, 50)
```

The subagent's system prompt comes from `/lib/veltro/agents/{type}.txt`, loaded before namespace restriction. Tool invocations in the runloop call `mod->exec(args)` directly on the pre-loaded module references.

## Security Properties

| Property | Mechanism |
|----------|-----------|
| No ambient host filesystem | `/n/local` is absent unless exactly granted; `#U` attachment is blocked by `NODEVS` at every execution boundary |
| No project file exposure | Root restriction hides `.env`, `.git`, `CLAUDE.md`, source tree |
| No env secrets | Every tool worker and spawned child uses `NEWENV`; workers copy only `VELTRO_SESSION`, then `/env` is allowlisted |
| No ambient child FDs | Each tool call has a descriptor table of its own (`NEWFD`, `/dev/null` as input); spawn uses `NEWFD`; exec runs its command from a descriptor group of the call's own: 0 is `/dev/null`, 1 and 2 the call's pipe, and the private wait FD the only other. Nothing of the group all tool calls share is kept |
| Bounded subagent life | A child is ended, with all it started, by its parent: at its answer, its timeout, or the tool server's end |
| Safe FD 0-2 | `verifysafefds()` redirects nil FDs to `/dev/null` |
| Empty srv registry | NEWPGRP first (child) |
| Truthful namespace | bind-replace shows only allowed items; `MREADONLY` enforces paths reported read-only, and `/tool/paths` lists a service under `/mnt`, which is not bound read-only, as `rw` |
| Capability attenuation | Child forks restricted parent, can only narrow |
| Bounded process visibility | `/prog` is self-only for non-exec tools and empty for exec, with or without `shellcmds` |
| Shadow cleanup | tools9p reclaims per-call physical shadows (a spawn call's when the last process of its group has gone) and sweeps crash leftovers at startup |
| Auditable construction | `restrictns()` pre-opens only the write-only audit append FD, `emitauditlog()` seals the completed restriction through it, then closes it before tool execution; the audit tree never enters the tool namespace |
| No cross-window access | `/chan` hidden unless `caps.xenith` is set; REPL opens FDs before restriction |
| exec grants sh.dis only | `sh.dis` bound when `exec` is in caps.tools; named commands require `shellcmds` |
| Shell access controlled | `sh.dis` + named command `.dis` files only bound if `shellcmds` is non-nil |
| Writable views explicit | `MREADONLY` protects code/source views; `MCREATE` appears only on `/tmp`, proposal endpoints, activity scratch, and cowfs staging |
| Staged writes applied only where granted | cowfs keeps its records out of its mount; a promote takes the folder from the harness's note of the grant, never from the overlay (see Staged Writes and Promotion) |
| Host path control | `/n/local` hidden unless `caps.paths` grants specific subpaths (`-p` flag) |
| Speech preserved | `/mnt/speech` granted as a path to `say` and `hear`, exposed only if mounted |
| 9P self-mount safe | Root restriction skips `stat()` to avoid deadlock on `/tool` |
| Compiler reads source only | The `limbo` tool runs the compiler in a process of its own, with an empty directory over `/mnt`, `/dev`, `/prog`, `/net`, `/env`, `/chan`, `/tool` and `/srv` and a pipe of its own: an `include` line names source, not a service's file. Where it saves (`-o`) is held to the rule `write` and `edit` follow |

The baseline paths above are retained capabilities, not declarations that an
entire subtree is harmless. `/dev/cons` is an input/output channel, `/prog`
reveals the current tool process, and `/lib/veltro` contains agent-visible
prompts and configuration. Installation secrets must never be placed in that
tree; credentials belong in factotum. The deterministic security suite pins the
exact `/dev`, `/dis`, `/prog`, and `/lib` top-level views, the granted tool
module set, protected-key exclusion, and read-only attenuation. Escape-room
campaign results supplement those checks but do not prove these paths safe.

### The git tool

`git` is the one tool whose effects are not bounded by the call's name space:
its worker is started when `tools9p` starts, before any restriction, and keeps
that name space (with `NODEVS`). Its boundary is the repository `tools9p` was
started in, and it is kept by checking names, not by the name space:

- a path the model gives is relative to the start directory, with no `..` and
  no `.git` component;
- a ref's name (the model's, one a remote advertises, what `HEAD` or a
  symbolic ref says) is a name as git's `check-ref-format` has it, under
  `refs/`, where it is read and where it is written (`writeref`,
  `updaterefs`): a remote that advertises `refs/heads/../../x` is not fetched
  from;
- a tree entry's name is one component, not `.`, `..`, or anything a host
  file system reads as `.git`: `parsetree` refuses the tree, so checkout,
  merge, the index and `/mnt/git` never join such a name to a directory.

Because of that, `git` is **not in the default delegation budget**
(`lib/lucifer/boot.sh`): a task agent cannot be given it unless the operator
adds it (`budget-add git`). What it adds, removes, checks out or merges is
written to the user's files directly, by no grant and through no copy-on-write
overlay, so nothing of it waits for a promote. It goes back in the budget when
its writes go through the call's grants and overlays and its push is a proposal
the user approves. `tests/host/default_budget_test.sh` refuses a budget naming
a tool whose manifest says its effects are outside the call's grants.

`push` and `fetch` dial the remote named in `.git/config` from the worker,
whatever `caps.network` says, and `push` sends the factotum key kept for that
host. The tool's manifest says `dials_net`, so nsaudit's egress rules count an
agent that holds `git`. A remote's URL is given back without any user and
password in it, and its progress text is not printed on the console.

## Staged Writes and Promotion

A folder granted `rw` is not written by the agent. Each tool call mounts a
cowfs overlay over it (`overlaywritepaths`), so every create, write and remove
lands in `/tmp/veltro/cow/<activity>-<key of the folder>`, and reaches the
folder only when the user applies it: `/promote` in the activity's tab, the
approval of `task promote <id>`, or `Apply` on changes kept from an earlier
session. Three rules keep that step the user's.

**The overlay's records are not in the tree it serves.** The overlay directory
holds, beside the staged files, `.cowmeta` (the folder it stages for, and the
session's mark), `.cowbase` (what each base file was when the task first
changed it: the conflict check) and `.whiteout` (the staged deletions). They
are in the directory the task's writes land in, so cowfs refuses every walk to
one and every create under one of their names at the overlay's root, by name as
a folding host file system would read it (case, trailing dots and blanks, a
`:stream` suffix) and by identity (any other name the host resolves to the same
file); 9P `wstat` is refused, so nothing is renamed onto one. A task that could
write them removed `.cowbase` (a promote then wrote over the user's newer
edit), listed deletions of its choosing in `.whiteout`, and named another
folder in `.cowmeta`.

**A promote takes the folder from the harness, not from the overlay.**
`lucibridge` notes every folder an activity is granted for writing, as
`tools9p` lists them in `/tool/paths`, under `/tmp/veltro/cow/.grants/`. That
directory is in no agent's name space and, like the rest of `/tmp/veltro/cow`,
cannot be granted. An overlay's name gives its activity and its folder's key;
its changes are applied only to a folder noted for that name, and only when the
overlay's own `.cowmeta` names the same one. Anything else is refused, saying
which folder was claimed and which was granted, and stays staged for `/revert`
or `Discard`. So an overlay for a folder the activity was never granted for
writing is never applied: exec's staging of `/lib/veltro`, `/lib/certs` and
`/dis/veltro` is of that kind. Changes kept from an earlier session follow the
same rule; without a note they are offered for discarding only.

**The user is shown what would change.** The dialogue that asks the user to
allow `task promote <id>` lists the staged changes (count, and up to twelve of
them with their folder), read by activity 0's `lucibridge` from the task's
overlays. The text the agent gave for the call names no file.

Promotion is conservative in what it changes. A staged deletion removes one
name: a file only if it is as it was when the task removed it, a directory only
if it is empty (a task removes a directory after what was in it, each a line of
`/diff`). A file whose base changed after the task first touched it is not
overwritten; it is reported and stays staged.

Xenith's Agent window (`appl/xenith/xenith/agent/Agent.b`) applies its own
overlays and still reads the folder from `.cowmeta`. It relies on the first
rule alone.

## Type Safety Between Modules

The name space decides which files an agent's programs can reach. What a
program can do to the emulator it runs in is decided by Limbo's type safety,
which at run time rests on the compiler, on the loader refusing to link a
module to a function of another type, and on nobody loading a module the
compiler did not make.

The loader's check compares, for each function a module imports, the type the
importer was compiled against with the type the implementing module (or the
builtin module's table) was compiled with. Each module file carries two forms
of that type: a 32-bit hash, and a SHA-256 digest of the same signature text
(`HASSIGS`, dis(6)). The 32-bit hash alone is not a check: two different
function types with the same hash are found in about a second, and a module
that declares one and loads a module implementing the other was linked, after
which a reference could be read as an integer and an integer used as a
reference. When both modules have digests the loader compares the digests,
and such a pair is refused with a `link typecheck` error, as it is against
`$Sys` and the other builtin modules.

What this guarantees: between two modules that both carry digests, a call
through a `load`ed module reaches a function of exactly the declared type, up
to SHA-256. Everything built from this tree carries them.

What strict mode adds: by default a module with no digests (built by an older
compiler, or with the section removed) is still linked on the 32-bit hash, so
that old modules keep loading; the guarantee above then covers only the links
between modules the current compiler made. `emu -L`, or a `1` written to
`/dev/strictlink` by the host owner (it cannot be written back to 0), makes
the loader refuse any link in which either side has no digests, so that no
link in the system rests on 32 bits. Everything this tree builds links under
it; a deployment that lets an agent compile and load its own Limbo should run
strict, and keep old module files out of where the agent can load from. On
the native kernel, a file `strictlink` on the boot card has init set it.

What it does not do: Dis has no bytecode verifier. A module file that did not
come from the compiler (written by hand, or patched) is trusted as far as it
is loaded: its instructions can address memory as they like, and a digest
section proves nothing about them, since whoever writes the file writes the
digests too. So "who can cause a module file of their own making to be
loaded" remains a boundary the name space must hold: an agent that can write
a `.dis` file somewhere it can then `load` from is confined by the name space
and the host, not by the type system. Strict linking closes the route that
needed only source and the stock compiler; it does not close that one.

## Shell and Exec Access

The `exec` tool and `shellcmds` field both affect what appears in `/dis`:

```
# exec in caps.tools (no shellcmds) -- sh.dis added to /dis allowlist
# Agent can run: exec cat /dev/sysname (using full /dis/cat.dis path)
caps := ref Capabilities("exec" :: ..., nil, nil, ...);

# shellcmds -- sh.dis + named .dis files added to /dis allowlist
# Agent can run commands by name: exec cat /dev/sysname
caps := ref Capabilities(..., nil, "cat" :: "ls" :: nil, ...);
```

`exec` grants `sh.dis` only (the shell interpreter). Named top-level commands
like `cat.dis`, `ls.dis`, `date.dis` require explicit `shellcmds` entries.
This is a two-level gate: exec access ≠ arbitrary command access.

## Invocation

### Starting the Agent

Veltro requires tools9p to be started first. The caller chooses which tools to grant, and optionally which host filesystem paths to expose:

```sh
# Inside Inferno (emu):

# Single-shot task with minimal tools
/dis/veltro/tools9p read list; /dis/veltro/veltro 'list the files in /appl/cmd'

# Full tool set (trusted use)
/dis/veltro/tools9p read list find search write edit exec spawn xenith say hear diff json webfetch git memory todo websearch grep; /dis/veltro/veltro -v 'task'

# Expose a host filesystem path to the agent (-p flag, comma-separated)
/dis/veltro/tools9p read list find grep; /dis/veltro/veltro -p /n/local/Users/pdfinn/projects 'task'

# Multiple paths
/dis/veltro/tools9p read list write edit; /dis/veltro/veltro -p /n/local/Users/pdfinn/projects,/n/local/Users/pdfinn/docs 'review the docs'
```

**This separation is intentional security architecture**: capability granting flows from caller to callee, never the reverse. The `-p` flag controls host filesystem access; without it, `/n/local` is completely hidden.

### Spawning Subagents

From within an agent session:

```
Spawn -- tools=read,list :: list the contents of /n and /tmp
Spawn -- tools=read,list,find agenttype=explore :: find all .b files under /appl
Spawn -- tools=read agenttype=plan model=sonnet :: plan a refactor of veltro.b
Spawn -- tools=exec shellcmds=cat,ls :: inspect only with the named commands
```

Options:
- `tools=<csv>` -- tools to grant (required)
- `paths=<csv>` -- paths to expose, each inside a grant the agent itself holds (optional)
- `shellcmds=<csv>` -- shell commands to allow (grants sh.dis + named cmds)
- `agenttype=<type>` -- agent prompt: default, explore, plan, task
- `model=<name>` -- LLM model (default: the llmsrv backend default)
- `temperature=<float>` -- 0.0-2.0 (default: 0.7)
- `thinking=<val>` -- off, max, or token budget 0-30000
- `system=<prompt>` -- explicit system prompt (overrides agenttype)

### Speech

If speech9p is mounted at `/mnt/speech`:
- `say <text>` -- text-to-speech output
- `hear` -- speech-to-text input (5-second recording)
- `Voice` button in Xenith REPL for voice input

## Verification

`verifyns(expected)` is an explicit test/debug helper. Production entry points
do not call it automatically. When invoked it:

1. Reads `/prog/$pid/ns` for current namespace state
2. Checks for known dangerous paths in mount table (`/n/local`, `#U` bindings)
3. Negative assertions: `stat()` on `/.env`, `/.git`, `/CLAUDE.md`, `/n/local` -- must fail
4. Positive assertions: `stat()` on expected paths -- must succeed
5. Returns nil on success, violation description on failure

Runtime enforcement comes from `restrictns()`, `NODEVS`, process groups, and
descriptor pruning. `nsaudit` and namespace manifests are advisory evidence;
they do not repair a bad runtime capability set.

## Design Decisions

### Why bind-replace (v3) instead of NEWNS + sandbox (v2)?

| Criterion | v2 (NEWNS + sandbox) | v3 (FORKNS + bind-replace) |
|-----------|---------------------|---------------------------|
| File copying | Required (NEWNS loses binds) | None |
| Cleanup | Required (rmrf copied sandbox) | Reclaim small bind-shadow directories |
| Bootstrap | Chicken-and-egg problem | No problem (fork existing) |
| Code size | Larger copied-sandbox builder | `nsconstruct.b` plus focused helpers |
| Security model | Allowlist (by construction) | Allowlist (by replacement) |
| Collision control | Create-fails-if-exists | PID/sequence/time-scoped shadow dirs |

### Why restrict `/` (root)?

When running `emu -r.`, the host project directory is bound onto `/` with MAFTER. This exposes `.env`, `.git`, `CLAUDE.md`, and the entire source tree. Individual bind-overs on entries don't affect `dirread()` -- Inferno's union mount returns entries from ALL union members. The only way to hide entries is to replace the entire root union with `restrictdir("/", safe)`.

### Why skip stat() for root entries?

`stat("/tool")` in the tools9p serveloop deadlocks: `/tool` is the serveloop's own 9P mount, and stat sends a 9P Tstat message that the serveloop can't process because it's blocked on stat. Solution: for `target == "/"`, create directory mount points unconditionally and let bind failures be non-fatal.

### Shadow Directory Management

Shadow directories are created under `/tmp/.veltro-ns/shadow/` with `{pid}-{seq}`
names. PID prefix avoids collisions between parent and child. The unrestricted
tools9p cleanup process can access this tree; restricted agents cannot.

## Files

| File | Purpose |
|------|---------|
| `module/nsconstruct.m` | Module interface: capabilities, restriction, verification helpers |
| `appl/veltro/nsconstruct.b` | Core implementation |
| `appl/veltro/tools9p.b` | Tool filesystem server with serveloop namespace restriction |
| `appl/veltro/cowfs.b` | Overlay server for `rw` grants and activity scratch; diff, promote and revert of what is staged |
| `appl/veltro/veltrosrv.b` | The coordinator: the agent loop served at `/mnt/veltro`, restricted before it serves |
| `appl/veltro/veltro.b` | Command-line client of `veltrosrv` |
| `appl/cmd/lucibridge.b` | Lucia's client of `veltrosrv`; model effects go through tools9p |
| `appl/veltro/tools/spawn.b` | Secure subagent spawn with FORKNS + restrictns |
| `appl/veltro/subagent.b` | Subagent runloop (runs in restricted namespace) |
| `lib/veltro/agents/*.txt` | Agent type prompts (default, explore, plan, task) |
| `lib/veltro/system.txt` | System prompt (output format specification) |
| `lib/veltro/reminders/security.txt` | Security reminders injected into prompts |
| `lib/veltro/tools/spawn.txt` | Spawn tool documentation |

## Testing

Security tests are in `tests/veltro_security_test.b`:

```sh
export ROOT=$PWD && export PATH=$PWD/MacOSX/arm64/bin:$PATH
cd tests && mk install
./emu/MacOSX/o.emu -r. /tests/veltro_security_test.dis -v
```

Tests cover:
- `restrictdir()` allowlist (only allowed items visible)
- `restrictdir()` exclusion (non-allowed items invisible)
- `restrictdir()` idempotent (multiple calls safe)
- `restrictns()` full policy (/dis, /dev, /n, /lib, /tmp, /)
- `restrictns()` shell access via shellcmds
- `/prog` is empty for exec both with and without shellcmds
- baseline `/dev`, `/dis`, `/prog`, and `/lib` surface and read-only attenuation
- concurrent live-shadow containment while restricted namespaces coexist
- `verifyns()` violation detection
- Audit logging
- Missing items handled gracefully
- `/tmp` writable after restriction (MCREATE on shadow bind)
- `exec` in tools grants `sh.dis` without `shellcmds`
- `sh.dis` and other read-only grants reject write, truncation, remove, and wstat
- rebinding and 9P export cannot strip read-only attenuation; explicit deeper writable mounts work
- `caps.paths` exposes granted `/n/local/` subtree

Staged writes: `tests/cowfs_control_test.b` (the overlay's records out of
reach of the mount, deletions, conflicts) and
`tests/host/lucibridge_promote_test.sh` (a task that goes for the records with
its tools, an overlay naming another folder than the one granted, the approval
dialogue).

Concurrency tests in `tests/veltro_concurrent_test.b`:
- Concurrent init
- Concurrent restrictdir
- Concurrent restrictns

## nsaudit: Advisory Analysis

### Not verification — syntactic analysis

The existing `formal-verification/` tree model-checks a TLA+ specification
of the kernel's namespace copy, bounded-checks `pgrpcpy`'s deep copy in CBMC
and confirms three fixed races in SPIN. Those checks are about the mechanism,
and they are checks of a model and of one function, not a proof that the
mechanism isolates (see `formal-verification/README.md`, "What this does and
does not establish").

`nsaudit` is about the *configuration* that feeds the mechanism. It parses a
capability configuration, looks up each tool in a per-tool authority
manifest, and applies pattern-match rules over the resulting authority set.
No symbolic execution, no theorem, no proof. This is syntactic analysis —
closer to a linter or a type checker than to TLA+. The two efforts are
complementary: `formal-verification/` checks the kernel's copy does what
the spec says; `nsaudit` checks that what you're telling it is what you meant.

### The question it answers

A single question, asked daily and asked under different urgencies:

> **"What does this namespace configuration actually allow the agent to do?"**

- *Daily debugging (high volume, low stakes)*: "My agent can't see
  `/n/local/foo/bar` and I don't know why. What did I miss?" — `nsaudit
  -reach /n/local/foo/bar` answers it.
- *Shipping defaults (low volume, very high stakes)*: "The config we ship to
  every InferNode install — does it grant an agent escape valve we didn't
  intend?" — `nsaudit` run on a committed fixture, diffed against a
  committed snapshot, gated in CI.
- *Tool development (per tool)*: "The new tool I'm writing — what authority
  does it actually add to an agent's caps?" — tool author runs `nsaudit`
  against a test fixture that includes their tool and reviews the report.
- *Security review (per release, per incident)*: "The Meta Agent has
  capabilities we've never formally scoped. What can it reach and cause?" —
  `nsaudit` run against the meta-agent fixture, violations section reviewed
  by hand.

Same tool, same engine. Different modes emphasize different parts of the
same underlying analysis.

**`nsaudit` is advisory, not enforcing.** The namespace is still what
enforces. `restrictns()`, `FORKNS`, `NODEVS`, cowfs overlays, and
`wallet9p`'s per-transaction gating are the runtime gate; `nsaudit` is the
pre-flight review. If you ship a misconfigured caps, `nsaudit`'s warning
does not help you at runtime — only the correctness of the caps themselves
does. The value `nsaudit` adds is making misconfiguration visible before
it ships.

A report says only what was checked. With no rules, a file among the rules
that is not one, a role that is neither `toplevel` nor `child`, an activity id
that is not a number, or a tool whose name is not a name in the manifest
directory, `nsaudit` fails saying so and reports nothing.

### Data model

All inputs and outputs are files. No serialization format is invented; no
in-tree JSON; everything is either a directory of scalar files (like
`tools9p` already uses) or an ndb(6) attribute file (like factotum and cs
already use). Inferno has `attrdb(2)` in `module/attrdb.m` and the ndb
parser in `appl/cmd/ndb/`.

**Caps input — a directory of scalar files** (the format `tools9p` already
exposes at `/tool/`):

    /tool/tools       one tool name per line
    /tool/paths       one `path ro|rw|cow` effective capability per line
    /tool/meta/role   "toplevel" or "child"
    /tool/meta/xenith "1" or "0"
    /tool/meta/actid  integer or "-1"
    /tool/meta/nodevs "set" or "unset"

Live audit: `nsaudit /tool`. Hypothetical analysis: construct a mock
directory of the same shape. Fixtures for CI are directories of the same
shape.

`tools9p` exposes `role`, `xenith`, `actid`, and `nodevs` as read-only scalar
files under `/tool/meta/`. Fixtures use the same shape. `nodevs` is not
declared by the launcher: every tool `tools9p` runs runs with `NODEVS` (exec's
wrapper applies its own) or the call is refused, so it is always `set`. The
old `-N` flag is accepted and ignored.

**Tool authority manifest — ndb files at `lib/veltro/nsaudit/authorities/<tool>`:**

    ; cat lib/veltro/nsaudit/authorities/exec
    description  Execute a shell command via sh.dis
    authorities  spawns_proc execs_code reads_fs writes_fs dials_net
    irreversible spawns_proc writes_fs dials_net
    notes        Force multiplier. Grants anything the spawned shell can
                 reach within the agent's namespace. Named top-level
                 commands require caps.shellcmds.

One file per tool. Adding a tool means adding a file. Reviewed at every
new tool.

**Rules — ndb files at `lib/veltro/nsaudit/rules/<name>`:**

    ; cat lib/veltro/nsaudit/rules/device-gate-bypass
    rule      DEVICE_GATE_BYPASS
    severity  high
    require   'role=toplevel nodevs=unset'
    message   top-level caps grants kernel device attach without NODEVS.
              Any sys->bind on an #x device will succeed, reaching
              #sfactotum, #U (host fs), or other kernel services
              regardless of path-based restriction.
    fix       add sys->pctl(Sys->NODEVS, nil) after the FORKNS site

One file per rule. Adding a rule means adding a file and a fixture under
`tests/nsaudit-rules/`. Suppression files are not implemented; a finding must
currently be removed by changing the capability set or the reviewed rule.

### Authority axes (closed set)

The soundness of syntactic analysis depends on the axis set being closed
and enumerable. Adding a new axis is a deliberate act, not a derivation:

| Category | Axis | Source |
|---|---|---|
| Filesystem | `reads_fs` | tool manifest, `caps.paths` |
| Filesystem | `writes_fs` | tool manifest, `caps.paths` |
| Filesystem | `writes_fs_durable` | `writes_fs` ∧ not `/tmp/veltro` ∧ `actid < 0` |
| Network | `dials_net` | tool manifest, `caps.mcproviders` |
| Network | `listens_net` | tool manifest |
| Process | `spawns_proc` | tool manifest (e.g. exec, spawn, launch) |
| Process | `signals_proc` | tool manifest |
| Process | `execs_code` | tool manifest |
| Kernel | `attaches_device` | `role=toplevel` ∧ `nodevs=unset` |
| Secrets | `reads_secrets_factotum` | `/mnt/factotum` in reads_fs |
| Secrets | `reads_env` | `NEWENV` unset |
| Economic | `proposes_payment` | tool manifest (wallet, payfetch) |
| Economic | `spends` | tool manifest for a distinct direct-spend capability |
| Comms | `proposes_message` | `writes_fs` and exact `/mnt/msg/draft` grant |
| Comms | `sends_llm` | tool manifest, `caps.llmconfig` |
| Comms | `sends_ui` | `caps.xenith` ∨ `/mnt/ui` in writes_fs |
| Comms | `receives_input` | `/dev/cons` in reads_fs |
| Windows | `reads_windows` | `caps.xenith` |
| Windows | `modifies_windows` | `caps.xenith` |
| Memory | `persists_memory` | `caps.memory` |

### Current Rule Set

Each rule is a file at `lib/veltro/nsaudit/rules/`, each with a test
under `tests/nsaudit-rules/`. New rules land as (file, test) pairs.

| Rule | Condition | Severity |
|---|---|---|
| `DEVICE_GATE_BYPASS` | `role=toplevel` ∧ `nodevs=unset` | high |
| `DIRECT_MAIL_SEND` | a raw mail compose/send path is granted | high |
| `INVALID_PATH_GRANT` | malformed or delimiter-bearing path grant | high |
| `PRIVILEGED_CONTROL_PATH` | a trusted controller path is granted | high |
| `EXFIL_RISK_EGRESS` | `reads_fs ∩ (dials_net ∨ sends_llm ∨ spawns_proc)` | high |
| `EXEC_FORCE_MULTIPLIER` | `exec` in tools | info |
| `UNCONSTRAINED_SHELL` | `exec` in tools ∧ `shellcmds` empty | high |
| `SPAWN_INHERITANCE` | `spawn` in tools ∧ `writes_fs_durable` | medium |
| `DURABLE_HOST_MUTATION` | `writes_fs_durable` non-empty | medium |
| `UNBOUNDED_SPEND` | `spends` without capability-bound enforcement attestation | high |
| `LLM_AS_EGRESS_FOR_SECRETS` | `sends_llm` ∧ reads_fs contains secrets path | high |
| `NET_EGRESS_IMPLICIT` | `dials_net` without matching `mcproviders` entry | medium |
| `SUBAGENT_MISSING_NODEVS` | `role=child` ∧ `nodevs=unset` | high |

`SUBAGENT_MISSING_NODEVS` turns the child `pctl(NODEVS)` call from an
implementation detail into a checked profile property. A child fixture with
`nodevs=unset` fires the rule and fails CI.

### Lightweight profile invariants

The first `nsaudit` profile fixtures are deliberately not full shipping
snapshots. InferNode is still moving too quickly for every ordinary tool list
or read path to be frozen as a release contract. The current fixtures are
executable assumptions: they describe the shape of authority we intend, and
`tests/host/nsaudit_profiles_test.sh` enforces only hard namespace-security
invariants.

Current fixtures under `tests/nsaudit-fixtures/`:

- `profile-minimal-headless` — base compute agent: read/list/find/grep,
  no GUI/window authority, no payments, `nodevs=set`.
- `profile-desktop-gui` — base profile plus fixed-function UI tools. This is
  the local Lucifer/desktop shape, not the headless default. `/mnt/ui` itself
  is not a path grant: `nsconstruct` derives its narrowed visibility from the
  granted UI tools, preventing generic filesystem and shell tools from reusing
  raw UI controller authority.
- `profile-messaging` — base profile plus the `write` tool and exact message
  read/proposal surface (`/mnt/msg`, `/mnt/msg/draft`). A draft write queues an
  immutable proposal; it does not send or approve it. Trusted message controls
  remain excluded, and the identity of the trusted approver is a deployment
  property rather than something the draft capability can attest.
- `profile-payments` — base profile plus wallet proposal authority
  (`/mnt/wallet`). Agent-visible `pay` and `authorize` files can only queue
  proposals; approval cannot be disabled, and trusted wallet controls remain
  excluded. A future direct-spend capability would be a distinct authority and
  would require enforcement metadata for that exact agent view.

The important design rule is additive composition. Start with a small base
namespace, then overlay only the capability layer required for the job:
messaging, payments, local GUI, or future remote administration. This is a
natural Plan 9/Inferno shape: profile layers can later be implemented with
ordinary namespace operations, including union binds where appropriate,
without turning the audit model into a separate policy engine.

Headless and desktop are distinct because `/mnt/ui` is authority. A headless
container should not receive `/mnt/ui` or `/chan` just because a UI service is
mounted somewhere nearby. If another InferNode exports a UI surface into the
namespace, that becomes a human-interaction and UI-state capability. That may
be exactly what a remote-admin or "remote desktop" profile wants, but it must
be explicit:

- `profile-minimal-headless`: no `/mnt/ui`, no `/chan`, no `sends_ui`, no
  `reads_windows`.
- `profile-desktop-gui`: local GUI/UI interaction is allowed through
  fixed-function tools; raw `/mnt/ui` path grants are rejected.
- future `profile-remote-admin-ui`: explicit remote UI grant, with separate
  authentication/provenance assumptions.
- future `profile-observe-ui`: possible read-only/event-only UI view if the
  namespace surface supports that distinction.

A fixed-function UI tool is only as fixed as the requests it writes. The
`/mnt/ui` control files take one request per write, and the request's first
word is the command, so a tool that puts model text into one must keep that
text where it is data. Two things hold this. `luciuisrv` takes a request
whole however many 9P messages carry it (a write longer than one message used
to be run a message at a time, the later ones as commands of their own), and a
tool does not write a control request longer than one message: long content
goes through an artifact's `data` file. This matters because of one request in
particular: `create ... type=app dis=<path> data=<args>` makes Lucifer start
that program with those arguments in its own name space, with the user's
authority, outside any agent's confinement. Lucifer loads only from `/dis/wm`
and `/dis/xenith`, and `luciuisrv` refuses any other path, but the arguments
are free (`wm/shell -c`, an editor's file). Of the agent's tools `launch`
writes such requests, building the path and checking the arguments itself, and
`keyring` a fixed one; `present` makes content artifacts and nothing else.

A GUI program a tool drives is the user's program in the user's name space,
and is not confined. A tool must not have it open or save a name the agent
chose: there the name is another file (the shared `/tmp/veltro/scratch`, not
the activity's; the real file, not the overlay) and no grant is read-only. So
the `editor` tool does the file I/O itself, in its own restricted name space:
`open` reads the file and writes the text to the editor's `body`, `save` reads
`body` and creates the file after the same check `write` makes, and the editor
is told the name only to show it (`remote`). The editor does not write a
document under such a name, its `quit` from a client saves nothing, and text a
client put in a document is not saved on the user's way out without the user
asking. The same holds for Xenith: an agent's windows are labels, never file
names.

Xenith's window `ctl` keeps Acme's rule, one write is whole commands, and does
not gather a request across messages as `luciuisrv` does. A write longer than
one 9P message (8192 bytes of data) reaches it in pieces, and it ran each as
commands of its own, so the end of a long line became a command its writer
never wrote (`name`, `put`). The `xenith` tool writes no request that long.
Xenith now also refuses a `ctl` write that fills its message and does not end
a line, before any of it is run; the mount driver stops at the refusal, so the
rest is not sent. Whole lines that fill a message are still taken. A program
that writes a `ctl` through a connection with a smaller message size than
Xenith's is cut where Xenith cannot see it: such a program must keep its
requests short itself, as the tool does.

The `matrix` tool composes into Matrix's name space, which is also the user's.
An agent's composition places display modules, and names a service or a watch
only over Matrix's own data (`/tmp/matrix`) or exactly as the live composition
already has it: a service's outputs come back to the agent (`out`), and a
watch's arms tell it what a file holds, so neither is the agent's to point at
the user's files. A library composition is the owner's grant, loaded with
`ctl load`. What its services publish an agent holding the tool can read:
with `sysmon` loaded that is the process table and the network census, so
"bounded process visibility" below is a property of the agent's own name
space, not of what a loaded Matrix service reports. Hosting an app in a
composition is never an agent's line.

The same rule applies to other fixed-function service trees. `/mnt/matrix` is
derived only from the `matrix` tool, `/mnt/git` only from the `git` tool,
`/mnt/vision` only from `vision`, `/mnt/wikia` only from `wiki`,
`/mnt/video` only from video presentation tools, and `/phone` only from `sms`,
`dial`, or `contacts`.
Legacy authority roots such as `/mnt/keys`, `/mnt/keysrv`, and
`/mnt/registry` are also never caller-supplied path capabilities. `/llm/ctl`
is likewise Settings/admin
authority over the host LLM backend, so raw grants of `/llm` or `/llm/ctl` are
rejected while exact status-only reads can remain ordinary filesystem reads.
Audit subjects should receive the exact append-only `/mnt/audit/log` endpoint,
not `/mnt/audit`, `/mnt/audit/chain`, or
`/mnt/audit/ctl`; the broad root leaks log history and the control file can
force checkpoint signing. This prevents generic filesystem or shell tools from
driving Matrix composition controls, video transport controls, SMS, calls, or
backend switches and audit-control operations through a raw namespace grant.

The profile invariant test currently fails on:

- any high-severity `nsaudit` violation;
- missing `NODEVS` / `attaches_device`;
- explicit trusted control-path grants;
- factotum secret visibility;
- message proposal authority outside the messaging profile;
- UI authority outside the GUI profile;
- payment proposal authority outside the payments profile;
- direct spend authority in the proposal-only payments profile.

This is intentionally narrower than a full snapshot gate. It lets ordinary
profile details churn while making the non-negotiable security properties
visible immediately.

### CI Gate

The gate is not runtime enforcement. CI runs the rule fixtures, additive
profile invariants, and component-aware path checks. These fail on known bad
authority compositions but do not freeze complete shipping namespace snapshots.

The current additive fixtures are listed above. `nsaudit_profiles_test.sh`
also starts a live `tools9p` with each fixture's tools and paths, and with the
desktop+messaging, messaging+payments and all-layer compositions, and requires
its `nsaudit -m /tool` report to equal the fixture's (a composition's, the
union of its layers'). That ties the fixtures to what `tools9p` serves, not to
any launcher's command line: full shipping snapshots and boot-configuration
drift checks do not exist yet, so do not describe a profile fixture as proof
that a particular launcher has the same authority set.

### What nsaudit cannot answer

Stated plainly, because a tool that over-claims is worse than no tool:

- **Prompt injection propagation.** If the agent reads attacker-controlled
  data and the LLM chooses to act on it, effective authority becomes
  whatever the model decides. Not statically decidable.
- **Semantic reversibility.** "Agent overwrote `notes.txt`" is
  reversible with backups, not without. Context-dependent.
- **Manifest truthfulness.** A lying manifest entry is undetectable to
  `nsaudit`. The runtime ground-truth check (below) is the safety net.
- **Tool-internal composition.** A tool that invokes sub-tools not named
  in its manifest entry is as good as its manifest, no better.

A caps that passes `nsaudit` is *not* "safe." It is "free of the
authority compositions `nsaudit` knows to check for." That ceiling is the
right one to advertise.

### Runtime ground-truth check

The one place runtime code is needed is the cross-check: does `nsaudit`'s
static model of `reads_fs` agree with what `restrictns()` actually
produces at runtime?

The proposed `tests/nsaudit_groundtruth_test.b` should fork, apply real
`restrictns(caps)` for each fixture, walk the resulting namespace with a
bounded BFS, and assert the walked set equals the `reads_fs` set the linter
computed for the same caps. That test does not exist yet. Any disagreement
would mean either the linter's model or the implementation has drifted.

This is where `nswalk` lives: not as a user-facing tool, but as a
subroutine of the ground-truth check. Once it exists as a subroutine,
exposing it as a user tool is cheap.

### NODEVS Device-Attach Gate

`pctl(NODEVS)` is applied before model-controlled code at every execution
boundary: `veltrosrv`, each ordinary `tools9p` invocation, the exec
wrapper after its private wait FD is opened, and each spawned child after its
namespace and keep-list are complete. The kernel device gate is in
`emu/port/chan.c`;
with `nodevs` set, `sys->bind("#sfactotum", "/tmp/veltro/x", MREPL)` (and any
`#x` attach outside the `|esDa` allowlist) fails, so device-attach cannot
bypass the path-based restriction.

This property is locked in by a regression test —
`testNodevsBlocksDeviceAttach` in `tests/veltro_security_test.b` — which
asserts that after `NODEVS`, `bind("#p", …)` and `bind("#sfactotum", …)`
both fail (and that `#p` *succeeds* before `NODEVS`, so the test proves the
gate, not an unrelated error).

The throwaway `FORKNS` in `tools9p.b`'s `emitmanifestnow()` has no `NODEVS`:
it forks only to compute a
namespace manifest for the UI and **discards** that namespace immediately —
it runs no model-driven code and never execs, so it is not an agent
sandbox and does not need the gate.

### Remaining Work

- Add a runtime ground-truth test that compares advisory authority output with
  the namespace produced by `restrictns()`.
- Add full fixtures for the meta-agent, Lucifer GUI, and remote administration.
- Add shipping-profile snapshots tied to actual boot configuration.
- Integrate authority display and preview into lucictx.

### Prior art, or lack thereof

No tool exists in the Plan 9 / Inferno / 9front ecosystem for namespace
safety analysis (verified 2026-04). The closest things are `ns(1)`
(inspection only) and ANTS's per-process `/srv` (mitigation, not
analysis). No tool exists in the broader capability-OS literature for
authority inventory over a running agent's caps either —
seL4/EROS/KeyKOS verify confinement at the kernel level but do not
produce human-readable authority reports for application-level capability
sets. `nsaudit` fills unclaimed ground.

### Current state

- `appl/cmd/nsaudit.b` — advisory CLI with report, reachability, diff, and
  machine-readable modes.
- `lib/veltro/nsaudit/authorities/` — per-tool authority manifests.
- `lib/veltro/nsaudit/rules/` — rule files, with one fixture per rule under
  `tests/nsaudit-rules/`.
- `tests/nsaudit-fixtures/profile-*` — lightweight additive profile fixtures
  for minimal headless, desktop GUI, messaging, and payments.
- `tests/host/nsaudit_profiles_test.sh` — hard invariant gate for those
  profile fixtures, and a live `tools9p` for each (and three compositions)
  audited the same way.
- `tests/host/nsaudit_path_semantics_test.sh` — regression for component-aware
  path containment.
- No full shipping-profile snapshot gate yet.
- `tools9p` exposes read-only role, xenith, activity, and NODEVS metadata.
- No runtime ground-truth check yet.
- No lucictx integration yet.
- No `meta-agent`, `remote-admin-ui`, or `lucifer-gui` fixture yet — those are
  the next high-value profile targets.
