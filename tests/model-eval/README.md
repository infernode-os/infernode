# InferNode model evaluation harness

This directory provides a thin offline harness for evaluating how well a
given model — served by an OpenAI-compatible endpoint such as Ollama —
behaves with the InferNode tool catalogue.

It is **not** a full reproduction of the production lucibridge agent
loop. It is meant to isolate the model + tool-description behavior so
fixes to either can be measured without rebuilding `emu` or relaunching
InferNode. Real production verification still happens in a live Veltro
session.

## Why this exists

Two questions we kept hitting in ad-hoc testing:

1. **Does this model fit the InferNode harness?** (Read by *column* —
   model X passes M of N scenarios → it's usable / unusable / canary.)
2. **Are these scenarios revealing harness bugs that affect many
   models?** (Read by *row* — scenario Y fails across most models →
   the tool description, error message, or protocol is the bug; the
   models are doing the most reasonable thing they can with what
   they're shown.)

The harness produces a 2D scorecard answering both.

## What it tests

`scenarios.yaml` is a list of probes derived from real failures
observed in production. Each scenario:

- Optionally runs `setup_turns` (priors that establish state, e.g.
  "Launch the editor").
- Issues a single `prompt` and runs an agent loop with synthetic tool
  results until the model emits `end_turn` (or a turn cap).
- Grades the resulting tool-call trace against `expects` (a
  multi-call sequence or a single-call shape) and `classify_other`
  patterns that distinguish *how* a non-pass run failed.

Scenarios cover three categories:

- **tool-selection** — does the model pick the right tool? (e.g.
  `launch shell` should call the launch tool, not the shell tool.)
- **tool-grammar** — does the model emit valid args for the right
  tool? (e.g. `editor write Hello!` not `editor write /path "Hello!"`.)
- **error-recovery** — does the model recover from an error message?
  (e.g. after `read /tmp/foo` errors, retry with `read body`.)
- **model-character** — soft probes for under-/over-confidence,
  unnecessary clarifying questions, false claims of incapacity.

## Usage

```sh
# Single model, default scenarios:
python tests/model-eval/runner.py \
    --models mistral-small3.2:24b \
    --runs 5 \
    --output /tmp/report.md

# Cross-model sweep (assumes Ollama on the Jetson is forwarded to
# localhost, or runner.py is invoked on the Jetson directly):
python tests/model-eval/runner.py \
    --models mistral-small3.2:24b qwen2.5:32b devstral:latest \
    --runs 5 \
    --temperature 0.0 \
    --output /tmp/report.md

# Probe a specific change to a single tool description:
python tests/model-eval/runner.py \
    --models mistral-small3.2:24b \
    --tools-dir /tmp/ab_new_tools \
    --runs 10 \
    --temperature 0.7
```

Required: `pip install pyyaml`.

## Reading the output

`report.md` has three sections:

1. **Per-model summary** — one row per model showing PASS / FAIL /
   classified-other counts. Quick "is this model usable" answer.
2. **Pass rate by scenario × model** — the 2D scorecard. Read by row
   to find harness/scenario issues; read by column to find model-fit
   issues.
3. **Failure-mode breakdown by scenario** — for each scenario that
   any model failed, how the failures distribute across models. If
   most models fail the same way → that's a harness fix (probably
   in the tool description for that scenario). If models fail
   differently → that's a per-model issue.

## Adding a scenario

Append to `scenarios.yaml`:

```yaml
- name: my_new_scenario
  category: tool-grammar
  description: One-line summary
  setup_turns: ["context-establishing user message"]
  prompt: "the test prompt"
  expects:
    tool: <expected tool>
    args_starts_with: "..."
  classify_other:
    SPECIFIC_FAILURE_MODE:
      tool_args_matches_regex: "..."
```

The `expects` and `classify_other` keys recognized are documented in
`runner.py` (`_check_one` and `_matches_classifier`).

## Adding a model

Just add it to `--models`. New models join with one config change at
the call site. The harness assumes the model is served by an
OpenAI-compatible endpoint (Ollama works; vLLM works; `--url` lets you
point elsewhere).

## Limitations

- **Synthetic tool results.** Production lucibridge runs real tools
  and feeds real results back. The harness uses canned strings
  ("created artifact", "ok"). For tool-selection and tool-grammar
  scenarios this doesn't matter; for error-recovery it does, and the
  scenario file contains the exact synthetic responses to make tests
  deterministic.
- **No model-side evaluation of system.txt or reminders.** The
  harness sends a minimal system prompt focused on the tool
  contract. Production sends ~30 KB of system text including
  long-form tooldocs and reminders. Some context-pressure failures
  (notably the Mistral-family `[TOOL_CALLS]` marker drop) only
  reproduce under the full production prompt; the harness is biased
  toward measurable, reproducible behavior — not edge-case
  surfacing.
- **Probabilistic, not deterministic.** Models at temperature > 0
  vary across runs. Run with `--runs >= 5` and look at pass rates,
  not single passes.
