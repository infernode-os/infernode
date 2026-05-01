# Model Integration Notes

Notes on local-LLM models tested through the InferNode harness
(`lucibridge` → `llmsrv` → Ollama → model). Captures what works,
what doesn't, and what would need to change to add support for the
ones that don't.

## Current status (2026-05-01)

| Model | Status | Notes |
|---|---|---|
| `mistral-small3.2:24b` | Works (with caveat) | Default local model. Mostly clean Ollama tool-call translation. Occasionally drops `[TOOL_CALLS]` markers (~5–10% of follow-up turns), leaking bare JSON or `read[ARGS]{...}` into chat content. Same root cause as Devstral; lower rate. |
| `qwen2.5:32b` | Works | Verified via offline A/B harness (5/5 with directive descriptions). Larger memory footprint. |
| `mistral-nemo:latest` | Untested in real session | Should work — same family as Mistral Small. |
| `devstral:latest` | **Broken** with our harness | See "Devstral" section below. |

## The `[TOOL_CALLS]` marker drop (Mistral-family Ollama bug)

This is **family-wide** Mistral-on-Ollama behavior, not Devstral-specific
as originally documented. Any Mistral-template model in Ollama can
drop the `[TOOL_CALLS][...]` wrapper around its tool-call JSON, in
which case Ollama returns the malformed payload as plain
`message.content` instead of as structured `tool_calls`.

Failure rate observed (rough):
- `mistral-small3.2:24b`: ~5–10% of *follow-up* turns (very rare on
  the first turn; more common after a tool result has been fed back).
- `devstral:latest`: significantly higher, especially under big prompts.

The right fix is harness-level — see "What would need to change to
support Devstral", item 3 (bare-JSON detector in `llmclient.b`). It
benefits every Mistral-family model.

## Devstral

Devstral is Mistral's agentic-fine-tuned model. ~24B params, similar
size to Mistral Small. Trained for tool use. **Should** be a strict
upgrade for our workload. In practice it isn't — same `[TOOL_CALLS]`
marker-drop class as Mistral Small but at a much higher rate,
especially under longer/more-complex production prompts.

### Symptom

User asks Veltro to do something tool-shaped. Model emits text
containing the tool call as bare JSON in a code block, e.g.

```javascript
{
  "name": "launch",
  "arguments": { "args": "fractals" }
}
```

The `present` tool (or whichever) is never actually invoked; lucibridge
only sees a plain `STOP:end_turn` text response.

### Root cause

Devstral's Ollama modelfile carries its own baked-in system prompt
("You are Devstral, …, using the OpenHands scaffold") and a chat
template that wraps tool calls in Mistral-native markers:

```
[TOOL_CALLS][{"name": "X", "arguments": Y}]
```

Ollama translates between those markers and OpenAI's `tool_calls`
array on the wire. **When Devstral forgets the `[TOOL_CALLS]`
wrapper and emits the JSON inline, Ollama can't recognize it as a
tool call** — the JSON is returned verbatim as `message.content`.
That's the bare-JSON-in-chat we observe.

The probability of forgetting the wrapper rises with prompt
size/complexity. Offline replays with short or moderate prompts
look fine; production at ~31 KB system prompt fails.

### Reproduction

Not reliably reproducible offline yet. Confirmed in production
sessions only. Offline replays we tried (with system prompts
up to ~22 KB) did not surface the failure.

To attempt a reproduction:

1. Pull `devstral` into Ollama on a host with at least 16 GB RAM.
2. Point InferNode at it (`~/.infernode/lib/ndb/llm`: `model=devstral:latest`).
3. Use a real Veltro session, not the offline A/B harness.
4. Issue an open-ended prompt ("Let's seek a kick-arse demo") rather
   than a specific imperative ("Launch the shell").
5. Observe whether tool calls reach lucibridge or appear as bare
   JSON in chat content.

### What would need to change to support Devstral

Roughly in order of cost:

1. **Override Devstral's baked-in system prompt.**
   Either via the Ollama API's `options.system` field on each request,
   or by building a custom modelfile that strips the OpenHands
   framing. Easiest experiment; might be enough on its own.

2. **Reduce production system prompt size.**
   The `loadtooldocs` redundancy — directive paragraph appears
   both in the JSON `description` and in the system prompt's
   long-form section — was identified earlier in this work. Trimming
   it would cut ~1100 tokens per session and may reduce the rate at
   which Devstral drops its `[TOOL_CALLS]` wrappers.

3. **Detect bare-JSON tool calls in content and convert.**
   Add a post-processing step in `llmclient.b` (`appl/lib/llmclient.b`,
   the OpenAI-compat path that already has fallback parsing for
   `<tool_call>...</tool_call>` style models) that recognizes
   `{"name": "...", "arguments": ...}` as a tool call when it
   appears as the entire content. Loud workaround; logs every
   activation so we know how often it fires.

4. **Try a different quantization or fine-tune.**
   Some Devstral variants may be more reliable than the default
   Q4_K_M. Worth a quick A/B if the above don't pan out.

### What we tried that didn't work

- Directive descriptions (the `118d33a9` rewrite): improve Devstral's
  *content*-shape but don't fix the protocol-marker drop.
- Stripping surrounding double quotes in `present.b`: defensive parse
  for a different bug (literal quotes wrapping content); doesn't help
  the bare-JSON-in-chat issue.

## Lessons for future model-integration testing

1. **Replay must match production prompt content, not just size.**
   System.txt + reminders + full tooldocs, in production order. A
   minimal system prompt won't reveal context-pressure failures.
2. **Cover conversational prompts, not just imperative scenarios.**
   "Could you do a demo" is different from "Launch the shell" and
   surfaces different model behavior.
3. **Probabilistic failures need probabilistic tests.**
   Same prompt run multiple times at varying temperatures, or under
   stress (longer context, more tools loaded). One-shot at temp=0
   is necessary but not sufficient.
4. **Treat the model's modelfile as part of the harness.**
   Each model brings its own baked-in system prompt and chat template.
   Two models that look equivalent on benchmarks can have very
   different behavior with our prompt structure because their
   templates differ.
