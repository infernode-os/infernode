# Agent harness 9P protocol reference

> **TESTING ONLY** — see [README.md](README.md) for the ring-fence rule.

This is the contract between the gateway (`serve-agent.sh` running an emu
on the host) and the external harness (any 9P client). Everything the
harness needs to drive an InferNode agent stack and observe its behaviour
is described here. Where a behaviour is best understood by reading the
implementation, the file and (where stable) line range is named.

## Surfaces

| Mount | Port | Provided by | Source |
|---|---|---|---|
| `/n/ui` | `tcp!127.0.0.1!5641` | `luciuisrv` | `appl/cmd/luciuisrv.b` |
| `/n/llm` | `tcp!127.0.0.1!5640` | `llmsrv` | `appl/cmd/llmsrv.b` |

Auth: Inferno Ed25519 keyring. Same keyfile at
`~/.infernode/lib/keyring/serve-llm` authenticates both.

## `/n/ui` — activity / conversation surface

### Top-level

| Path | Mode | Semantics |
|---|---|---|
| `/n/ui/ctl` | r/w | Write commands (see below). Read returns `activities: <id1> <id2> ...\ncurrent: <id>\n`. The last id in `activities:` is the most-recently-created. |
| `/n/ui/event` | r | Streaming event log. One line per event. Reads block until the next event. The harness should `open` this with a long-lived fd and `read` repeatedly. |
| `/n/ui/activity/` | dir | Directory of all live activities (one subdir per id). |

> **Caveat:** `ls /n/ui` against the luciuisrv synthetic tree hangs in
> practice. Walk by explicit path — the harness should always know
> which activity ids it cares about (from `/n/ui/ctl` or `/n/ui/event`).
> Do not rely on directory enumeration.

### `/n/ui/ctl` write commands

| Command | Effect |
|---|---|
| `activity create <label>` | Create new activity, auto-assigned id. Reply via reading `/n/ui/ctl` (id appears at the end of the `activities:` line). |
| `activity delete <id>` | Archive activity. Cannot delete activity 0 (meta-agent). |
| `activity <id>` | Switch the `current:` field to `<id>` (UI-driven; not usually relevant to a harness). |

Source: `appl/cmd/lucibridge.b`, `appl/veltro/tools/task.b:docreate`,
`appl/veltro/taskboard9p.b:404+`.

### `/n/ui/event` line format

The event stream is line-oriented; each line is space-separated. Relevant
prefixes:

| Line | Meaning |
|---|---|
| `activity new <id> <label>` | New activity created. |
| `activity delete <id>` | Activity archived. |
| `activity <id>` | UI switched to activity `<id>` (active focus). |
| `activity urgency <id> <0\|1\|2>` | Urgency change. |
| `activity status <id> <status>` | Status field changed. |

`taskboard9p.b:194+` is the canonical event-consumer reference. Crib
its logic when building the harness's watcher.

### Per-activity paths

For each live activity `N`:

| Path | Mode | Semantics |
|---|---|---|
| `…/activity/<N>/label` | r | Short label (e.g. `Main`). |
| `…/activity/<N>/status` | r/w | Activity status (`live`, `idle`, `done`, custom). Read for completion-poll. |
| `…/activity/<N>/urgency` | r/w | `0`/`1`/`2`. |
| `…/activity/<N>/conversation/input` | w | **Write user/harness messages here.** lucibridge picks them up and runs the agent loop. |
| `…/activity/<N>/conversation/output` | r | Streaming conversation transcript. role=user (harness), role=veltro (agent). |
| `…/activity/<N>/conversation/ctl` | r/w | Conversation control (clear, set role, etc. — see `lucibridge.b:283+`). |
| `…/activity/<N>/context/ctl` | w | Context plane. Used by `spawn.b` for `bg add/update/remove`. |
| `…/activity/<N>/presentation/ctl` | w | UI presentation (taskboard widgets etc.). Not usually harness-relevant. |

`lucibridge.b` is the reference reader; lines 188 (`context/ctl`), 281
(`conversation/ctl`), 339 (`conversation/input`), 524 (`status`),
530 (`urgency`).

## `/n/llm` — LLM session gateway

Sessions are created via the clone pattern.

### Top-level

| Path | Mode | Semantics |
|---|---|---|
| `/n/llm/new` | r | Read returns a new session id as a decimal string (trailing newline). |
| `/n/llm/<id>/` | dir | Per-session control plane. |

### Per-session paths

