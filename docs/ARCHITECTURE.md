# InferNode / Veltro — Architecture

## Overview

InferNode is Inferno OS running natively on AMD64, ARM64 and RISC-V (macOS, Linux, Windows). The AI
agent stack runs entirely inside the Inferno emulator (`emu`), using Plan 9's "everything is
a file" model to integrate the LLM API, tool execution, wallet, and GUI through a unified 9P namespace.

---

## Layer Diagram

```
Host OS (macOS / Linux / Windows)
│
├── emu (Dis VM + JIT compiler)
│     │
│     └── Inferno namespace (rootfs = project root)
│           │
│           ├── /mnt/llm        ← llmsrv (LLM providers as 9P)
│           ├── /mnt/veltro     ← veltrosrv (the agent loop as 9P)
│           ├── /mnt/ui         ← luciuisrv (GUI state 9P server)
│           ├── /n/wallet     ← wallet9p (crypto wallet 9P server)
│           ├── /tool         ← tools9p (44 tool modules as 9P)
│           ├── /mnt/factotum ← factotum (key agent, secstore-backed)
│           ├── /n/local/     ← agent-visible host paths (via sys->bind)
│           ├── /dis/         ← compiled Limbo bytecode (~1,000 modules; tools/dis-manifest.txt)
│           ├── /lib/         ← runtime data (fonts, tool docs, resources)
│           └── /tmp/         ← scratch (writable at /tmp/veltro/scratch/)
│
└── secstored (TCP 5356)      ← encrypted key persistence
                                  (PAK auth on the wire; client-side
                                   AES-256-GCM at rest)
```

See [AUTHENTICATION.md](AUTHENTICATION.md) for the full secstore/factotum architecture
and threat model.

## Boot Sequence

The GUI boots with `sh -l /lib/lucifer/boot.sh`. The login shell runs
`lib/sh/profile` first, then `boot.sh`:

```
lib/sh/profile:
1. secstored starts (tcp!127.0.0.1!5356)
2. factotum starts (with secstore backing if $SECSTORE_PASSWORD set, otherwise empty)
3. llmsrv starts, or a remote /mnt/llm is mounted (per /lib/ndb/llm); speech9p starts
lib/lucifer/boot.sh:
4. wm/logon displays login screen (skipped when $skiplogon=1)
   - First boot: password + confirmation → creates secstore account
   - Normal boot: password → PAK auth → keys loaded into factotum
   - Skip: continue without secstore
5. lib/lucifer/llmsrv.sh (re-)starts the LLM service in the background
6. wallet9p, msg9p (/mnt/msg, with the sms and, if configured, email sources)
7. luciuisrv (/mnt/ui), activity "Main", tools9p (/tool)
8. lucibridge -a 0 (starts veltrosrv for activity 0)
9. plumber (/lib/lucifer/plumbing), then lucifer
```

---

## Components

### llmsrv (native Limbo LLM service)

- Source: `appl/cmd/llmsrv.b`; runs inside Inferno emulator
- Presents LLM providers (Anthropic API or Ollama/OpenAI-compatible) as a 9P file server
- Self-mounts at `/mnt/llm`; can also be accessed remotely via 9P dial+mount
- Session lifecycle: clone from `/mnt/llm/new` → session directory `/mnt/llm/{id}/`
- Reading `new` returns an unguessable session token; the session directory is named by
  it and is not listed in the root (INFR-321). The root also has `models`.
- Files per session: `ask` (write prompt → read response), `stream`, `model`,
  `temperature`, `system`, `thinking`, `prefill`, `tools` (write tool schemas),
  `context` (conversation history), `compact`, `ctl` (`reset` or `close`), `usage`,
  `maxtokens`, `reasoning`
- Response format: `STOP:tool_use\nTOOL:<id>:<name>:<args>` or `STOP:end_turn\n<text>`
- Native `tool_use` protocol: LLM receives proper JSON tool schemas, returns structured tool calls

### tools9p (`appl/veltro/tools9p.b`)

A harness component: the shared configuration and execution server that running agents
dispatch tool calls through. The GUI (lucictx), lucibridge and veltrosrv all use it.

Filesystem layout at `/tool`:

