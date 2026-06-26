#!/bin/bash
# matrix.sh — Cross-model compatibility harness for the Veltro agent stack.
#
# GOAL: confirm the InferNode agent harness works with each model family
# (gpt-oss, mistral, qwen, glm) and surface any MODEL-FAMILY-SPECIFIC breakage
# (tool-call emission/parsing, arg formats, output discipline, agentic paths).
# This is a COMPATIBILITY check, not fine-tuning. gpt-oss + mistral are the
# known-good baselines; qwen3.6 + GLM-4-32B are the new entrants.
#
# Design (learned from INFR-349 / INFR-353):
#   - ONE emu, ONE mount of /mnt/llm for the whole matrix (no per-run remount).
#   - unmount BEFORE the run ends; only signal .done after unmount.
#   - model-OUTER ordering so each model stays resident in ollama
#     (OLLAMA_MAX_LOADED_MODELS=1, keep_alive=-1 → avoid 17-19GB reloads).
#   - per-run wall-clock via host `date` called from inside emu (`os`).
#
# USAGE:
#   sh workspace/exp/matrix.sh           # DRY: generate matrix_boot.sh + print plan
#   sh workspace/exp/matrix.sh run       # RUN: launch emu, execute, then metrics
#                                        #   (requires /mnt/llm reachable, i.e. INFR-353 fixed)
#
# Tune via env: REPS=2 MODELS="..." sh workspace/exp/matrix.sh run

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root
EXP="$ROOT/workspace/exp"
LOGS="$EXP/matrix-logs"
KEY="$ROOT/workspace/serve-llm"
EMU="$ROOT/emu/Linux/o.emu"
HEPH="tcp!10.147.17.120!5640"

REPS="${REPS:-2}"

# ── Models under test (exact ollama tags; veltro -m writes these per-session) ──
MODELS="${MODELS:-gpt-oss:20b mistral-small3.2:24b qwen3.6:27b hf.co/unsloth/GLM-4-32B-0414-GGUF:Q4_K_M}"

# ── Toolset the agent gets (covers every dimension below) ──
TOOLSET="read,list,find,search,grep,exec,plan,todo,gap,present,spawn"

# ── Task suite: id | dimension | expectation | prompt ─────────────────────────
# Each line probes a distinct dimension where families tend to diverge.
# Pipe-delimited; prompts crafted so the deterministic classifier routes t4/t5.
read -r -d '' TASKS <<'TASKS_EOF'
t0_trivia|lightness|plain reply, 0 tool calls, says "Veltro"|who are you?
t1_read|single-tool dispatch + dedup|1 read, no redundant re-reads, completes|Read the file /appl/veltro/tools/read.b and explain in two sentences what it does.
t2_find|find arg-order/substring tolerance|find returns spawn.b (not "no matches")|Find the source file that implements the spawn tool somewhere under /appl/veltro.
t3_grep|multi-tool search|locates classifyintent via grep/find+read|Search under /appl/veltro for where the deterministic intent classifier is defined and name the function.
t4_verify|classifier->verify + VERDICT format|routes verify, runs exec, first line is VERDICT:|verify that find for the pattern spawn under /appl/veltro/tools returns spawn.b
t5_research|classifier->research + citation|routes research, ends FINDINGS + SOURCES with file:line|compare how the find tool and the read tool parse their input arguments
t6_agentic|plan/decompose/spawn|plan/todo, covers all three tools in a synthesized answer|Audit three veltro tools - find, read, and grep: for each, report its argument format and one limitation.
TASKS_EOF

# ── Generate the in-emu boot script (flat sequence; no Inferno-sh looping) ────
BOOT="$EXP/matrix_boot.sh"
mkdir -p "$LOGS"
{
  echo '#!/dis/sh.dis'
  echo 'load std'
  echo 'path=(/dis .)'
  echo 'mount -ac {mntgen} /n'
  echo "bind -a '#I' /net"
  echo 'ndb/cs &'
  echo 'sleep 1'
  echo "mount -k /workspace/serve-llm $HEPH /mnt/llm"
  echo 'echo mount-rc $status > /workspace/exp/matrix-logs/_mount'
  echo "/dis/veltro/tools9p.dis -m /tool -b $TOOLSET `echo $TOOLSET | sed 's/,/ /g'` &"
  echo 'sleep 2'
  echo 'fn stamp { echo $1 `{os sh -c '"'"'date +%s'"'"'} >> /workspace/exp/matrix-logs/_timing }'
  n=0
  rep=1
  while [ "$rep" -le "$REPS" ]; do
    for M in $MODELS; do
      msafe="$(echo "$M" | tr '/:.' '___')"
      while IFS='|' read -r id dim exp prompt; do
        [ -z "$id" ] && continue
        log="/workspace/exp/matrix-logs/${msafe}__${id}__r${rep}.log"
        echo "stamp 'START ${msafe} ${id} r${rep}'"
        echo "/dis/veltro/veltro.dis -m $M -v -p /appl/veltro '$prompt' > $log >[2=1]"
        echo "stamp 'END ${msafe} ${id} r${rep}'"
        n=$((n+1))
      done <<< "$TASKS"
    done
    rep=$((rep+1))
  done
  echo 'unmount /mnt/llm'
  echo 'echo done > /workspace/exp/matrix-logs/_done'
} > "$BOOT"

NRUNS=$(( REPS * $(echo "$MODELS" | wc -w) * $(printf '%s\n' "$TASKS" | grep -c '|') ))

echo "=== Veltro cross-model compatibility matrix ==="
echo "Models ($(echo "$MODELS" | wc -w)):"
for M in $MODELS; do echo "  - $M"; done
echo "Tasks ($(printf '%s\n' "$TASKS" | grep -c '|')):"
printf '%s\n' "$TASKS" | awk -F'|' 'NF{printf "  %-12s %-32s %s\n",$1,$2,$4}'
echo "Reps: $REPS   ->   TOTAL RUNS: $NRUNS"
echo "Boot script: $BOOT"
echo "Logs dir:    $LOGS/<model>__<task>__r<rep>.log"
echo

if [ "${1:-}" != "run" ]; then
  echo "DRY RUN. To execute once /mnt/llm is reachable (INFR-353 fixed):"
  echo "    sh $0 run"
  exit 0
fi

# ── Execute ───────────────────────────────────────────────────────────────────
[ -f "$HOME/.infernode/lib/keyring/serve-llm" ] && cp "$HOME/.infernode/lib/keyring/serve-llm" "$KEY"
rm -f "$LOGS/_done" "$LOGS/_timing" "$LOGS/_mount"
echo "launching emu (model-outer; resident model avoids reloads)..."
"$EMU" -c1 -pheap=1024m -r"$ROOT" sh /workspace/exp/matrix_boot.sh >/dev/null 2>&1 &
EPID=$!
echo "$EPID" > "$EXP/matrix.emupid"
# Poll for completion (slow Orin: budget generously)
for i in $(seq 1 600); do
  [ -f "$LOGS/_done" ] && break
  sleep 15
done
if [ -f "$LOGS/_done" ]; then echo "matrix complete."; else echo "TIMED OUT waiting for _done (check $LOGS)"; fi
kill -9 "$EPID" 2>/dev/null
echo "mount: $(cat "$LOGS/_mount" 2>/dev/null)"
python3 "$EXP/matrix_metrics.py" "$LOGS"
