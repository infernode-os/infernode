#!/bin/sh
# Regression test for INFR-421: typecom()'s measurement scratch buffer must
# be sized for the type it is measuring.
#
# comi() and comd() both walk t->map, which covers t->np*8 pointer slots, and
# emit per-slot code into a scratch buffer.  That buffer was a fixed 8KB
# (amd64) / 4096 words (arm64).  /dis/limbo.dis carries a type with np=542,
# needing ~100KB, so measuring it ran off the end of the buffer:
#
#   genw (comp-amd64.c:580)  *(u32int*)code = (u32int)o;
#     code = typecom_tmp + 8191, buffer is 8192
#   -> SIGSEGV, page-aligned address, si_code=1 (unmapped)
#
# emu's fault handler reported it as "PC not in any image (JIT-generated
# code?)" because genw is static and dladdr cannot name it, which is why it
# read like a JIT codegen bug rather than a buffer overflow in the compiler.
#
# Loading limbo.dis under -c1 is enough to trigger it.  Several concurrent
# loads make it near-certain and match the shape the escape-room campaign hit
# (an exec tool that abandons its child on timeout, leaving orphaned shells
# each loading the compiler).

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

[ "$OBJTYPE" = amd64 ] || { echo "SKIP: amd64 JIT test"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/limbo.dis" ] || { echo "SKIP: limbo.dis not built"; exit 77; }

fails=0
if ! grep -q 'typecom_bound' "$ROOT/libinterp/comp-amd64.c"; then
	echo "FAIL: comp-amd64.c does not size the typecom scratch from the type"
	fails=$((fails + 1))
fi
if grep -q 'typecom_tmp = jitmalloc(8192\*sizeof(uchar))' "$ROOT/libinterp/comp-amd64.c"; then
	echo "FAIL: comp-amd64.c still uses a fixed 8KB typecom scratch buffer"
	fails=$((fails + 1))
fi
if grep -q 'tmp = mallocz(4096 \* sizeof(u32int), 0)' "$ROOT/libinterp/comp-arm64.c"; then
	echo "FAIL: comp-arm64.c still uses a fixed 4096-word typecom scratch buffer"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] || exit 1
echo "PASS: source contract (typecom scratch is sized from t->np)"

REPRO="$ROOT/tmp/amd64_jit_typecom_bound_repro.sh"
LOG="$(mktemp)"
trap 'rm -f "$REPRO" "$LOG" "$ROOT/tmp/infr421_bound_probe.b" "$ROOT/tmp/infr421_bound_probe".*.dis' EXIT HUP INT TERM

cat >"$ROOT/tmp/infr421_bound_probe.b" <<'EOF'
implement Probe;
include "sys.m";
include "draw.m";
sys: Sys;
Probe: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("INFR421_BOUND_OK\n");
}
EOF

cat >"$REPRO" <<'EOF'
#!/dis/sh.dis

load std
path=(/dis .)

# Several concurrent limbo.dis loads, as the campaign's abandoned exec
# children produced.  Each load compiles the type that overran the buffer.
for (r in `{seq 1 8}) {
	limbo -o /tmp/infr421_bound_probe.1.dis /tmp/infr421_bound_probe.b &
	limbo -o /tmp/infr421_bound_probe.2.dis /tmp/infr421_bound_probe.b &
	limbo -o /tmp/infr421_bound_probe.3.dis /tmp/infr421_bound_probe.b &
	ls /dis > /dev/null
	sleep 1
}
sleep 4
echo '@@BOUND done'
EOF

timeout 240 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/amd64_jit_typecom_bound_repro.sh \
	>"$LOG" 2>&1
rc=$?
case "$rc" in
	0|124|137) ;;
	*) echo "FAIL: emulator exited with status $rc"; sed -n '1,40p' "$LOG"; exit 1 ;;
esac

if ! grep -q '^@@BOUND done$' "$LOG"; then
	echo "FAIL: repro did not run to completion"
	sed -n '1,40p' "$LOG"
	exit 1
fi
if grep -q 'segmentation violation' "$LOG" || grep -q '^SEGV' "$LOG"; then
	echo "FAIL: typecom scratch overrun still faults"
	grep -nE 'SEGV|segmentation violation|PC=' "$LOG" | sed -n '1,10p'
	exit 1
fi
if grep -q 'typecom: emitted' "$LOG"; then
	echo "FAIL: emitted code exceeded the typecom size bound"
	grep -n 'typecom: emitted' "$LOG" | sed -n '1,5p'
	exit 1
fi

echo "PASS: concurrent limbo.dis loads compile without overrunning the scratch"