```
/tool/
├── tools       (r)   Newline-separated list of currently active tool names
├── grantable   (r)   Tools this agent may delegate, with summaries
├── help        (rw)  Write tool name → read documentation
├── ctl         (rw)  Control: add/remove tools; bindpath/unbindpath paths
├── provision   (rw)  Child-task provisioning (narrowing only; present with the task tool)
├── paths       (r)   Newline-separated list of registered namespace paths
├── budget      (r)   Delegation budget: tools that may be handed to child tasks (-b)
├── activity    (r)   Activity identifier
├── _registry   (r)   Space-separated list of tool names (for spawn validation)
├── meta/       (dir) Audit metadata scalars
└── <name>/     (dir) Per-tool directory: ctl and run (write args → blocking execute →
                      read result), doc, schema
```

The same tree is also bound at `/mnt/toolctl` (`/mnt/toolctl.N` for `/tool.N`).
Trusted clients (lucictx, lucibridge, veltrosrv) write control commands to
`/mnt/toolctl/ctl`; agent namespaces do not contain it.

Key design properties:
- **Pre-loads all tool modules before namespace restriction** — allows `ctl add` without
  needing access to `/dis/veltro/tools/`
- **Async tool execution** — `asyncexec()` runs tool in a spawned goroutine; the write()
  call blocks until complete but the serveloop remains responsive to other 9P traffic
- **Shared server** — tools9p runs in its own Inferno thread and is mounted in the shell's
  namespace; lucictx, lucibridge and the veltrosrv it starts inherit `/tool` from there

### veltrosrv (`appl/veltro/veltrosrv.b`)

The agent harness, served as files at `/mnt/veltro` (see `man/4/veltrosrv`). It runs the
agent loop (model at `/mnt/llm`, tools at `/tool`); every front end is a client of its
files: `veltro` on the command line, lucibridge for Lucia, Xenith's `Agent` window
(`appl/xenith/xenith/agent/Agent.b`), or a shell.

```
/mnt/veltro/
├── new              read: start a session; returns its id
└── <id>/
    ├── ctl          cancel | reset | close | persona | role | brief | model | think |
    │                maxsteps | gate on|off
    ├── input        write one user message; starts a turn
    ├── text         the conversation as the user sees it
    ├── log          the trajectory, one line per event
    ├── status       idle | working | blocked | <tool>
    └── approve      gated calls: read "<callid> <tool> <args>", write allow|deny <callid>
```

- The serving process forks its namespace and applies `nsconstruct->restrictns()` with the
  grants given by `-t` and `-p` before it serves; the mount lands only in the caller's
  namespace, so the agent cannot name its own `ctl` or `approve`
- On each turn: re-reads `/tool/tools` (calls `initsessiontools()` if the set changed) and
  `/tool/paths` (rebuilds the system prompt if the paths changed)

### lucibridge (`appl/cmd/lucibridge.b`)

Lucia's client of the agent harness.

- Started in the background by `lib/lucifer/boot.sh` (`lucibridge -a 0`)
- Starts a veltrosrv with the activity's grants, mounted at `/mnt/veltro` in its namespace
- Reads user input from `/mnt/ui/activity/{id}/conversation/input` and writes it to the
  session's `input`
- Renders the agent's text, tool activity and approval requests back into the UI via
  `/mnt/ui/activity/{id}/conversation/ctl` and the context zone
- `applypathchanges()` reflects `/tool/paths` into the context zone

### luciuisrv (`appl/cmd/luciuisrv.b`)

GUI state server — a 9P file server for the three-zone Lucia UI.

Mounted at `/mnt/ui`. Presents conversation messages, presentation artifacts, and context
zone state as a filesystem. No draw/display dependency — fully testable headless.

```
/mnt/ui/
├── ctl                           Global control
├── event                         Global event stream
├── catalog/                      Resource catalog (from /lib/veltro/resources/*.resource)
└── activity/{id}/
      ├── label                   Activity name
      ├── status                  idle / working / error
      ├── event                   Per-activity event stream
      ├── conversation/
      │     ├── ctl               Write messages / update streaming token
      │     ├── input             Blocking read: next user message
      │     └── {N}               Indexed message files
      ├── presentation/
      │     ├── ctl               Create / update / append / center artifacts
      │     ├── current           ID of centered artifact
      │     └── {id}/             Per-artifact directory
      │           ├── type        text / markdown / pdf / diagram
      │           ├── label       Display label
      │           └── data        Artifact content
      └── context/
            ├── ctl               Add resources / gaps / bg tasks
            ├── resources/{N}     Context resources
            ├── gaps/{N}          Knowledge gaps
            └── background/{N}    Background tasks
```