| Path | Mode | Semantics |
|---|---|---|
| `…/<id>/ask` | r/w | Write a user message, read the response. Same fd is used (clone pattern). Blocks until the LLM responds. |
| `…/<id>/stream` | r/w | Streaming variant: response arrives in chunks. |
| `…/<id>/model` | r/w | Read current model name. Write to switch model mid-session (verified, INFR-4 closed). Allowed names: `gpt-oss`, `daedalus`, `haiku`, `sonnet`, `opus` (see `appl/veltro/tools/task.b:72`). |
| `…/<id>/usage` | r | Read returns `<estimated_tokens>/<context_limit>`. Running total, not per-turn. |
| `…/<id>/thinking` | w | Write thinking budget: `off`, `max`, or a token count (`0`–`30000`). |
| `…/<id>/system` | w | Write the system prompt. |
| `…/<id>/tools` | w | Write tool definitions (used by lucibridge to install the activity's tool slice — `agentlib.b:887`). |
| `…/<id>/compact` | r | Read to trigger context compaction. |
| `…/<id>/ctl` | w | Write `close` to release the session early. Without this, the session lingers until server restart. |

Source: `appl/cmd/llmsrv.b`, `appl/veltro/agentlib.b`.

> **Activity ↔ LLM session correlation is implicit.** Lucibridge clones
> a session at startup, stores the id locally, never re-publishes it. To
> map "activity N → llm session id X", the harness uses timing: snapshot
> `/n/llm` before delegation, read `/n/ui/event` for `activity new N`,
> snapshot again — the new session id is the one for activity N. See
> [HARNESS-GUIDE.md](HARNESS-GUIDE.md#per-activity-llm-session-correlation).

## Out-of-band state (not 9P)

Several useful artefacts live on the emu filesystem rather than in a
9P export. The harness reads them via the host filesystem at
`<ROOT>/<inferno-path>` (since emu was invoked with `-r$ROOT`).

| Path | Written by | Purpose |
|---|---|---|
| `/usr/inferno/veltro/sessions/<name>/log` | `veltro.b:appendlog` | Main agent trajectory. One line per step: `step %d: %s %s -> %s\n`. Args + results truncated to 200 chars. |
| `/usr/inferno/veltro/sessions/<name>/todo.txt` | Veltro's todo plane | Persistent task state for a session. |
| `/usr/inferno/veltro/subagents/<batch_ms>.<idx>.log` | `subagent.b` via `spawn.b` | Subagent trajectory log (one file per child). Header line `# subagent task=…`, step lines, footer `# end status=<done\|max-steps> steps=N total_ms=M`. |
| `/tmp/veltro/brief.<id>` | `task.b:281` | The brief A0 gave A`<id>` (full text, not truncated). |
| `/tmp/veltro/instructions.<id>` | `task.b:293` | Structured instructions for A`<id>`. |
| `/tmp/veltro/model.<id>` | `task.b:309` | Model selection for A`<id>` (lucibridge reads this at startup to pick the LLM). |
| `/tmp/veltro/agenttype.<id>` | `task.b:319` | Agent prompt type (e.g. `coder`). |

For "what got written" grading, prefer the workspace `diff` over the
session log — the log is 200-char-truncated and the workspace is not.

## Activity tree growth: the `task` tool

When A0's LLM calls the `task` tool to delegate:

```
task create label=<name> [tools=<csv>] [paths=<csv>] [model=<m>]
            [agenttype=<t>] [brief=<text>] [instructions=<text>]
            [urgency=0|1|2]
```

The sequence (`appl/veltro/tools/task.b:docreate`):

1. Writes `activity create <label>` to `/n/ui/ctl`.
2. Reads `/n/ui/ctl` back to find the newly-assigned id.
3. Writes `brief` / `instructions` / `model` / `agenttype` to
   `/tmp/veltro/<key>.<id>`.
4. Writes `provision <id> tools=<csv> paths=<csv>` to `/tool/provision`
   (which is the parent tools9p instance — it spawns a child lucibridge
   for the new activity with the restricted tool slice).
5. Returns `created activity <id>: <label>` to A0.

What the harness observes:

- `/n/ui/event` emits `activity new <id> <label>`.
- `/n/ui/activity/<id>/label`, `…/status`, `…/conversation/{input,output}`
  all populate.
- A new `/n/llm/<sid>/` session appears for the child's lucibridge.

## Subagent spawning: the `spawn` tool

`spawn` is the parallel-subagent tool, distinct from `task`. Syntax
(v4, breaking change from v3):

```
Spawn [timeout=N] -- tools=<t> paths=<p> [model=M] [agenttype=T] :: <task>
                  -- tools=<t2> paths=<p2> :: <task2>
                  ...
```

Each `--` section is one subagent (max 5). The `::` separator between
spec and task is **required** in every section. Each subagent runs
inside `FORKNS + bind-replace` namespace restriction with its own
LLM session (clone of `/n/llm/new`) and its own tool slice.

Subagents are **not** visible in `/n/ui` (they're inside an activity,
not a new activity). Their trajectory lands at:

```
/usr/inferno/veltro/subagents/<batch_ms>.<idx>.log
```

where `<batch_ms>` is the wall-clock millisecond when spawn was called
and `<idx>` is the subagent index within that batch (0..N-1). Spawn
parameters (`at=` for scheduled, `every=` for recurring loops) are
detailed in `appl/veltro/tools/spawn.b:doc()`.

## Known caveats

- `ls /n/ui` hangs against the synthetic tree. Walk explicit paths.
- `/n/llm/<id>/usage` is a running total, not per-turn. Per-turn token
  cost requires phase-2 telemetry changes to llmsrv.
- Veltro session log truncates args+results to 200 chars per step.
  Subagent log applies the same truncation.
- emu does not exit cleanly when the main script returns — kernel
  threads keep it alive. The harness should kill the gateway process
  on teardown rather than expecting it to terminate.
- Mid-session model switches (writing to `/n/llm/<id>/model`) work,
  but conversation history is preserved — the new model sees what
  the previous one said. For clean A/B comparisons, clone a fresh
  session per model.
