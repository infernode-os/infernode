# Veltro Security Model (v3)

## Overview

Veltro uses Inferno OS namespace isolation to create secure environments for AI agents. The core primitive is `restrictdir(target, allowed, writable)`: create a shadow directory containing only allowed items, then bind-replace the target. Anything not in the allowlist becomes invisible. The `writable` flag adds `MCREATE` to the final bind, needed for `/tmp` so agents can create files there.

### Terminology

This document distinguishes:

- **Harness** — the namespace-restriction machinery itself: `nsconstruct`,
  `tools9p`, and the `veltro`/`repl`/`spawn` entry points. The harness defines
  what an agent *can* do and is trusted code.
- **Coordinator** — the process that owns the model loop and chooses which
  tool request to send. `veltro` and `repl` restrict their own namespaces.
  `lucibridge` is a trusted GUI coordinator: it does not call `restrictns()`;
  model-requested effects cross into a fresh, confined `tools9p` worker for
  every call. Model text is data and never executes in the coordinator.
- **Agent** — a logical model session plus its capability set. Do not assume
  one agent means one confined process: the enforcement point is either its
  restricted coordinator (`veltro`/`repl`), its per-call `tools9p` worker, or
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
through `/mnt/msg/approve` (or discard it through `/mnt/msg/deny`). Never bind
those controller endpoints into an agent namespace. Message notification text is
also part of the boundary: source-controlled fields must remain single physical
lines so hostile mail/SMS content cannot forge `Triage:` or `Message ID:`
control records.

Wallet payments follow the same split. A `/n/wallet` grant is narrowed inside
the agent namespace: agents can read account metadata and write per-account
`pay` proposals and structured `authorize` (x402/EIP-3009) requests, but cannot
see root `ctl`, `pending`, `new`, or per-account `ctl`. There is no raw `sign`
file at all: a hash-blind signing oracle over the spend key — signing an
attacker-chosen 32-byte hash can authorize an arbitrary transfer — cannot be
protected by namespace narrowing alone, so it was removed rather than hidden
(`NsConstruct->walletcontrolpath`, shared with `tools9p`, still refuses it as a
grant). wallet9p constructs everything it signs
(transactions from `pay`, EIP-712 digests from `authorize`) and enforces budget
and approval policy on every execution path. Payment approval and wallet
configuration remain trusted-controller actions outside the model namespace.

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

Four model-execution boundaries apply namespace restriction:

| Entry Point | Where | When |
|-------------|-------|------|
| `tools9p` invocation | `appl/veltro/tools9p.b` | Per tool call, after `FORKNS`, attenuated to the invoked tool |
| `repl` init | `appl/veltro/repl.b` | After mount checks, before LLM session |
| `veltro` init | `appl/veltro/veltro.b` | After tool discovery, before LLM session |
| `spawn` child | `appl/veltro/tools/spawn.b` | In runchild(), before subagent->runloop() |

All four call `nsconstruct->restrictns(caps)` after `pctl(FORKNS)`. `lucibridge`
does not run model-supplied code directly; it relies on the `tools9p` row for
every model-requested tool effect.

## How It Works

### Core Primitive: `restrictdir(target, allowed, writable)`

```
1. Create unique trusted shadow dir: /tmp/.veltro-ns/shadow/{pid}-{seq}/
2. For each item in allowed:
   - Create mount point in shadow (dir or file matching source type)
   - bind(target/item, shadow/item, MREPL)
3. flags = MREPL | (writable ? MCREATE : 0)
   bind(shadow, target, flags)  -- replace entire target
4. Result: target shows only allowed items; everything else is gone
```

`writable=1` adds `MCREATE` to the final and inner binds so file creation is
permitted. It is used only for explicit writable views such as `/tmp`, activity
scratch, wallet proposal files, message draft/flag endpoints, and cowfs staging.

Special handling for `target == "/"`:
- Skips `stat()` on each item to avoid deadlock on 9P self-mounts (e.g., `/tool`)
- Creates directory mount points unconditionally
- Bind failures are non-fatal (item may not exist in current namespace)

