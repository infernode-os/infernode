#!/bin/bash
#
# Connection-churn leak / stability harness for the node-auth path.
#
# Launches one emu running churn_node (a serving node + a connecting node that
# performs `count` sequential authenticated connection cycles over loopback),
# and samples the emu process's resident memory (VmRSS) and open file
# descriptors against the iteration markers it prints.  A healthy run plateaus:
# RSS reaches a steady state after warmup and the descriptor count stays flat.
# A leak in the socket / handshake / ssl / fd lifecycle shows as monotonic
# growth.
#
# Usage:  run-churn.sh [count [alg [port]]]
#   count  connection cycles      (default 800)
#   alg    signer cert algorithm  (default ed25519; e.g. mldsa65)
#   port   loopback TCP port       (default 19500)
#
# Exit status: 0 = plateau (PASS), 1 = leak/instability (FAIL), 2 = skipped.
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COUNT="${1:-800}"
ALG="${2:-ed25519}"
PORT="${3:-19500}"

emu_bin() {
	for c in "$ROOT/emu/Linux/o.emu" "$ROOT/emu/MacOSX/o.emu"; do
		[ -x "$c" ] && { echo "$c"; return; }
	done
	echo ""
}
EMU="$(emu_bin)"
[ -n "$EMU" ] || { echo "run-churn: no emu binary under $ROOT" >&2; exit 2; }

LIMBO=""
for c in "$ROOT/Linux/amd64/bin/limbo" "$ROOT/Linux/arm64/bin/limbo" "$ROOT/MacOSX/arm64/bin/limbo"; do
	[ -x "$c" ] && { LIMBO="$c"; break; }
done
DIS="$ROOT/dis/tests/stress/churn_node.dis"
if [ -n "$LIMBO" ]; then
	mkdir -p "$ROOT/dis/tests/stress"
	"$LIMBO" -I "$ROOT/module" -o "$DIS" "$(dirname "$0")/churn_node.b" 2>/dev/null
fi
[ -f "$DIS" ] || { echo "run-churn: churn_node.dis missing (build with native limbo)" >&2; exit 2; }

TMP="$(mktemp -d)"
OUT="$TMP/out"
trap 'kill $PID 2>/dev/null; rm -rf "$TMP"' EXIT

echo "=== churn: $COUNT cycles, $ALG signer, $EMU ==="
"$EMU" -c1 -r"$ROOT" /dis/tests/stress/churn_node.dis "$COUNT" "$PORT" "$ALG" >"$OUT" 2>&1 &
PID=$!

rss_kb()  { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null; }
fd_count(){ ls "/proc/$1/fd" 2>/dev/null | wc -l; }

# samples: "iter rss fd"
SAMPLES="$TMP/samples"
: >"$SAMPLES"

# Wait for START (or a clean skip)
for _ in $(seq 1 100); do
	grep -q "START" "$OUT" 2>/dev/null && break
	if grep -q "SKIP:" "$OUT" 2>/dev/null; then
		echo "SKIP: $(grep SKIP: "$OUT")"; exit 2
	fi
	kill -0 $PID 2>/dev/null || break
	sleep 0.1
done

# Sample until the process prints DONE or exits.
last_iter=0
while kill -0 $PID 2>/dev/null; do
	r="$(rss_kb $PID)"; f="$(fd_count $PID)"
	it="$(awk '/^iter /{n=$2} END{print n+0}' "$OUT")"
	[ -n "$r" ] && echo "$it $r $f" >>"$SAMPLES"
	last_iter="$it"
	grep -q "^DONE" "$OUT" && break
	sleep 0.3
done
# brief settle + final sample while still alive
sleep 0.5
r="$(rss_kb $PID)"; f="$(fd_count $PID)"
[ -n "$r" ] && echo "$COUNT $r $f" >>"$SAMPLES"
wait $PID 2>/dev/null

echo "--- node output ---"
sed 's/^/    /' "$OUT"

if ! grep -q "^DONE" "$OUT"; then
	echo "FAIL: churn did not complete $COUNT cycles (instability under churn)"
	exit 1
fi
# any explicit error line is an instability failure
if grep -qiE "failed|short" "$OUT"; then
	echo "FAIL: churn reported a per-connection error"
	exit 1
fi

# ---- leak analysis -------------------------------------------------------
# Warmup baseline = first sample taken at/after iter 100 (steady-state heap);
# compare RSS + fd against the final sample.
analyze() {
	awk '
	{ iter[NR]=$1; rss[NR]=$2; fd[NR]=$3; n=NR }
	END{
		if(n < 2){ print "INSUFFICIENT"; exit }
		# warmup index: first sample with iter>=100, else first sample
		wi=1;
		for(i=1;i<=n;i++){ if(iter[i]>=100){ wi=i; break } }
		rss_warm=rss[wi]; fd_warm=fd[wi]; it_warm=iter[wi];
		rss_end=rss[n]; fd_end=fd[n];
		# peak fd over the whole run
		fdpeak=0; rsspeak=0;
		for(i=1;i<=n;i++){ if(fd[i]>fdpeak)fdpeak=fd[i]; if(rss[i]>rsspeak)rsspeak=rss[i] }
		dr=rss_end-rss_warm; if(dr<0)dr=0;
		printf "warmup@iter%d: rss=%dkB fd=%d | end: rss=%dkB fd=%d | peakfd=%d peakrss=%dkB\n",
			it_warm, rss_warm, fd_warm, rss_end, fd_end, fdpeak, rsspeak;
		printf "post-warmup RSS growth: %d kB; fd delta: %d\n", dr, fd_end-fd_warm;
		# thresholds: fds must stay flat; RSS must not grow more than 24 MB
		# after warmup (a real per-connection leak grows linearly and blows
		# well past this over hundreds of cycles).
		fdleak = (fd_end > fd_warm + 8) || (fdpeak > fd_warm + 16);
		rssleak = (dr > 24000);
		if(fdleak){ print "VERDICT FAIL (fd leak)"; exit }
		if(rssleak){ print "VERDICT FAIL (rss growth)"; exit }
		print "VERDICT PASS";
	}' "$SAMPLES"
}
echo "--- leak analysis ---"
RESULT="$(analyze)"
echo "$RESULT" | sed 's/^/    /'

if echo "$RESULT" | grep -q "VERDICT PASS"; then
	echo "PASS: $COUNT cycles, RSS and fd count plateaued"
	exit 0
else
	echo "FAIL: resource growth across $COUNT cycles — see analysis above"
	exit 1
fi
