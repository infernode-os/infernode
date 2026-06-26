# Cross-model compatibility harness (Veltro agent)

Runs the same task suite across multiple LLMs to confirm the InferNode agent
stack (veltro + tools9p + `/mnt/llm` + ollama) behaves correctly with each
model family, and to surface **model-family-specific** breakage (tool-call
emission/parsing, arg formats, output discipline, reasoning-token leakage).

This is a **compatibility** check, not fine-tuning. gpt-oss + mistral are the
known-good baselines; qwen3.6 + GLM-4-32B were the new entrants validated here.

## Files
- `matrix.sh` — generator + launcher for running **locally** (laptop emu mounts
  hephaestus `/mnt/llm` over the network). DRY by default; `… run` to execute.
- `matrix_heph.sh` — runs the matrix **on hephaestus via loopback**
  (`tcp!127.0.0.1!5640`). Use this when the local emu is stale vs the server's
  keyring SSL algs (see Caveats). Subcommands: `launch | status | fetch`.
- `matrix_metrics.py` — aggregates logs → per-run table, per-model summary, and
  **family-specific flags**; extracts final answers for eyeballing.

## Usage (hephaestus loopback — the reliable path)
```sh
# full matrix (4 models x 7 tasks x REPS)
REPS=1 sh matrix_heph.sh launch
sh matrix_heph.sh status            # poll until done
sh matrix_heph.sh fetch             # pull logs locally + run metrics

# focused re-run of specific cells, separate log dir
REPS=3 ONLY="t4_verify t5_research" TAG=reps3 sh matrix_heph.sh launch
```
Models default to: `gpt-oss:20b mistral-small3.2:24b qwen3.6:27b hf.co/unsloth/GLM-4-32B-0414-GGUF:Q4_K_M`
(override with `MODELS=`). Model-OUTER ordering keeps each model resident in
ollama (`OLLAMA_MAX_LOADED_MODELS=1`) to avoid 17–19 GB reloads.

## Task suite (dimensions)
| id | dimension |
|----|-----------|
| t0_trivia   | lightness — no spurious tool use on "who are you?" |
| t1_read     | single-tool dispatch + read-cache dedup |
| t2_find     | `find` arg-order / substring tolerance (the "no matches" failure mode) |
| t3_grep     | multi-tool search |
| t4_verify   | deterministic classifier → verify persona → `VERDICT:` line |
| t5_research | classifier → research persona → `FINDINGS` + `SOURCES` (file:line) |
| t6_agentic  | plan / decompose / spawn + synthesis |

## Results (2026-06, hephaestus Jetson Orin)
**Compatibility: PASS for all four models.** Core dimensions (t0–t3, t6) pass
across the board — no tool/arg/dispatch breakage, no qwen `<think>` leakage.
qwen3.6 and GLM-4-32B are drop-in compatible (GLM patterns like gpt-oss, qwen
like mistral). gpt-oss remains the server default (`model=gpt-oss:20b`).

**One model-agnostic gap → INFR-354.** The verify/research personas don't
reliably emit their output contract on short tasks. The classifier routed
correctly 24/24, but (REPS=3, passes/3):

| Model | t4_verify (VERDICT) | t5_research (FINDINGS+SOURCES) |
|---|---|---|
| gpt-oss:20b | 0/3 | 0/3 |
| mistral-small3.2:24b | 2/3 | 0/3 |
| qwen3.6:27b | 1/3 | 1/3 |
| GLM-4-32B-0414 | 0/3 | 0/3 |

Content was usually correct on t5 (headers omitted) — a format-discipline gap,
not capability, and it affects the baselines too (so not a new-model bug). Note:
a REPS=1 pass made qwen look like it "nailed" verify — REPS=3 corrected that.
**Always rep these two cells; single samples mislead.**

## Caveats
- **Run on hephaestus loopback** if the local amd64 emu is stale: the patched
  server uses new kernel-SSL algorithms (#D, AES-CBC/SHA-256) for keyring auth;
  an older client emu hangs at the auth handshake. Rebuild the local emu to use
  `matrix.sh` (network path).
- The keyfile (`~/.infernode/lib/keyring/serve-llm`) is referenced by path only;
  never commit it.
- Logs/`*_boot.sh` are reproducible artifacts — regenerate by re-running.

## Related
- INFR-354 — verify/research output-contract gap (the open item).
- INFR-353 — exporter crash-loop regression (had to be patched before this eval
  could run).