### Layered Restriction

```
tools9p call:   FORKNS + restrictns()   -- one invoked tool only
veltro/repl:    FORKNS + restrictns()   -- restrict coordinator namespace
subagent spawn: FORKNS + restrictns()   -- inherit + further restrict
```

All layers use the same `restrictdir()` primitive. Capability attenuation is
natural: children fork an already-restricted namespace and can only narrow
further.

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
files, and GUI IPC trees are present only when the relevant tool or an explicit
path capability names them. Trusted app control files under `/tmp/veltro/*/ctl`
must never be ambient.

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
| 4 | `/n` | Capability-derived foreign imports: speech, wallet, wikia, presentation, and exact `/n/local` grants | Foreign-tree capabilities |
| 5 | `/mnt` | Exact application subtrees plus fixed-function tool mounts such as Git; sensitive services are narrowed again | Synthesized-service capabilities |
| 6 | `/lib` | `veltro/`, `certs/`; `/lib/veltro/keys` replaced with an empty view | Prompts/config and TLS roots, not credentials |
| 7 | `/env` | `VELTRO_SESSION` only | No inherited environment secrets |
| 8 | `/prog` | Current pid for non-exec tools; empty for exec, including exec with `shellcmds` | No parent/sibling inspection or control |
| 9 | `/` | Base system dirs plus only capability-derived `/mnt`, network, UI, phone, and explicit root trees | Replace the host-backed root union |
| 10 | `/tool` and extra roots | Tool metadata/current tool plus recursively narrowed explicit path grants | Remove generic control files and sibling paths |
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
  1. pctl(FORKNS)
  2. pctl(NODEVS)
  3. bind /tool.N over /tool
  4. restrictns(Capabilities(tools = [tool], ...))
  5. execute only that tool module
```

`exec` defers `NODEVS` to its trusted wrapper. The wrapper opens the current
worker's `#p/<pid>/wait`, retains only that FD and its I/O across `NEWFD`, then
applies `NODEVS` before parsing or running model-supplied command text. Its
`/prog` directory is empty even when named `shellcmds` are granted.

After restriction, all async tool execution threads (via `spawn asyncexec()`) inherit the restricted namespace.

### repl and veltro Restriction

Both command-line coordinators apply `NODEVS` and restriction after discovering
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

### spawn Child Restriction

The child process applies the full isolation sequence:

```
1. pctl(NEWPGRP)         -- Fresh process group (empty srv registry)
2. pctl(FORKNS)          -- Fork parent's restricted namespace
3. pctl(NEWENV)          -- Empty environment (NOT FORKENV!)
4. Open LLM FDs          -- While /mnt/llm still accessible from parent
5. restrictns(caps)      -- Further bind-replace restrictions
6. verifysafefds()       -- Redirect FDs 0-2 to /dev/null if nil
7. pctl(NEWFD, keepfds)  -- Prune all other FDs (llm ask, log, pipe, provenance store)
8. pctl(NODEVS)          -- Block #U/#p/#c device naming
9. setprov(childid, fd)  -- Arm audit provenance (INFR-355): child seals its
                            trajectory via the bound write-only /mnt/audit/log;
                            payloads go to the content store over the pre-dialed fd
10. subagent->runloop()  -- Execute task with pre-loaded tool modules
```

