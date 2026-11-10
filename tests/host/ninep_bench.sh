#!/bin/sh
#
# ninep_bench.sh - 9P throughput and latency by message size, through
# tests/ninep_bench.b, with the statistics: for each target, size and
# number of readers, the median, least and most MB/s over the runs and
# the median time of one small message's round trip.
#
#	tests/host/ninep_bench.sh [label=addr:path ...]
#
# With no target it exports a file of its own on the loopback (no
# authentication) and measures that.  A target is reached as mount(1)
# would, with the key in $BENCH_ROOT's /usr/$user/keyring/default and
# -C $BENCH_ALG; BENCH_ROOT is the emulator's root for that (a release
# tree with the keys), and must hold dis/tests/ninep_bench.dis.
#
#	BENCH_ARGS	the bench's own options (default: four sizes, 1 2 4 8
#			readers, five runs)
#	BENCH_ROOT	emulator root for targets (default: this tree)
#	BENCH_OUT	directory for the raw lines (default: $ROOT/tmp/ninep_bench)
#
# Not a test: it passes or fails nothing, and is not run by CI.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "no emulator at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "no python3"; exit 77; }
BENCH_ARGS=${BENCH_ARGS:-"-m 8192,16384,32768,65536 -c 1,2,4,8 -n 5 -l 20"}
BENCH_ROOT=${BENCH_ROOT:-$ROOT}
BENCH_OUT=${BENCH_OUT:-$ROOT/tmp/ninep_bench}
mkdir -p "$BENCH_OUT"
[ -f "$BENCH_ROOT/dis/tests/ninep_bench.dis" ] || { echo "no dis/tests/ninep_bench.dis under $BENCH_ROOT"; exit 77; }

summary() {
	python3 - "$@" <<'PY'
import re, sys, statistics as st
stalled = {}
for f in sys.argv[1:]:
    rows = {}
    for l in open(f):
        m = dict(re.findall(r'(\w+)=(\d+)', l))
        if 'stalled' in m:
            stalled.setdefault(f, []).append(l.strip())
            continue
        if 'ms' not in m:
            continue
        k = (int(m['msize']), int(m['readers']), int(m['shared']))
        rows.setdefault(k, []).append((int(m['bytes']) / 1e6 / max(int(m['ms']), 1) * 1000, int(m['stat_us'])))
    print(f.rsplit('/', 1)[-1].replace('.out', ''))
    print('  %-7s %-8s %-6s %9s %9s %9s %12s %4s' % ('msize', 'readers', 'mounts', 'MB/s med', 'min', 'max', 'stat ms/op', 'n'))
    for (ms, r, sh), v in sorted(rows.items()):
        mb = [x[0] for x in v]
        us = [x[1] for x in v]
        print('  %-7d %-8d %-6s %9.2f %9.2f %9.2f %12.2f %4d' % (ms, r, 'one' if sh else 'each', st.median(mb), min(mb), max(mb), st.median(us) / 3000, len(v)))
    for l in stalled.get(f, []):
        print('  STALLED', l)
PY
}

script="$BENCH_ROOT/tmp/ninep_bench.sh"
mkdir -p "$BENCH_ROOT/tmp"
outs=""
if [ $# = 0 ]; then
	mkdir -p "$BENCH_ROOT/tmp/ninep_bench_src"
	head -c 16777216 /dev/urandom > "$BENCH_ROOT/tmp/ninep_bench_src/f"
	PORT=$((20000 + $$ % 20000))
	cat > "$script" <<ISH
load std
ndb/cs
listen -A tcp!127.0.0.1!$PORT {export /tmp/ninep_bench_src}
sleep 1
/dis/tests/ninep_bench.dis -A $BENCH_ARGS tcp!127.0.0.1!$PORT /f
echo halt > /dev/sysctl
ISH
	out="$BENCH_OUT/loopback.out"
	with_timeout 3600 "$EMU" -c1 -r"$BENCH_ROOT" /dis/sh.dis /tmp/ninep_bench.sh </dev/null > "$out" 2>&1 || true
	outs="$out"
	rm -rf "$BENCH_ROOT/tmp/ninep_bench_src"
fi
for t in "$@"; do
	label=${t%%=*}; rest=${t#*=}; addr=${rest%%:*}; path=${rest#*:}
	cat > "$script" <<ISH
load std
ndb/cs
/dis/tests/ninep_bench.dis -C ${BENCH_ALG:-aes_256_cbc/sha256} $BENCH_ARGS $addr $path
echo halt > /dev/sysctl
ISH
	out="$BENCH_OUT/$label.out"
	with_timeout 7200 "$EMU" -c1 -r"$BENCH_ROOT" /dis/sh.dis /tmp/ninep_bench.sh </dev/null > "$out" 2>&1 || true
	outs="$outs $out"
done
rm -f "$script"
grep -h 'ninep_bench:\|stalled=' $outs || true
summary $outs