### Veltro (`appl/veltro/veltro.b`)

CLI agent: `veltro [-v] [-t] [-y] [-a type] [-m model] [-p paths] <task>`, or `-r <name>`
to resume a saved session.

A client of veltrosrv: it starts the harness with the grants given on the command line,
writes the task to the session's `input`, prints the agent's text as it arrives, and
answers approval requests on the terminal. It also does the planning turn for a complex
task, intent routing to a persona, and session storage under
`/usr/inferno/veltro/sessions`.

### nsconstruct (`appl/veltro/nsconstruct.b`)

Namespace restriction engine (`module/nsconstruct.m`), called by tools9p and veltrosrv.

Policy applied after `FORKNS`:
- `/dis` → reduced to `lib/`, `veltro/` (+ `sh.dis` if `exec` tool active)
- `/dis/veltro/tools/` → only registered tool `.dis` files visible
- `/dev` → reduced to `cons`, `null`, `time`
- `/n` → capability-gated foreign imports: `/n/speech` only if in `caps.paths` (`/mnt/git` is derived only for the fixed `git` tool — migrated from `/n/git`, INFR-401)
- `/tmp` → writable only at `/tmp/veltro/scratch/`

### wallet9p (`appl/veltro/wallet9p.b`)

Cryptocurrency wallet exposed as a 9P file server at `/n/wallet/`.

```
/n/wallet/
├── ctl              rw   "network <name>", "default <name>", "rpc <url>"
├── accounts         r    newline-separated account names
├── new              rw   write: "eth chain name" or "import eth chain name hexkey"
└── {name}/
    ├── address      r    public address (EIP-55 checksummed)
    ├── balance      r    live balance from blockchain RPC
    ├── chain        rw   chain name
    ├── pay          rw   write: "amount recipient" → read: pending:id
    ├── authorize    rw   write: structured x402/EIP-3009 request → read: pending:id
    ├── ctl          rw   "budget maxpertx maxpersess currency",
    │                     "gasbudget maxpertx maxpersess", "requireapproval on"
    └── history      r    recent transactions
```

Key design properties:
- **Factotum-backed** — private keys stored in factotum (`service=wallet-eth-{name}`),
  never in wallet9p's memory long-term. Keys are fetched per operation and zeroed.
- **Secstore persistence** — new accounts trigger factotum sync to secstore (async).
  Keys survive emu restart.
- **Budget + mandatory approval enforcement** — server-side; every execution path checks the
  account budget, and payments always queue for trusted approval. There is no
  raw signing file: agents submit structured `pay`/`authorize` requests that
  wallet9p constructs, policy-checks, and signs itself.
- **Namespace-gated** — agents need `"/n/wallet"` in `caps.paths` to access.
  `/mnt/llm` is also capability-driven: top-level loops grant it when they open
  model sessions by path, while subagents normally use pre-opened descriptors.
- **Multi-network** — supports Ethereum Mainnet, Sepolia, Base, Base Sepolia with
  per-network RPC endpoints and USDC contract addresses.

### editor (`appl/wm/editor.b`)

Built-in text editor with 9P IPC for agent integration. Mounts at `/edit/`.

```
/edit/
├── ctl              rw   open <path>, new, quit
├── index            r    list of open document IDs
└── {id}/
    ├── body         rw   document text
    ├── ctl          rw   save, saveas, goto, find, insert, delete, replace, replaceall
    ├── addr         rw   cursor position ("line col")
    └── event        r    blocking read for events (modified, opened, quit)
```

The Veltro `editor` tool uses this IPC to let agents read, navigate, and modify open
documents without needing direct Draw access.

### Lucia GUI (`appl/cmd/lucifer.b`)

Three-zone window: Conversation | Presentation | Context.

`luciuisrv`, `tools9p` and `lucibridge` are started by `lib/lucifer/boot.sh` before
lucifer, which loads the zone renderers:
1. `luciconv` — the conversation zone
2. `lucipres` — the presentation zone (a wmclient app)
3. `lucictx` — the context zone (tool toggles, namespace browser)

Additional features:
- **Live theme sync** — theme changes propagate to all running apps in real time
- **HiDPI fonts** — antialiased combined fonts for Retina/HiDPI displays
- **App slots** — up to 48 GUI apps (wallet, editor, fractals, etc.) in the presentation zone
- **Activity tracking** — per-activity event streams, status indicators, tool-call tiles

---

## Data Flows