When the install audits (`/mnt/audit/log` present), spawn auto-grants that
append-only path into every child's caps; `auditcontrolpath` keeps
`/mnt/audit` itself, `chain`, and `ctl` ungrantable, so a child can append
to its own trail but can never read or rewrite history (AU-9 by placement).

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
| No env secrets | `/env` is allowlisted; spawned children also use `NEWENV` |
| No ambient child FDs | Spawn uses `NEWFD`; exec keeps only I/O and its private wait FD |
| Safe FD 0-2 | `verifysafefds()` redirects nil FDs to `/dev/null` |
| Empty srv registry | NEWPGRP first (child) |
| Truthful namespace | bind-replace shows only allowed items; no "access denied" on visible paths |
| Capability attenuation | Child forks restricted parent, can only narrow |
| Bounded process visibility | `/prog` is self-only for non-exec tools and empty for exec, with or without `shellcmds` |
| Shadow cleanup | tools9p reclaims per-call physical shadows and sweeps crash leftovers at startup |
| Auditable construction | `restrictns()` pre-opens only the write-only audit append FD, `emitauditlog()` seals the completed restriction through it, then closes it before tool execution; the audit tree never enters the tool namespace |
| No cross-window access | `/chan` hidden unless `caps.xenith` is set; REPL opens FDs before restriction |
| exec grants sh.dis only | `sh.dis` bound when `exec` is in caps.tools; named commands require `shellcmds` |
| Shell access controlled | `sh.dis` + named command `.dis` files only bound if `shellcmds` is non-nil |
| Writable views explicit | `MCREATE` appears only on `/tmp`, proposal endpoints, activity scratch, and cowfs staging |
| Host path control | `/n/local` hidden unless `caps.paths` grants specific subpaths (`-p` flag) |
| Speech preserved | `/n/speech` auto-detected and included in `/n` allowlist |
| 9P self-mount safe | Root restriction skips `stat()` to avoid deadlock on `/tool` |

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

# Start tool server with specific tools, then launch interactive REPL
/dis/veltro/tools9p read list find search spawn edit write xenith say; /dis/veltro/repl

# Single-shot task with minimal tools
/dis/veltro/tools9p read list; /dis/veltro/veltro 'list the files in /appl/cmd'

# Full tool set (trusted use)
/dis/veltro/tools9p read list find search write edit exec spawn xenith say hear ask diff json webfetch git memory todo websearch grep; /dis/veltro/repl -v

# Expose a host filesystem path to the agent (-p flag, comma-separated)
/dis/veltro/tools9p read list find grep; /dis/veltro/repl -p /n/local/Users/pdfinn/projects

