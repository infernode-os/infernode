#!/bin/sh
# Modules a JIT will not compile, in an emulator of its own
# (tests/jit_compile_fail.b loads them; tests/host/jit_compile_fail/mkbad.py
# makes them here, from modules limbo compiled).
#
# The code generators raise for an instruction they will not compile, out
# of the middle of compile(), which had no way to free what it held: each
# load of a large module with one such instruction kept its tables in the
# kernel's pool (megabytes a load for the largest), and on arm64 and
# riscv64 the next compile of anything panicked on the "compiling" flag
# left set.  An operand that indexes one of the compiler's own tables (a
# frame's type number, a movpc's pc, a branch whose destination is not an
# immediate, where a case or goto table is and the pcs in it) was used
# unchecked: the compiler read and wrote wherever the file said, a fault
# in the emulator's C.  The error named an opcode that is none from past
# the end of the table of names.  And a compile that failed after the code
# was generated (the amd64 JIT cannot make the code for a frame of 131072
# pointers) left the module's case and goto tables holding addresses, for
# the interpreter that then ran it.
#
# Here: /dis/sh.dis with its last instruction's opcode 255, loaded 200
# times, raises each time naming op255 and the main pool is where it was
# (the arm64 and riscv64 JITs leave an opcode they do not know to the
# interpreter, so there it loads, and the pool is where it was); seven
# other faults in a small module each raise "compile failed" and nothing
# faults; then a module marked "must be compiled" is, and runs; and the
# module with the large frame gives under -c1 what it gives under -c0,
# through each kind of case and a goto.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "jit_compile_fail_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "jit_compile_fail_test: SKIP (no python3)"; exit 77; }
for f in jit_compile_fail jit_compile_fail_mod jit_compile_fail_ok; do
	[ -f dis/tests/$f.dis ] || { echo "jit_compile_fail_test: SKIP (dis/tests/$f.dis not built)"; exit 77; }
done
[ -f dis/sh.dis ] || { echo "jit_compile_fail_test: SKIP (dis/sh.dis not built)"; exit 77; }

MK="$ROOT/tests/host/jit_compile_fail/mkbad.py"
D="$ROOT/tmp/jit_compile_fail.$$"
rm -rf "$D"
mkdir -p "$D" || exit 1
trap 'rm -rf "$D"' EXIT

KINDS="mode frame movpc branch casefar gotofar casepc"
python3 "$MK" op dis/sh.dis "$D/bad_bigop.dis" || exit 1
for k in $KINDS; do
	python3 "$MK" $k dis/tests/jit_compile_fail_ok.dis "$D/bad_$k.dis" || exit 1
done
python3 "$MK" must dis/tests/jit_compile_fail_ok.dis "$D/ok_must.dis" || exit 1
python3 "$MK" must dis/tests/jit_compile_fail_mod.dis "$D/mod_must.dis" || exit 1

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

COUNT=200
# what 200 failed loads may leave in the main pool: sh.dis's kept 48K each
LIMIT=262144

run() {
	with_timeout 300 "$EMU" $1 -pmain=512m -r"$ROOT" /dis/tests/jit_compile_fail.dis "/tmp/jit_compile_fail.$$" $COUNT 2>&1 < /dev/null
}

ref=$(run -c0)
out=$(run -c1)
if echo "$out" | grep -q '^SKIP'; then
	echo "jit_compile_fail_test: SKIP ($(echo "$out" | grep '^SKIP' | head -1))"
	exit 77
fi
tabref=$(echo "$ref" | grep '^TABLES ')
want='TABLES one two teens other / ant b-c e-g none / one 4G minus other / a b c'
[ "$tabref" = "$want" ] || fail "-c0: the module with the large frame: $tabref"

# is there a JIT here?  with none the bad modules load under -c1 as under -c0
if echo "$out" | grep -q '^BAD frame raised 0 nil 0 loaded '; then
	echo "jit_compile_fail_test: SKIP (no JIT here: the bad modules load under -c1)"
	exit 77
