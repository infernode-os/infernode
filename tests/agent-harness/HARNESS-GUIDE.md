# Building a harness against the gateway

> **TESTING ONLY** — see [README.md](README.md) for the ring-fence rule.
> For the 9P contract this guide references, see [PROTOCOL.md](PROTOCOL.md).

This is practitioner-level guidance: how to build the external eval
harness as a 9P client of the gateway. Examples are in Python-flavoured
pseudocode for clarity — the actual implementation language is the
harness author's call.

## Scenario lifecycle

A "scenario" is one eval — a task (possibly multi-turn), pass/fail
predicates, and a model selection. The harness's per-scenario loop:

```text
1. Prepare workspace fixture (copy initial files into $ROOT/workspace/<id>/)
2. Start gateway: ./tests/agent-harness/serve-agent.sh  (or assume running)
3. Mount /n/ui and /n/llm via 9P
4. Open /n/ui/event watcher (long-lived fd)
5. Snapshot baseline state:
     - /n/llm/ session ids in existence
     - /usr/inferno/veltro/sessions/ contents
     - /usr/inferno/veltro/subagents/ contents
6. For each turn:
     a. Write turn-prompt to /n/ui/activity/0/conversation/input
     b. Wait for completion (poll /n/ui/activity/0/status, or watch output)
     c. Collect new artefacts since last snapshot
7. Bundle artefacts (transcripts + logs + workspace diff + metrics)
8. Send bundle to judge LLM, record verdict
9. Teardown: archive child activities, clear workspace, optionally
    restart gateway
```

Step 2 is one-time per harness session if you run multiple scenarios
back-to-back; cold-starting per scenario is acceptable when the model
count is small.

## Mounting

```python
import subprocess, os
KEY = os.path.expanduser("~/.infernode/lib/keyring/serve-llm")

# Inferno-native: mount via a thin emu wrapper.
subprocess.check_call([
    "emu", "-c1", "-r.", "sh", "-c",
    f"bind -a '#I' /net; mount -ac {{mntgen}} /n; "
    f"mount -k {KEY} tcp!127.0.0.1!5641 /n/ui; "
    f"mount -k {KEY} tcp!127.0.0.1!5640 /n/llm"
])
```

In practice, a Python 9P client (`py9p`, or a homebrew Styx implementation
— 9P2000 is small) is cleaner than shelling out to emu for every read.
The choice is left to the harness author; the protocol is the same.

## The activity-tree watcher

`/n/ui/event` is line-oriented and blocking. Open it once at scenario
start and consume in a worker thread (or async task):

```python
def watch_events(event_fd, on_event):
    """Block reading lines from /n/ui/event, dispatching each."""
    buf = b""
    while True:
        chunk = os.read(event_fd, 4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            on_event(line.decode().strip())

def on_event(line):
    if line.startswith("activity new "):
        rest = line[len("activity new "):].split(maxsplit=1)
        new_id = int(rest[0])
        label = rest[1] if len(rest) > 1 else ""
        subscribe_to_activity(new_id, label)
    elif line.startswith("activity delete "):
        teardown_activity(int(line.split()[2]))
    elif line.startswith("activity status "):
        _, _, id_str, status = line.split(maxsplit=3)
        update_activity_status(int(id_str), status)
```

Reference implementation in Limbo: `appl/veltro/taskboard9p.b:194+`
(`taskboard9p` is itself a 9P client of `/n/ui/event` for the desktop
taskbar widget). Crib its logic.

## Driving a conversation

### Single-turn task

```python
def send_turn(activity_id, prompt):
    """Write a user message to an activity; lucibridge picks it up."""
    path = f"/n/ui/activity/{activity_id}/conversation/input"
    open(path, "wb").write(prompt.encode())

def wait_until_idle(activity_id, timeout_s=300):
    """Poll status until it returns to 'idle' (turn complete)."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        status = open(f"/n/ui/activity/{activity_id}/status").read().strip()
        if status == "idle":
            return
        time.sleep(0.5)
    raise TimeoutError(f"activity {activity_id} did not idle within {timeout_s}s")
```