# Multiple paths
/dis/veltro/tools9p read list write edit; /dis/veltro/veltro -p /n/local/Users/pdfinn/projects,/n/local/Users/pdfinn/docs 'review the docs'
```

**This separation is intentional security architecture**: capability granting flows from caller to callee, never the reverse. The `-p` flag controls host filesystem access; without it, `/n/local` is completely hidden.

### Spawning Subagents

From within an agent session:

```
spawn tools=read,list -- list the contents of /n and /tmp
spawn tools=read,list,find agenttype=explore -- find all .b files under /appl
spawn tools=read agenttype=plan model=sonnet -- plan a refactor of repl.b
spawn tools=exec shellcmds=cat,ls -- inspect only with the named commands
```

Options:
- `tools=<csv>` -- tools to grant (required)
- `paths=<csv>` -- host filesystem paths to expose (optional)
- `shellcmds=<csv>` -- shell commands to allow (grants sh.dis + named cmds)
- `agenttype=<type>` -- agent prompt: default, explore, plan, task
- `model=<name>` -- LLM model (default: the llmsrv backend default)
- `temperature=<float>` -- 0.0-2.0 (default: 0.7)
- `thinking=<val>` -- off, max, or token budget 0-30000
- `system=<prompt>` -- explicit system prompt (overrides agenttype)

### Speech

If speech9p is mounted at `/n/speech`:
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
| `appl/veltro/repl.b` | Interactive REPL with namespace restriction at init |
| `appl/veltro/veltro.b` | Single-shot coordinator with namespace restriction at init |
| `appl/cmd/lucibridge.b` | Trusted GUI coordinator; model effects go through tools9p |
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
- `restrictns()` concurrent (race safety)
- `verifyns()` violation detection
- Audit logging
- Missing items handled gracefully
- `/tmp` writable after restriction (MCREATE on shadow bind)
- `exec` in tools grants `sh.dis` without `shellcmds`
- `caps.paths` exposes granted `/n/local/` subtree

Concurrency tests in `tests/veltro_concurrent_test.b`:
- Concurrent init
- Concurrent restrictdir
- Concurrent restrictns

## nsaudit: Advisory Analysis

### Not verification — syntactic analysis

The existing `formal-verification/` tree proves properties of the kernel's
namespace primitives: 3.17 billion TLA+ states, SPIN model checks, CBMC
harnesses over `pgrpcpy` and friends. Those proofs are about the mechanism.

`nsaudit` is about the *configuration* that feeds the mechanism. It parses a
capability configuration, looks up each tool in a per-tool authority
manifest, and applies pattern-match rules over the resulting authority set.
No symbolic execution, no theorem, no proof. This is syntactic analysis —
closer to a linter or a type checker than to TLA+. The two efforts are
complementary: `formal-verification/` proves the kernel does what it's
told; `nsaudit` checks that what you're telling it is what you meant.

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

### Data model

All inputs and outputs are files. No serialization format is invented; no
in-tree JSON; everything is either a directory of scalar files (like
`tools9p` already uses) or an ndb(6) attribute file (like factotum and cs
already use). Inferno has `attrdb(2)` in `module/attrdb.m` and the ndb
parser in `appl/cmd/ndb/`.

**Caps input — a directory of scalar files** (the format `tools9p` already
exposes at `/tool/`):

    /tool/tools       one tool name per line
    /tool/paths       one path grant per line
    /tool/meta/role   "toplevel" or "child"
    /tool/meta/xenith "1" or "0"
    /tool/meta/actid  integer or "-1"
    /tool/meta/nodevs "set" or "unset"

Live audit: `nsaudit /tool`. Hypothetical analysis: construct a mock
directory of the same shape. Fixtures for CI are directories of the same
shape.

`tools9p` exposes `role`, `xenith`, `actid`, and `nodevs` as read-only scalar
files under `/tool/meta/`. Fixtures use the same shape.

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
| Economic | `spends` | tool manifest (wallet, pay) |
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
| `UNBOUNDED_SPEND` | `spends` without per-call gating metadata | high |
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
- `profile-messaging` — base profile plus the message read/proposal surface
  (`/mnt/msg`, `/mnt/msg/draft`). Trusted message controls remain excluded.
- `profile-payments` — base profile plus wallet proposal authority
  (`/n/wallet`) and a declared `walletbudget`. Trusted wallet controls remain
  excluded.

The important design rule is additive composition. Start with a small base
namespace, then overlay only the capability layer required for the job:
messaging, payments, local GUI, or future remote administration. This is a
natural Plan 9/Inferno shape: profile layers can later be implemented with
ordinary namespace operations, including union binds where appropriate, without
turning the audit model into a separate policy engine.

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

The same rule applies to other fixed-function service trees. `/mnt/matrix` is
derived only from the `matrix` tool, `/mnt/git` only from the `git` tool,
`/mnt/gpu` only from `gpu` or local `vision`, `/n/wikia` only from `wiki`,
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
- UI authority outside the GUI profile;
- spend authority outside the payments profile;
- unbounded spend in the payments profile.

This is intentionally narrower than a full snapshot gate. It lets ordinary
profile details churn while making the non-negotiable security properties
visible immediately.

### CI Gate

The gate is not runtime enforcement. CI runs the rule fixtures, additive
profile invariants, and component-aware path checks. These fail on known bad
authority compositions but do not freeze complete shipping namespace snapshots.

The current additive fixtures are listed above. Full shipping snapshots and
boot-configuration drift checks do not exist yet; do not describe a profile
fixture as proof that a live launcher has the same authority set.

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
boundary: `veltro`, `repl`, each ordinary `tools9p` invocation, the exec
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
  profile fixtures.
- `tests/host/nsaudit_path_semantics_test.sh` — regression for component-aware
  path containment.
- No full shipping-profile snapshot gate yet.
- `tools9p` exposes read-only role, xenith, activity, and NODEVS metadata.
- No runtime ground-truth check yet.
- No lucictx integration yet.
- No `meta-agent`, `remote-admin-ui`, or `lucifer-gui` fixture yet — those are
  the next high-value profile targets.