### User sends a message

```
User types in Conversation zone
  → lucifer writes to /mnt/ui/activity/{id}/conversation/ctl
  → luciuisrv stores message, fires "conversation N" event
  → lucifer re-renders conversation zone
  → lucibridge (blocking read on /conversation/input) receives message
  → lucibridge writes it to /mnt/veltro/<id>/input
  → veltrosrv re-reads /tool/tools, /tool/paths
  → veltrosrv calls LLM via /mnt/llm/<session>/ask
  → LLM returns tool_use or end_turn
  → veltrosrv executes tools (writes to /tool/<name>, reads result)
  → lucibridge reads /mnt/veltro/<id>/text and writes it to /mnt/ui conversation/ctl
  → lucifer renders response
```

### User toggles a tool in Context zone

```
User clicks [-] on "diff" in context zone
  → lucictx writes "remove diff" to /mnt/toolctl/ctl
  → tools9p moves diff from active set to alltools
  → /tool/tools no longer lists "diff"
  → On next LLM turn: veltrosrv re-reads /tool/tools, calls initsessiontools()
  → LLM no longer receives diff tool schema
```

### User binds a directory via Context zone browser

```
User browses to /Users/pdfinn/docs, clicks [Bind]
  → lucictx writes "bindpath /Users/pdfinn/docs" to /mnt/toolctl/ctl
  → tools9p adds path to boundpaths list; /tool/paths now lists it
  → lucibridge applypathchanges() shows it in the context zone
  → On next LLM turn: veltrosrv reads /tool/paths and rebuilds the system prompt
```

---

## Namespace Isolation Model

Each agent session has a restricted namespace:

```
Full Inferno namespace (shell, GUI)
  │
  ├── tools9p runs in this namespace (shared)
  └── FORKNS ──► Agent namespace (restricted copy)
                   ├── /mnt/llm          (always)
                   ├── /n/local/<base> (only granted paths)
                   ├── /tool           (inherited, read-only in practice)
                   ├── /dis/veltro/    (tool .dis files only)
                   ├── /dev/cons       (console only)
                   └── /tmp/veltro/scratch/  (only writable area)
```

Subagents (via `spawn` tool) can only NARROW further — they cannot re-grant permissions
their parent didn't have.

---

## Cross-Host

The same stack runs on Linux ARM64 (e.g. Jetson) over ZeroTier (Ed25519 host identity,
Salsa20/Poly1305 link encryption — provided by ZeroTier itself, independent of Inferno).
9P mounts work cross-host: the remote Inferno namespace is accessible locally via
`mount -A tcp!<host>!<port> /n/remote`. Cross-host secstore/factotum behaviour is
documented in [DISTRIBUTED-AUTH.md](DISTRIBUTED-AUTH.md).

---

## Key Files

| Component | Source | Compiled |
|-----------|--------|----------|
| tools9p | `appl/veltro/tools9p.b` | `dis/veltro/tools9p.dis` |
| lucibridge | `appl/cmd/lucibridge.b` | `dis/lucibridge.dis` |
| lucictx | `appl/cmd/lucictx.b` | `dis/lucictx.dis` |
| lucifer | `appl/cmd/lucifer.b` | `dis/lucifer.dis` |
| luciuisrv | `appl/cmd/luciuisrv.b` | `dis/luciuisrv.dis` |
| lucitheme | `appl/lib/lucitheme.b` | `dis/lib/lucitheme.dis` |
| veltro | `appl/veltro/veltro.b` | `dis/veltro/veltro.dis` |
| veltrosrv | `appl/veltro/veltrosrv.b` | `dis/veltro/veltrosrv.dis` |
| nsconstruct | `appl/veltro/nsconstruct.b` | `dis/veltro/nsconstruct.dis` |
| agentlib | `appl/veltro/agentlib.b` | `dis/veltro/agentlib.dis` |
| llmsrv | `appl/cmd/llmsrv.b` | `dis/llmsrv.dis` |
| wallet9p | `appl/veltro/wallet9p.b` | `dis/veltro/wallet9p.dis` |
| factotum | `appl/cmd/auth/factotum/factotum.b` | `dis/auth/factotum.dis` |
| secstored | `appl/cmd/auth/secstored.b` | `dis/auth/secstored.dis` |
| logon | `appl/wm/logon.b` | `dis/wm/logon.dis` |
| editor | `appl/wm/editor.b` | `dis/wm/editor.dis` |