> Exact status-string semantics are defined by `lucibridge.b` — read
> the source for the full lifecycle. `idle` is the post-turn rest
> state; `live` means an LLM call is in flight.

### Multi-turn (continuous-state)

Just keep writing to `conversation/input`. The activity preserves all
its state — Veltro session log, LLM session context, workspace,
spawned subagents. No restart between turns:

```python
for turn in scenario["turns"]:
    send_turn(0, turn["prompt"])
    wait_until_idle(0, timeout_s=turn.get("budget_s", 300))
    capture_turn_artefacts(turn_idx=turn["idx"])
```

For long scenarios, the harness should also poll `/n/llm/<sid>/usage`
to detect context exhaustion; lucibridge auto-compacts via
`/n/llm/<sid>/compact` when usage approaches the limit, but the harness
should track this for grading (a scenario that needed compaction is
different from one that didn't).

## Per-activity LLM session correlation

Lucibridge doesn't publish the mapping `activity → llm session id`
anywhere. The harness derives it via timing:

```python
def snapshot_llm_sessions():
    """Return the set of active session ids."""
    # /n/llm/ contains one subdir per active session (named "0", "1", ...).
    return {name for name in os.listdir("/n/llm") if name.isdigit()}

# Before spawning a child:
before = snapshot_llm_sessions()

# Trigger delegation (write to A0 input). Wait for the event.
send_turn(0, "delegate task X to a coder agent")
new_act = wait_for_event("activity new ", timeout_s=30)

# The new llm session is the diff.
after = snapshot_llm_sessions()
new_sessions = after - before
assert len(new_sessions) == 1  # in most cases
activity_to_llm[new_act.id] = next(iter(new_sessions))
```

Edge cases the harness should handle:
- Multiple sessions can appear if A0's tool calls (e.g. `task create`)
  also clone a session under the hood. Take the most-recently-created
  (highest numeric id) when in doubt.
- A scheduled `spawn` may clone a session well after the `spawn`
  tool call. The mapping is then `subagent log → session id`, harder
  to derive — phase 2 telemetry would help here.

## Capturing artefacts

Per-turn capture, written to `results/<run_id>/<scenario>/<model>/turn_<n>/`:

| File | Source |
|---|---|
| `prompt.txt` | The turn prompt the harness sent. |
| `transcripts/activity_<N>.txt` | Snapshot of `/n/ui/activity/<N>/conversation/output` (full, untruncated). |
| `veltro_logs/<session>.log` | Copy of `/usr/inferno/veltro/sessions/<session>/log`. |
| `subagent_logs/<batch_ms>.<idx>.log` | Copy of any new files in `/usr/inferno/veltro/subagents/` since last turn. |
| `usage.json` | `{activity_id: token_count}` from `/n/llm/<sid>/usage` for each known session. |
| `workspace.diff` | Diff of `$ROOT/workspace/<id>/` between turn start and turn end. |
| `wall_clock_ms` | Harness-measured turn duration. |
| `events.jsonl` | `/n/ui/event` lines that arrived during this turn. |

Per-scenario aggregation, in `results/<run_id>/<scenario>/<model>/`:

| File | Source |
|---|---|
| `metrics.json` | Run-level summary: total tokens, total wall clock, turn count, peak activity tree size, subagent count, exit reason. |
| `grade.json` | Judge verdict (rubric scores, failure mode, reasoning). |
| `metadata.json` | Harness commit SHA, scenario commit SHA, judge model + temp, gateway version, model name. |

The metadata file pays off in month 2 — when a regression appears,
it tells you whether the agent got worse or the rubric got stricter.

## LLM-as-judge

Bundle composition matters more than the judge model:

```python
def build_judge_prompt(scenario, captured):
    return f"""You are evaluating an agent's performance on a task.

# Task (given to the agent)
{scenario['task']}

# Reference solution (if any)
{scenario.get('reference', 'N/A')}

# What the agent did

## Activity tree
{render_tree(captured['events'])}

## Per-activity conversation transcripts
{render_transcripts(captured['transcripts'])}

## Tool-call trajectory (from Veltro session logs)
{render_trajectory(captured['veltro_logs'], captured['subagent_logs'])}

## Workspace changes
```diff
{captured['workspace.diff']}
```

## Cost
- {captured['total_tokens']} tokens total
- {captured['wall_clock_ms']/1000:.1f}s wall clock
- {captured['subagent_count']} subagents spawned

# Rubric
Score each axis 0–3, then give a one-line failure_mode if any score < 3.
Return STRICT JSON only:

{{
  "correctness": 0-3,    # Did the agent complete the task as specified?
  "efficiency": 0-3,     # Was the trajectory reasonable, or wasteful?
  "tool_use": 0-3,       # Were tools used appropriately?
  "failure_mode": "..."  # Short tag if anything scored < 3, else ""
}}
"""
```

Two recommendations:

1. **Pin the judge** (model + temperature=0) and version the rubric.
   When the rubric changes, recompute all scores rather than letting
   old verdicts linger.
2. **Persist the raw bundle.** The grade is a derived artefact; the
   bundle is the source of truth. If you decide to switch judge models
   or tighten the rubric in three months, you re-grade from the bundle,
   not from a re-run (which is non-deterministic anyway).

## Teardown between scenarios

Within one harness session (gateway already running):

```python
def teardown_scenario():
    # Delete all child activities (anything > 0).
    info = open("/n/ui/ctl").read()
    for line in info.splitlines():
        if line.startswith("activities:"):
            ids = [int(x) for x in line.split()[1:] if x.isdigit()]
            for aid in ids:
                if aid == 0:
                    continue
                open("/n/ui/ctl", "wb").write(f"activity delete {aid}".encode())

    # Clear A0's conversation.
    open("/n/ui/activity/0/conversation/ctl", "wb").write(b"clear")

    # Close any LLM sessions we mapped.
    for sid in activity_to_llm.values():
        open(f"/n/llm/{sid}/ctl", "wb").write(b"close")

    # Reset workspace.
    shutil.rmtree(f"{ROOT}/workspace/{scenario_id}", ignore_errors=True)
```

For cross-model runs in the same scenario, prefer **restarting the
gateway** between models so the LLM session and workspace state are
fully fresh. The cold-start cost is acceptable when the model count
is small (≤ 2 per eval cycle per the design).

## Common pitfalls

- **Confusing activity-tree spawning (`task`) with subagent spawning
  (`spawn`).** `task` creates a new top-level activity with its own
  lucibridge — visible in `/n/ui`. `spawn` runs sub-loops inside an
  existing activity — invisible in `/n/ui`, only the log file is
  observable.
- **Treating the 200-char-truncated log as the source of truth for
  output content.** The log is for trajectory grading. For "did it
  write the right code" grading, use the workspace diff.
- **Reading `/n/ui/event` non-blockingly.** It's a streaming file;
  the protocol is read-blocks-until-next-event. The harness needs
  a dedicated reader.
- **Polling too aggressively.** `/n/ui/activity/<N>/status` returns
  fast but lucibridge writes to it on state transitions. 500ms poll
  is plenty.
- **Assuming `ls /n/ui/activity/` enumerates children.** It hangs.
  Get ids from `/n/ui/ctl` or `/n/ui/event` and walk explicit paths.
- **Not closing LLM sessions.** They linger until server restart.
  Long harness runs without `close` exhaust llmsrv's session table.
- **emu not exiting cleanly after the harness signals shutdown.**
  The harness should `kill` the gateway pid, not rely on graceful
  exit.

## Phase 2 telemetry (when the time comes)

The current protocol gives the harness enough to grade outcomes
("did the task get done"). For grading **process** ("how efficiently /
elegantly was it done"), some telemetry gaps will start to bite:

- Per-turn token cost (currently only running total in `/usr/usage`).
- Per-turn wall clock latency (currently only end-to-end at harness).
- Per-tool-call latency (currently nothing).
- LLM-call trace (currently `llmsrv -D` writes to stderr, not a file).
- Decision-to-tool latency vs tool-execution latency split.

The simplest extension is a per-session `events.jsonl` written by
llmsrv, one line per `Tmsg.Write` to `/ask`/`stream` with a timestamp,
token count, and elapsed-since-last-msg. If/when the harness needs
this, that's the right shape — additive, easy to ignore if you
don't care.
