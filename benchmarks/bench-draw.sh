#!/bin/sh
#
# bench-draw.sh — A/B test of the draw device on drawbench's workloads.
#
#	bench-draw.sh [-n runs] [-f frames] A B
#
# A and B are commands that run the emulator, each given the arguments
# for drawbench after them: two emulator binaries (before and after a
# change), or one binary with and without a setting, e.g.
#
#	bench-draw.sh ./old/o.emu ./emu/MacOSX/o.emu
#	bench-draw.sh 'env VAR=0 ./emu/MacOSX/o.emu' 'env VAR=1 ./emu/MacOSX/o.emu'
#
# Each is run n times (default 5); the table has each workload's median
# ms a frame, B's speed-up, and whether the final pixels agree.  It exits
# 1 if any checksums differ: a change to how drawing is done must not
# change what is drawn.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=5
FRAMES=20
while getopts n:f: o; do
	case $o in
	n)	RUNS=$OPTARG ;;
	f)	FRAMES=$OPTARG ;;
	*)	echo "usage: bench-draw.sh [-n runs] [-f frames] A B" >&2; exit 2 ;;
	esac
done
shift $((OPTIND-1))
if [ $# -ne 2 ]; then
	echo "usage: bench-draw.sh [-n runs] [-f frames] A B" >&2
	exit 2
fi
A=$1
B=$2
TMP="${TMPDIR:-/tmp}/bench-draw.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

for side in A B; do
	eval cmd=\$$side
	i=0
	while [ $i -lt $RUNS ]; do
		(cd "$ROOT" && eval "$cmd -c1 -r. /dis/drawbench.dis -f $FRAMES") > "$TMP/$side.$i" 2>&1
		i=$((i+1))
	done
done

python3 - "$TMP" "$RUNS" "$A" "$B" <<'EOF'
import sys, statistics, collections
tmp, runs, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
ms = {"A": collections.defaultdict(list), "B": collections.defaultdict(list)}
sums = {"A": {}, "B": {}}
order = []
for side in "AB":
    for i in range(runs):
        for line in open(f"{tmp}/{side}.{i}"):
            f = line.split()
            if len(f) == 4 and f[2] == "ms":
                ms[side][f[0]].append(float(f[1]))
                sums[side].setdefault(f[0], set()).add(f[3])
                if f[0] not in order:
                    order.append(f[0])
print(f"A: {a}\nB: {b}\n")
print(f"{'workload':10} {'A ms':>9} {'B ms':>9} {'B/A':>7}  pixels")
bad = 0
for w in order:
    ma = statistics.median(ms["A"][w]) if ms["A"][w] else float("nan")
    mb = statistics.median(ms["B"][w]) if ms["B"][w] else float("nan")
    same = sums["A"].get(w) == sums["B"].get(w) and len(sums["A"].get(w, ())) == 1
    bad |= not same
    ratio = f"{ma/mb:6.2f}x" if mb else "   -  "
    print(f"{w:10} {ma:9.2f} {mb:9.2f} {ratio:>7}  {'same' if same else 'DIFFER'}")
sys.exit(1 if bad else 0)
EOF
