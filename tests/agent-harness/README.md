# Agent harness gateway

> **TESTING ONLY — NEVER SHIP IN A RELEASE.**
> CI guards in `.github/workflows/release.yml` and `.github/workflows/ci.yml`
> enforce that nothing under this directory lands in release artefacts or
> moves outside this directory. See [CLAUDE.md](../../CLAUDE.md) for the
> ring-fence rule.

This directory ships the in-tree pieces needed to drive an InferNode
instance from an external evaluation harness. The harness itself lives
in a private repo and talks 9P to two localhost ports.

## Reading order

| Doc | When to read it |
|---|---|
| **This README** | Quick start — what's here, how to run it. |
| [PROTOCOL.md](PROTOCOL.md) | The 9P contract — every path, event, log file the harness can rely on. |
| [HARNESS-GUIDE.md](HARNESS-GUIDE.md) | Practitioner guide — how to actually build a harness against the protocol. Sample flows in pseudocode. |

## Files

| File | Purpose |
|---|---|
| `serve-agent` | Inferno `rc` profile. Mirrors `lib/sh/serve-profile` but also starts `luciuisrv`, `tools9p`, and `lucibridge -a 0`, and exports `/n/ui` alongside `/n/llm`. |
| `serve-agent.sh` | Host launcher. Mirrors `serve-llm.sh`, points emu at `serve-agent`, reuses the same keyfile. |

## What gets exported

Both ports are bound to `127.0.0.1` — the harness is expected to run
on the same host as `emu`.

| Mount | Port | Provided by |
|---|---|---|
| `/n/llm` | `tcp!127.0.0.1!5640` | `llmsrv` (LLM session gateway) |
| `/n/ui` | `tcp!127.0.0.1!5641` | `luciuisrv` (activity / conversation surface) |

Authentication is Inferno Ed25519 keyring auth, same as `serve-llm.sh`.
The keyfile at `~/.infernode/lib/keyring/serve-llm` is shared between
both exports.

## Usage

One-time key generation:

```sh
./serve-llm.sh --gen-key
```

Start the gateway:

```sh
./tests/agent-harness/serve-agent.sh
```

The harness mounts each surface like any 9P client:

```sh
mount -k ~/.infernode/lib/keyring/serve-llm tcp!127.0.0.1!5640 /n/llm
mount -k ~/.infernode/lib/keyring/serve-llm tcp!127.0.0.1!5641 /n/ui
```

Or, for ad-hoc loopback debugging only (no auth):

```sh
./tests/agent-harness/serve-agent.sh --anon-lan
```

## Driving an activity

The meta-agent runs as activity 0. Send a task by writing to its
conversation input:

```sh
echo 'find every .b file under appl that defines a styxservers handler' \
  > /n/ui/activity/0/conversation/input
```

Watch the activity tree grow as the agent delegates:

```sh
cat /n/ui/event   # streams activity new/delete/switch events
```

When activity 0 calls `task create label=… …`, a new lucibridge spawns
for the child activity. Each child has its own conversation streams at
`/n/ui/activity/<N>/...`, its own tool slice at `/tool.<N>`, and its
own LLM session in `/n/llm/<id>`.

## Subagent observability

`spawn` (the parallel-subagent tool, separate from `task`) opens a
per-subagent trajectory log before `FORKNS`. The log fd survives
namespace restriction the same way `llmaskfd` does. Files land at:

```
/usr/inferno/veltro/subagents/<batch_ms>.<idx>.log
```

Format (one line per agent step, matches `veltro.b`'s `appendlog`):

```
# subagent task=<truncated task summary>
step 1: <tool> <args> -> <result>
step 2: <tool> <args> -> <result>
...
# end status=done steps=N total_ms=M
```

Args and results are truncated at 200 chars per step. For richer
"what got written" inspection the harness should diff the workspace
filesystem state, not parse the log.

## What's *not* here

- The harness itself (scoring, judge calls, scenario YAML) — that lives
  in a private repo per the design decision. See [HARNESS-GUIDE.md](HARNESS-GUIDE.md)
  for what the harness needs to do.
- A second keyfile for `/n/ui` — by choice we share the `serve-llm` key.
  If you ever need to separate them, generate two keys and edit
  `SERVE_LLM_KEY` in `serve-agent.sh`.
- A network-reachable export. If you genuinely need remote orchestration,
  change the `tcp!127.0.0.1!` prefixes in `serve-agent`, but be aware
  the keyfile becomes a network-reachable credential.
- Per-turn token and latency telemetry. Phase 1 has running-total token
  count and end-to-end wall clock; phase 2 will likely add per-turn
  signal if the harness needs it. See [HARNESS-GUIDE.md § Phase 2
  telemetry](HARNESS-GUIDE.md#phase-2-telemetry-when-the-time-comes).

## Smoke-test

```sh
./tests/agent-harness/serve-agent.sh &
# wait ~5 seconds for boot
ss -tlnp | grep -E ':5640|:5641'
# Both ports should show LISTEN on 127.0.0.1. From a second emu:
emu -c1 -r. /dis/sh.dis tmp/smoke.rc
```

`tmp/smoke.rc` (Inferno sh):

```rc
load std
bind -a '#I' /net
mount -ac {mntgen} /n
trfs '#U*' /n/local
ghome=/n/local/^`{echo 'echo $HOME' | os sh}
bind -bc $ghome/.infernode/lib/keyring /lib/keyring

mount -k /lib/keyring/serve-llm 'tcp!127.0.0.1!5641' /n/ui
cat /n/ui/ctl                          # expect: "activities: 0\ncurrent: 0"
cat /n/ui/activity/0/label             # expect: "Main"

mount -k /lib/keyring/serve-llm 'tcp!127.0.0.1!5640' /n/llm
cat /n/llm/new                         # expect: a session id (e.g. "1")
```

If those three reads return as expected, the gateway is working
end-to-end and the harness's 9P transport story is validated.
