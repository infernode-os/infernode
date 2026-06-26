# Veltro

**Purpose:** User and operator guide for Veltro, InferNode's AI agent system.

> Looking for the security model? See [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md) for the namespace isolation design (FORKNS + bind-replace, capability attenuation, three harness entry points). This document covers day-to-day usage.

## What it is

Veltro is a Limbo-native agent harness:

- Talks to an LLM via the **`/mnt/llm`** 9P filesystem (Anthropic Claude or any OpenAI-compatible backend through `llmsrv`).
- Calls **40 tools** via the **`/tool`** 9P filesystem, each tool a separate `.dis` module.
- Runs inside a **restricted namespace** (FORKNS + bind-replace) so an agent only sees the files and capabilities its caller granted.
- Can **spawn subagents** with strictly narrower namespaces (capability attenuation).

Three things the agent sees as files: **the LLM, the tools, the host filesystem**. There is no SDK, no JSON-RPC, no HTTP — everything is read/write on a 9P tree.

## Entry points

| Command   | Form                          | Use for                                                               |
|-----------|-------------------------------|-----------------------------------------------------------------------|
| `veltro`  | one-shot, `veltro "do X"`     | scripted tasks, batch runs, resumable sessions                        |
| `repl`    | interactive                   | iterative work; opens a Xenith window if available, terminal otherwise|
| `spawn`   | inside a tool call            | parallel subagents launched by a parent agent                         |
| `lucibridge` | embedded in Lucia          | the agent loop driving the [Lucia](LUCIA.md) UI                       |

### `veltro` — one-shot

```sh
; veltro "summarise the changes in this branch"
; veltro -t -p $home/proj "refactor the auth module"
; veltro -r last  "now add tests"          # resume the most recent session
; veltro -r work-1 "..."                   # resume a named session
; veltro -v "..."                          # verbose
```

Flags:

- `-v` — verbose tool/LLM logging.
- `-t` — enable extended thinking (8000-token budget).
- `-r name` — resume a persisted session (`last` = most recent).
- `-p paths` — comma-separated host paths to expose under `/n/local/`.
- `-a type` — run as a specialist persona from `lib/veltro/agents/<type>.txt`
  (e.g. `-a research`, `-a verify`), layered on top of the base system prompt.
  See [Agent prompts](#agent-prompts).

Sessions persist to `/usr/inferno/veltro/sessions/`. The hard step cap is 200 (the LLM's `end_turn` is the primary stop condition).

### `repl` — interactive

```sh
; repl
; repl -v
; repl -n 80      # raise per-turn step cap (default 50, max 100)
```

Two modes, picked automatically:

- **Xenith mode** (when `/chan` is available) — a window with **Send · Voice · Clear · Reset · Delete** tag buttons. Voice records via `speech9p` and transcribes with the `hear` tool.
- **Terminal mode** — line-oriented stdin/stdout fallback.

Both establish a persistent LLM session for the duration of the REPL invocation. Each turn injects the current namespace into the system prompt so the agent always knows what tools and paths it actually has.

### `spawn` (subagents)

A parent agent calls the `spawn` tool to launch up to 5 subagents in parallel:

```
Spawn -- tools=read,list :: explore appl/veltro
       -- tools=write,edit :: update the README
```

Each child gets:

- A forked namespace with `bind-replace` restrictions narrower than the parent's.
- Its own LLM session with optional model/temperature/thinking overrides.
- A pre-loaded set of tool modules (no `tools9p` for subagents).
- A 5-minute default timeout.

A child can never exceed the parent's capabilities; it can only narrow them further. See [SECURITY.md §Capability attenuation](../appl/veltro/SECURITY.md).

## Tools

Forty tools live in `appl/veltro/tools/`. Each is a `.dis` module implementing a small interface (`init`, `name`, `doc`, `exec`) defined in [`tool.m`](../appl/veltro/tool.m). Tools are loaded on demand and exposed to the agent through `/tool`.

| Category       | Tools |
|----------------|-------|
| **Files**      | `read`, `write`, `edit`, `list`, `find`, `search`, `grep`, `diff` |
| **Execution**  | `exec`, `shell`, `launch`, `spawn`, `safeexec` |
| **Code**       | `git`, `json`, `vision`, `editor` |
| **Web**        | `webfetch`, `websearch`, `browse`, `charon`, `http` |
| **Comms**      | `say`, `hear` |
| **Persistence**| `memory`, `todo`, `task`, `wiki`, `keyring`, `wallet`, `payfetch` |
| **UI**         | `xenith`, `present`, `gap`, `man`, `fractal`, `plan` |
| **System**     | `mount`, `gpu` |

Run `cat /tool/tools` in a Veltro shell to list whatever tools the running agent actually has — the namespace-restricted view, not the full 40.

## Capabilities and the tool budget

Capabilities are granted at **namespace construction time**, not per call. The `Capabilities` adt in [`nsconstruct.m`](../appl/veltro/nsconstruct.m) names the dimensions:

| Field         | Meaning |
|---------------|---------|
| `tools`       | Which tools to load and expose. |
| `paths`       | Host filesystem dirs surfaced under `/n/local/`. |
| `shellcmds`   | If non-nil, enables `exec` with this allowlist plus `sh.dis`. |
| `llmconfig`   | Per-agent model, temperature, system prompt, thinking budget. |
| `xenith`      | Grant `/chan` (Xenith window access). |
| `memory`      | Enable persistent memory store. |
| `mcproviders` | mc9p providers to spawn (HTTP, fs, search) with domain/network grants. |

When `tools9p` is started, two flags shape what agents see:

```sh
/dis/veltro/tools9p \
  -m /tool \
  -b read,list,find,search,grep,write,edit,...   # delegation budget (max for spawn)
  read list find present say hear ...            # tools loaded for THIS agent
```

- The **positional tools** are loaded for the agent running this `tools9p`.
- The `-b` budget is the **maximum a child can be granted**. Subagents can never exceed it.

The Lucia launch scripts (`run-lucia.sh`, `run-lucia-linux.sh`) show a typical configuration. Edit them to lock down a deployment.

## Agentic behaviour

For multi-step or open-ended work the agent follows a complexity-gated discipline
(`<complex_tasks>` in `system.txt`). Greetings, small talk, and single-action
requests stay light — plain text, no tools, no plan. When a task needs several
steps or covers independent parts, the agent:

1. **Plans first** — records steps with `plan`/`todo` (exactly one in progress).
2. **Decomposes** into the smallest independent sub-tasks.
3. **Delegates** genuinely independent, multi-step sub-tasks in parallel via
   `spawn` (one child each) — fan-out is reserved for work that warrants it, not
   cheap reads.
4. **Synthesizes the result itself** — reads every child's output and writes the
   conclusion; it never just relays "the subagent's findings."

### Intent routing

`system.txt` recognizes the shape of a request and applies the matching
discipline inline: a **research** request (investigate / compare / find out)
gathers from real sources — web (`websearch`+`webfetch`) or codebase
(`find`+`read`) — and cites them; a **verify** request ("does X actually work",
"confirm X") runs the thing and ends with a `VERDICT`. Substantial parallel
research can instead be delegated to `task agenttype=research`.

### Read-cache

To stop the agent burning its step budget re-reading the same file, identical
read-only calls (`read`/`list`/`find`/`search`/`grep` with the same arguments)
are short-circuited within a turn with an "already ran at step N" note instead of
re-executing. A mutating tool (`write`/`edit`/`exec`/…) invalidates the cache, so
`read → edit → read` still re-reads the changed file.

## LLM configuration

LLM state lives at `/mnt/llm`, served by `llmsrv` (`appl/cmd/llmsrv.b`).

```
/mnt/llm/new            # read it to allocate a fresh session id
/mnt/llm/N/ask          # write a user message, read a full response
/mnt/llm/N/stream       # streaming response
/mnt/llm/N/model        # haiku | sonnet | opus  (or any backend-specific id)
/mnt/llm/N/temperature  # 0.0 – 2.0
/mnt/llm/N/thinking     # disabled | max | <integer token budget>
/mnt/llm/N/system       # write-only system prompt
/mnt/llm/N/context      # read current conversation as JSON
/mnt/llm/N/compact      # summarise+truncate to free tokens
```

Default model: **haiku**. Override with the `LLMConfig` field of `Capabilities`, or by writing to `/mnt/llm/N/model` directly.

### Backends

`llmsrv` is started by `lib/sh/profile`. To use a non-Anthropic backend:

```sh
llmsrv -b openai -u https://my-host/v1 -M my-model
```

`-b api` (default) is the Anthropic Claude API; `-b openai` speaks any OpenAI-compatible endpoint (Ollama, vLLM, OpenAI itself).

The host environment variable `ANTHROPIC_API_KEY` is provisioned into factotum by the profile and consumed by `llmsrv` automatically.

## Agent prompts

System prompts and per-type prompts live in `lib/veltro/`:

| File                          | Role |
|-------------------------------|------|
| `lib/veltro/system.txt`       | Default system prompt for `veltro`/`repl`. |
| `lib/veltro/meta.txt`         | "Chief of Staff" prompt used by Lucia: never executes, always delegates via `task`. |
| `lib/veltro/agents/default.txt`  | Subagent baseline. Pre-loaded tools, machine-parseable output, terminate with `DONE`. |
| `lib/veltro/agents/explore.txt`  | Read-only codebase analysis. No speculation; report file paths and dependencies. |
| `lib/veltro/agents/plan.txt`     | Architecture/design only. Never implements. |
| `lib/veltro/agents/task.txt`     | Autonomous task execution; uses `plan`/`todo` for multi-step work. |
| `lib/veltro/agents/secretary.txt`| Message-handling agent; acts on the msg9p notification plane (`/mnt/msg`). See `docs/MESSAGE-INTEGRATION.md`. |
| `lib/veltro/agents/research.txt` | Research agent: decompose → gather sources (web or codebase) → synthesize → cite. Adds source/citation discipline on top of `<complex_tasks>`. |
| `lib/veltro/agents/verify.txt`   | Verification agent: *"reading is not verification — run it."* Reproduces the claim, probes edge cases, emits one `VERDICT: PASS/FAIL/PARTIAL` backed by captured output. |

A persona is **layered on top of `system.txt`**, not a replacement — it keeps the
base policies and environment grounding and adds its specialist discipline. Pick
one three ways:

- `veltro -a <type>` — run the top-level agent as that persona.
- `task create agenttype=<type> brief="…"` — delegate to a child agent of that type.
- `spawn -- agenttype=<type> tools=… :: …` — a parallel subagent of that type.

Custom agents: drop a `.txt` file into `lib/veltro/agents/` and reference it by
name via any of the three. `research` and `verify` are also registered in the
`task` tool with sensible default tool budgets.

## Reminders

`lib/veltro/reminders/` holds short context snippets that are injected into the system prompt when the relevant capability or state is detected:

```
file-modified.txt    git.txt              inferno-shell.txt
plan-mode.txt        security.txt         xenith.txt
```

`agentlib->discovernamespace()` runs at the start of each turn, sees what's mounted, and selects matching reminders. Add a reminder by dropping a new `.txt` file alongside the existing ones — the discovery code picks it up automatically when its trigger condition fires.

## Memory and persistence

Two distinct stores:

- **`memory` tool** — agent-controlled key/value store. `memory save K V`, `memory load K`, `memory list`, `memory clear`. Persists to `/tmp/veltro/memory/{agentid}/`.
- **Sessions** — full conversation transcripts for `veltro`, written to `/usr/inferno/veltro/sessions/`. Resume with `veltro -r name` or `veltro -r last`.

`repl` does **not** persist conversations across REPL restarts; use `veltro` for that.

## Common workflows

### One-shot scripted task

```sh
; veltro "list every TODO in appl/veltro and group by file"
```

### Iterative exploration

```sh
; repl
> walk me through how spawn enforces capability attenuation
> show me where MREPL is used in nsconstruct.b
> are there tests for this?
```

### Parallel delegation

A parent agent issues a single tool call:

```
Spawn -- tools=read,list,grep :: find every place that touches /mnt/llm
       -- tools=read,list,grep :: find every place that touches /mnt/ui
       -- tools=read,list,grep :: find every place that touches /tool
```

The three children run in parallel, each in its own restricted namespace. Results stream back to the parent's conversation.

### Research with citations

```sh
; veltro -a research "compare how the find, spawn and task tools parse their arguments"
```

The research persona decomposes the question, reads each source, synthesizes the
answer, and ends with a `SOURCES` list of the `file:line`/URLs it actually read.

### Verify a claim (run it, don't read it)

```sh
; veltro -a verify "confirm that find returns spawn.b when searching /appl/veltro/tools for spawn"
```

The verify persona *runs* the check, probes edge cases, and ends with a single
`VERDICT: PASS` / `FAIL` / `PARTIAL` backed by the captured output.

### Embedded in Lucia

The Lucia launch scripts wire everything up: `tools9p` with the default budget, `lucibridge` as the agent loop, `speech9p` for voice. See [LUCIA.md](LUCIA.md).

## Hardening checklist

For deployments where untrusted prompts may reach the agent:

1. **Trim the tool budget** — remove `exec`, `shell`, `launch`, `spawn`, `git`, `keyring`, `wallet` from `-b` and the positional tool list in your launch script.
2. **Restrict `-p` paths** — only mount what the agent legitimately needs.
3. **Disable `xenith` and `memory`** in the `Capabilities` you construct.
4. **Pin `llmconfig.model`** so prompt-injected attempts to switch to a more permissive model can't take effect.
5. **Use the `secretary` or a custom prompt** rather than `meta.txt` to avoid Chief-of-Staff delegation patterns.
6. Read [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md) end to end. The namespace model is the security boundary; treat the LLM and its prompt as untrusted.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `cannot load module testing.dis` and friends | Stale `.dis` after `git pull` | `./hooks/install.sh` (once); `mk install` in `appl/cmd` and `appl/veltro` |
| `/mnt/llm: file does not exist` | `llmsrv` not started | Run as `sh -l` so `lib/sh/profile` starts it; check `ANTHROPIC_API_KEY` |
| Agent says it has tool X but `/tool` doesn't list it | Tool not in the positional list of `tools9p` | Add it to the launch script, or rely on `spawn` (subject to `-b` budget) |
| `tools9p` deadlock on the first tool call | Self-mount race during namespace restriction | Already mitigated; if it recurs, check `nsconstruct.b` hasn't been edited to add a `stat()` on the restricted root |
| Subagent times out at 5 minutes | Default `spawn` timeout | Pass `timeout=N` (seconds) in the `spawn` call |
| Memory writes silently lost | Wrong agent id | The `memory` tool keys by sandbox id; confirm with `memory list` |

## See also

- [appl/veltro/SECURITY.md](../appl/veltro/SECURITY.md) — namespace isolation model (the security boundary).
- [appl/veltro/IDEAS.md](../appl/veltro/IDEAS.md) — implemented features and roadmap.
- [LUCIA.md](LUCIA.md) — the GUI driven by `lucibridge`.
- [NAMESPACE.md](NAMESPACE.md) — namespace primitives Veltro builds on.
- [WALLET-AND-PAYMENTS.md](WALLET-AND-PAYMENTS.md) — wallet and x402, used by `wallet` and `payfetch` tools.
- [formal-verification/README.md](../formal-verification/README.md) — TLA+/SPIN/CBMC proofs of namespace isolation.