fi

echo "$out" | grep -q '^DONE$' || fail "-c1: the program did not finish: $(echo "$out" | grep -v '^fs:' | tail -3 | tr '\n' ' ' | cut -c1-300)"
if echo "$out" | grep -q 'SEGV: addr=\|BUS: addr=\|panic:\|segmentation violation'; then
	fail "-c1: the compiler faulted: $(echo "$out" | grep 'SEGV: addr=\|BUS: addr=\|panic:\|segmentation violation' | head -2 | tr '\n' ' ' | cut -c1-300)"
fi

line=$(echo "$out" | grep '^BAD bigop ')
grew=$(echo "$line" | sed -n 's/.* grew \(-\{0,1\}[0-9]*\):.*/\1/p')
if echo "$line" | grep -q "^BAD bigop raised $COUNT nil 0 loaded 0 "; then
	if [ -z "$grew" ] || [ "$grew" -gt $LIMIT ]; then
		fail "-c1: $COUNT refused compiles of sh.dis left ${grew:-?} bytes in the main pool"
	else
		pass "-c1: $COUNT refused compiles of sh.dis left $grew bytes in the main pool"
	fi
	if echo "$line" | grep -q "compile, no 'op255'\$"; then
		pass "-c1: the error names the opcode: $(echo "$line" | sed 's/.*: raised: //')"
	else
		fail "-c1: the error for opcode 255 does not name it op255: $line"
	fi
elif echo "$line" | grep -q "^BAD bigop raised 0 nil 0 loaded $COUNT "; then
	# a JIT that gives the opcode to the interpreter, which refuses it when it is run
	if [ -z "$grew" ] || [ "$grew" -gt $LIMIT ]; then
		fail "-c1: $COUNT loads of sh.dis with an opcode that is none left ${grew:-?} bytes in the main pool"
	else
		pass "-c1: sh.dis with an opcode that is none loads (this JIT leaves it to the interpreter); $grew bytes left"
	fi
else
	fail "-c1: sh.dis with an opcode that is none: $line"
fi

for k in $KINDS; do
	line=$(echo "$out" | grep "^BAD $k ")
	grew=$(echo "$line" | sed -n 's/.* grew \(-\{0,1\}[0-9]*\):.*/\1/p')
	if ! echo "$line" | grep -q "^BAD $k raised $COUNT nil 0 loaded 0 .*: raised: compile failed\$"; then
		fail "-c1: $k: not refused with \"compile failed\" each time: $line"
	elif [ -z "$grew" ] || [ "$grew" -gt $LIMIT ]; then
		fail "-c1: $k: $COUNT refused compiles left ${grew:-?} bytes in the main pool"
	else
		pass "-c1: $k: refused $COUNT times, $grew bytes left"
	fi
done
# the amd64 JIT prints the instruction it refuses: its source mode is none
if echo "$out" | grep -a -q '^movw	'; then
	if echo "$out" | grep -q '^movw	mode3, '; then
		pass "-c1: an address mode that is none is printed as mode3"
	else
		fail "-c1: the instruction with address mode 3 was not printed as such: $(echo "$out" | grep -a '^movw' | head -1 | cut -c1-80)"
	fi
fi

okl=$(echo "$out" | grep '^OK ')
[ "$okl" = "OK 1000012 3000022 125 20" ] && pass "-c1: a module that must be compiled is, after them, and runs" ||
	fail "-c1: a module that must be compiled, after the refused ones: $okl"

tab=$(echo "$out" | grep '^TABLES ')
must=$(echo "$out" | grep '^MUST ')
if [ "$tab" = "$want" ]; then
	case "$must" in
	"MUST nil: "*"compiler required"*)
		pass "-c1: the module this JIT cannot compile runs interpreted, its case and goto tables intact" ;;
	*)
		pass "-c1: the module with the large frame runs (this JIT compiles it: $must)" ;;
	esac
else
	fail "-c1: the module with the large frame ($must): $tab"
fi
exit $rc
