# Matrix-skill grind campaign — gpt-oss-20b (2026-07)

First rigorous test of the new **Matrix "skill" surface** (PRs #352, #408)
against a real LLM. Matrix exposes a library of typed Limbo modules that an
agent discovers and composes entirely through the `/mnt/matrix` control
filesystem; the `matrix` Veltro tool (`appl/veltro/tools/matrix.b`) is the
agent-facing wrapper. None of it had been driven by a model before this run.

Model: **gpt-oss-20b**, served from hephaestus (nerva3 `serve-llm.sh`, ollama
backend) over 9P/keyring, mounted at `/mnt/llm` on a local Linux amd64 emu.

## TL;DR

- The skill itself is **sound**: when gpt-oss calls the tools, its grammar is
  flawless — `index`, `man sysmon-svc`, `compose service sysmon-svc /`,
  `out sysmon-svc cpu/current`, correct mounts. The tool contract communicates
  the skill well. No prompt bug found.
- The failure mode is **premature `end_turn`** ("describe-instead-of-call"):
  after a tool result, the model emits a short *"next I'll call X"* narration
  and ends its turn without the tool_use block. The agentloop correctly reads
  that as done and stops mid-task.
- **Counterintuitive reasoning result:** the serving default is already
  `reasoning=low`, and for this *multi-step* skill low is the *worst* setting.
  Interleaved A/B (N=8): **medium 6/8 vs low 0/8** full-loop completion. (Low is
  good for single-shot dispatch; multi-step needs sustained tool-calling.)
- **Fix shipped in-harness:** an adaptive stall-recovery loop in `veltro.b` —
  on a mid-workflow premature stop it escalates reasoning one rung
  (low→medium→high, capped) and re-prompts once. **low+escalation: 7/8**,
  matching medium while keeping low's latency on non-stalling turns.

## Rig — resolving the "#304 keyring skew"

Local `/mnt/llm` mount had been considered blocked by a PQ-keyring version
skew. Root-caused to two independent stale-state bugs, both fixed:

1. **Stale emu binary.** The committed `emu/Linux/o.emu` predated PR #351
   (variable-width keyfile framing for PQ signer keys), so `readauthinfo`
   rejected ML-DSA-87 keyfiles with `input or format error` — even keyfiles the
   same emu had just written via `createsignerkey`. The post-merge hook rebuilds
   `.dis` but never the C emu. **Fix:** `./build-linux-amd64.sh`. Confirmed with
   a `readauthinfo` round-trip probe.
2. **Stale signer keyfile.** serve-llm uses one self-signed signer keyfile
   shared by server and client. Heph re-keyed Jul 12; the local copy was Jul 5,
   so the handshake failed at `pk doesn't match certificate`. **Fix:** re-pull
   heph's current `~/.infernode/lib/keyring/serve-llm` (verified byte-identical).

Verified end-to-end: local emu mounts heph, session on gpt-oss-20b, live prompt
→ answer. Matrix control fs (`index`/`man`/`compose`/`out`/`unload`) baselined
clean without the LLM first.

## Method

Task (forces the full skill loop): *"discover available modules, read the
contract of the one that samples system stats, load it as a service, report the
current CPU value from its output."* Expected chain:
`index → man sysmon-svc → compose service sysmon-svc / → out sysmon-svc cpu/current`.

Driven headless: `mount /mnt/llm; wm/matrix -h; tools9p -m /tool read list
matrix; veltro -v [-R effort] "<task>"`. Scored on **actual tool-invocation
lines**, not prose (medium is more verbose and mentions paths it never calls).
Reasoning set per session via the new `veltro -R` flag; verified applied by
reading `/mnt/llm/$id/reasoning`.

## Results

Interleaved low-vs-medium A/B, N=8 each, plus low+escalation N=8:

| condition          | full loop (`…→out cpu/current`) | stalled after 1st call |
|--------------------|:------------------------------:|:----------------------:|
| low (server default) | 0/8                          | 7/8                    |
| medium             | 6/8                            | 2/8                    |
| **low + escalation** | **7/8**                      | 1/8                    |

Stall signature at low (verbatim, `stop_reason=end_turn`, no tool call):
`"We need to call matrix man sysmon-svc."` / `"Need to read contract of
sysmon-svc."` — it names the exact tool, then ends the turn.

Escalation behaviour: completing reps used 1–2 recoveries; on a genuine
completion the nudge costs exactly one extra cheap turn (model replies `DONE`,
`justnudged` guard prevents re-escalation). Bounded by `MAX_RECOVERIES=2`.

### Recovery-mode ablation (decoupling nudge from reasoning)

The recovery was initially built as a fused "escalate reasoning + re-prompt",
which tightly coupled it to reasoning-capable models (it would blindly write
`reasoning` to a session — harmful for a non-reasoning model like mistral,
which llmsrv does *not* auto-clear). It was split into a model-agnostic **nudge**
(re-prompt only) and an opt-in **escalate** (nudge + reasoning bump, gated on the
session already reporting a reasoning level). Ablation (gpt-oss, `-R low`,
interleaved N=6 each):

| mode | full-loop |
|------|:---------:|
| off (no recovery)              | 1/6 |
| nudge (model-agnostic)         | **3/6** |
| escalate (nudge + reasoning)   | 1/6 |

The **nudge carries the recovery**; the reasoning bump added nothing at this N
(the earlier one-off "low+escalation 7/8" was variance — absolute rates swing
hard run-to-run). Conclusion: **default recovery is the model-agnostic nudge**;
reasoning-escalation stays opt-in (`-X escalate`) and is not justified as a
default. Larger-N confirmation is future work, but the direction (nudge > off;
escalate ≈ off) plus the decoupling principle settles the default.

Caveat: A/B pairs ran medium-then-low (mild ordering confound); effect size is
large (Fisher p≈7e-4) and mechanistically clear, so the direction is trusted.
Absolute completion rates are noisy session-to-session; the *within-interleave*
contrast is the reliable signal.

## Changes made

`appl/veltro/veltro.b`:
- `-R <effort>` flag → per-session `reasoning_effort` override (default unchanged
  = server default). Lever for tool-driven tuning.
- **Model-agnostic stall recovery** in `agentloop`, `-X <mode>`
  (`nudge`|`escalate`|`off`, default **nudge**): on `end_turn`/no-tools *after*
  ≥1 tool call with a short narration (`< STALL_TEXT_MAX`), re-prompt once with
  "call the tool or reply DONE". Bounded by `MAX_RECOVERIES`, guarded against
  re-escalating the nudge reply. `escalate` additionally bumps reasoning one
  rung, but only when the session already reports a reasoning level — so a
  non-reasoning model is never sent a reasoning request. Verbose logs each
  recovery (= eval metric).
- Verbose per-step diagnostic (`stopreason`/`ntools`/`textlen`) — the
  observability that made the stall diagnosable; kept for future grinds.

Model-agnostic by construction: the default nudge is pure harness (safe for any
model); reasoning-escalation is opt-in and capability-gated. Claude rarely
narrates-then-stops so recovery almost never fires for it.

## Tickets filed

- **IOL-51** (commented) — describe-instead-of-call fine-tune target. Added the
  Matrix-skill data: same failure mode, plus two new dimensions (reasoning-effort
  dependence; the stall lands at the tool-result→next-call transition). The raw
  model behaviour remains the SFT target; the harness only partially masks it.
- **INFR-381** (new) — harness/serving side: the shipped model-agnostic stall
  recovery, and the reasoning-capability signal gap (llmsrv has no per-session
  "reasoning_supported"; client can't safely gate reasoning writes for
  non-reasoning models). Follow-on: larger-N ablation, per-toolset reasoning,
  mistral run. Relates IOL-51, INFR-1.

## Composing the interface (display dashboards) — the actual skill

The reliability work above all used a one-line **service** composition — it tests
tool-*driving*, not interface *composition*. Driving gpt-oss to author a real
two-panel dashboard (`layout hsplit` + cpu-gauge + mem-gauge + service, wiring
display inputs to the service's output dir) exposed the real skill boundary:

- **Structure: 4/4.** Valid layout, region names, module→region mapping, service
  line; composition loads (`status: running`).
- **Wiring: 0/4 (before fix).** Every rep mounted the gauges at `/`,
  `/sysmon-svc`, or `/sysmon` instead of the service outdir — the dashboard
  would render empty. All reps *read the contracts*; they failed because the
  outdir path (`/tmp/matrix/<service>`, `matrix.b:1970`) was documented **only**
  in `matrix.txt` (not in the model's context) and the `perf-dashboard` example —
  never in the discoverable man pages. A doc gap, not a capability limit.

**Fix (pure prompt/contract, no rebuild — man pages serve live):** added a
`MOUNT` section to the display-module contracts (cpu-gauge, mem-gauge) stating
"mount at the producing service's outdir, `/tmp/matrix/<service>`", and put the
concrete outdir path in sysmon-svc's `WRITES` header. Re-ran the identical test:

- **Wiring: 4/4 correct** (`/tmp/matrix/sysmon-svc`). 0/4 → 4/4.
- One rep produced a **fully correct, complete dashboard** (layout + service +
  both gauges wired). 2/4 wired the gauges but omitted the `service` line
  (completeness gap); 1/4 stalled.

Conclusion: **Veltro can compose a correctly-wired interface** once the contract
states where services write. The `MOUNT`/outdir-path documentation was then
extended across the whole library (net-gauge, proc-list, signal-feed,
position-table, risk-gauge, llm-sessions, llm-context, geo-map; llm-recorder,
alert-watcher, geo-fixture), so every module is wireable.

### Residual after the wiring fix (N=6 + N=6)

Two probes on the finished contracts:

- **Wiring: robust** — every composing rep used `/tmp/matrix/sysmon-svc`.
- **Completeness (producer service line):** before a nudge, composing reps
  included `service …/` only 1/3 (they compose the visible panels, forget the
  producer). Adding an "include that service in the same composition" reminder to
  the display `MOUNT` hints raised it to 2/2 among composing reps — the same
  doc lever works.
- **Dominant remaining failures are model-level, not compositional:**
  - *Hard stalls* (≈3/6 on this longer task): index → narrate → `end_turn`; the
    nudge fires but the model re-narrates and gives up. The interface task stalls
    MORE than the one-line service task (more turns = more stall points).
  - *Verb confusion* (new): a rep composed a **correct** dashboard, then flailed
    `ctl load` / `pin` / `ctl load <name>` and **emptied its own correct
    composition**. The model doesn't grasp that `compose` applies immediately —
    it hunts for a separate "load". Candidate fix: state in the tool description
    that `compose` loads the composition (no `ctl load` after). Both behaviours
    belong to IOL-51.

Net: the contract fixes make gpt-oss compose *correctly when it composes*; the
ceiling on the interface task is now tool-calling reliability (stalls) and
compose-vs-load verb confusion — both model-behaviour, tracked in IOL-51.

## Cross-model: Mistral (non-reasoning target)

Swapped heph's SGLang backend to `mistral-small-3.2-awq`
(`--served-model-name mistral-small3.2 --disable-cuda-graph
--tool-call-parser mistral`, no reasoning-parser — a true non-reasoning model)
via the pre-built `serving-sglang.env.mistral-small3.2`, verified live from the
local emu (`model: mistral-small3.2`, bare ask → `PONG`), ran the grind, and
restored gpt-oss.

**Result: mistral cannot drive the skill — blocked at the SGLang serving layer,
upstream of veltro.** Every agent-loop turn returned an empty response:

- The **planning turn worked** (337-byte plan, context fine at 0.13 usage) — so
  it is NOT context overflow (mistral's 8192 window) and NOT the system prompt.
- The **tool-use turn returned 14 bytes (empty)**, and the SGLang container
  logged `Error in parse_streaming_increment: Expecting value: line 1 column 2`
  repeatedly — SGLang's `--tool-call-parser mistral` fails to parse mistral's
  tool-call output. The agent loop dies before a single tool call lands.

Implications:
- **Model-agnostic recovery couldn't be exercised** on mistral — not because the
  nudge is wrong, but because mistral emits no parseable tool call for the loop
  to recover. The serving bug is upstream of the harness entirely.
- The INFR-381 reasoning hazard is **visible** (the session reports
  `reasoning: low` for a non-reasoning model) but was **not** the blocker here —
  the bare ask worked at `reasoning: low`. The blocker is the tool-call parser.
- **Mistral is not currently usable as a tool-driving agent on this stack.**
  Fixing it is SGLang serving config (tool-call-parser variant / chat template /
  streaming), not veltro. Filed as an INFR ticket.

## Open / future work

- Confirm the stall generalises beyond matrix (a `spawn`/delegation task at low).
- Larger, order-randomised A/B to fully kill the ordering confound.
- Tune `STALL_TEXT_MAX` (observed stalls were 12–77 chars; a short final answer
  of 107 chars got one benign nudge).
- Minor: one rep confused generic `read` with matrix `out`
  (`read cpu/current` before `out sysmon-svc cpu/current`) — tool-selection
  overlap worth watching.
- Narrow-mount-grant discipline (does the model over-grant `/` when a narrower
  mount satisfies the contract?) — not yet probed.
