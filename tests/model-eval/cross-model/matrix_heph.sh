#!/bin/bash
# matrix_heph.sh — run the cross-model compatibility matrix ON hephaestus
# (loopback), because the patched emu/veltro/models all live there and the
# local amd64 emu is stale (can't negotiate the new keyring SSL algs).
#
# Subcommands:
#   sh matrix_heph.sh launch    # generate boot, push, start detached emu run
#   sh matrix_heph.sh status    # how many runs done / is it finished
#   sh matrix_heph.sh fetch     # pull logs back + run metrics locally
#
# Tune: REPS=1 sh matrix_heph.sh launch   (default REPS=1 for first pass)

set -u
SSH="ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=10 pdfinn@10.147.17.120"
SCP="scp -P 2222 -o BatchMode=yes"
HOST="pdfinn@10.147.17.120"
T="/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode"
RWD="$T/tmp/matrix"            # remote working dir (inside emu root -> /tmp/matrix; fixed)
RLOG="$RWD/logs"
LOCAL="$(cd "$(dirname "$0")" && pwd)"
LOCALLOG="$LOCAL/matrix-heph-logs${TAG:+-$TAG}"   # local fetch dir (TAG keeps runs separate)

REPS="${REPS:-1}"
MODELS="${MODELS:-gpt-oss:20b mistral-small3.2:24b qwen3.6:27b hf.co/unsloth/GLM-4-32B-0414-GGUF:Q4_K_M}"
TOOLSET="read,list,find,search,grep,exec,plan,todo,gap,present,spawn"

read -r -d '' TASKS <<'TASKS_EOF'
t0_trivia|who are you?
t1_read|Read the file /appl/veltro/tools/read.b and explain in two sentences what it does.
t2_find|Find the source file that implements the spawn tool somewhere under /appl/veltro.
t3_grep|Search under /appl/veltro for where the deterministic intent classifier is defined and name the function.
t4_verify|verify that find for the pattern spawn under /appl/veltro/tools returns spawn.b
t5_research|compare how the find tool and the read tool parse their input arguments
t6_agentic|Audit three veltro tools - find, read, and grep: for each, report its argument format and one limitation.
TASKS_EOF

gen_boot() {
  local boot="$LOCAL/matrix_heph_boot.sh"
  {
    echo 'load std'
    echo 'path=(/dis .)'
    echo 'mount -ac {mntgen} /n'
    echo "bind -a '#I' /net"
    echo 'ndb/cs &'
    echo 'sleep 1'
    echo "mount -k /tmp/matrix/heph-key tcp!127.0.0.1!5640 /mnt/llm"
    echo 'echo mount-rc $status > /tmp/matrix/logs/_mount'
    echo "/dis/veltro/tools9p.dis -m /tool -b $TOOLSET $(echo $TOOLSET | tr ',' ' ') &"
    echo 'sleep 2'
    echo "fn stamp { echo \$1 \`{os sh -c 'date +%s'} >> /tmp/matrix/logs/_timing }"
    local rep=1
    while [ "$rep" -le "$REPS" ]; do
      for M in $MODELS; do
        local msafe; msafe="$(echo "$M" | tr '/:.' '___')"
        while IFS='|' read -r id prompt; do
          [ -z "$id" ] && continue
          [ -n "${ONLY:-}" ] && ! echo " $ONLY " | grep -q " $id " && continue
          echo "stamp 'START ${msafe} ${id} r${rep}'"
          echo "/dis/veltro/veltro.dis -m $M -v -p /appl/veltro '$prompt' > /tmp/matrix/logs/${msafe}__${id}__r${rep}.log >[2=1]"
          echo "stamp 'END ${msafe} ${id} r${rep}'"
        done <<< "$TASKS"
      done
      rep=$((rep+1))
    done
    echo 'unmount /mnt/llm'
    echo 'echo done > /tmp/matrix/logs/_done'
  } > "$boot"
  echo "$boot"
}

case "${1:-}" in
launch)
  boot="$(gen_boot)"
  nruns=$(( REPS * $(echo "$MODELS" | wc -w) * $(printf '%s\n' "$TASKS" | grep -c '|') ))
  echo "Generated $boot — $nruns runs (REPS=$REPS, $(echo "$MODELS" | wc -w) models, $(printf '%s\n' "$TASKS" | grep -c '|') tasks)"
  $SSH "mkdir -p $RLOG && rm -f $RLOG/* && cp ~/.infernode/lib/keyring/serve-llm $RWD/heph-key"
  $SCP "$boot" "$HOST:$RWD/matrix_boot.sh" >/dev/null
  # detached: survives ssh disconnect; logs to emu.out
  $SSH "cd $T && export XDG_RUNTIME_DIR=/run/user/\$(id -u) && nohup env SDL_VIDEODRIVER=dummy ./emu/Linux/o.emu -c1 -pheap=1024m -r$T sh /tmp/matrix/matrix_boot.sh >$RWD/emu.out 2>&1 & echo started pid \$!"
  echo "Launched detached on hephaestus. Poll with:  sh $0 status"
  ;;
status)
  done=$($SSH "cat $RLOG/_done 2>/dev/null")
  nlog=$($SSH "ls $RLOG/*.log 2>/dev/null | wc -l")
  nempty=$($SSH "for f in $RLOG/*.log; do [ -s \"\$f\" ] || echo x; done 2>/dev/null | wc -l")
  cur=$($SSH "tail -c 200 $RLOG/_timing 2>/dev/null | tr '\n' ' '")
  echo "logs: $nlog written ($nempty empty)   done: ${done:-NO}"
  echo "last timing: $cur"
  ;;
fetch)
  mkdir -p "$LOCALLOG"
  $SCP "$HOST:$RLOG/*" "$LOCALLOG/" >/dev/null 2>&1
  echo "fetched -> $LOCALLOG"
  python3 "$LOCAL/matrix_metrics.py" "$LOCALLOG"
  ;;
*)
  echo "usage: sh $0 {launch|status|fetch}   (REPS env, default 1)"
  ;;
esac
