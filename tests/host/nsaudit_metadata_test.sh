#!/bin/sh
# Fail-closed parsing tests for security-critical nsaudit metadata.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH=/dis/sh.dis
FIXTURE="$ROOT/tests/.nsaudit-metadata-$$"
PASSED=0
FAILED=0

cleanup()
{
	rm -rf "$FIXTURE"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$EMU" ] || [ ! -f "$ROOT/dis/nsaudit.dis" ]; then
	echo "SKIP: emulator or nsaudit.dis not built"
	exit 77
fi

make_fixture()
{
	name=$1
	role=$2
	nodevs=$3
	dir="$FIXTURE/$name"
	mkdir -p "$dir/meta"
	printf '%s\n' read > "$dir/tools"
	: > "$dir/paths"
	printf '%s\n' "$role" > "$dir/meta/role"
	printf '%s\n' 0 > "$dir/meta/xenith"
	printf '%s\n' 0 > "$dir/meta/actid"
	if [ "$nodevs" != MISSING ]; then
		printf '%s\n' "$nodevs" > "$dir/meta/nodevs"
	fi
}

check_case()
{
	name=$1
	nodevs_status=$2
	nodevs_violation=$3
	log="/tmp/nsaudit-metadata-$name-$$.log"
	"$EMU" -r"$ROOT" "$SH" -c \
		"path=(/dis/veltro /dis/cmd /dis .); nsaudit -m /tests/.nsaudit-metadata-$$/$name" \
		</dev/null >"$log" 2>&1

	ok=yes
	grep -q "nodevs_status=$nodevs_status" "$log" || ok=no
	if [ "$nodevs_violation" = NONE ]; then
		grep -q 'violation=DEVICE_GATE_BYPASS\|violation=SUBAGENT_MISSING_NODEVS' "$log" && ok=no
	else
		grep -q "violation=$nodevs_violation" "$log" || ok=no
	fi
	if [ "$ok" = yes ]; then
		echo "PASS: $name"
		PASSED=$((PASSED + 1))
	else
		echo "FAIL: $name"
		cat "$log"
		FAILED=$((FAILED + 1))
	fi
	rm -f "$log"
}

make_fixture nodevs-set toplevel set
make_fixture nodevs-unset toplevel unset
make_fixture nodevs-missing toplevel MISSING
make_fixture nodevs-empty toplevel ''
make_fixture nodevs-uppercase toplevel SET
make_fixture nodevs-junk child arbitrary

check_case nodevs-set valid NONE
check_case nodevs-unset valid DEVICE_GATE_BYPASS
check_case nodevs-missing missing DEVICE_GATE_BYPASS
check_case nodevs-empty missing DEVICE_GATE_BYPASS
check_case nodevs-uppercase invalid DEVICE_GATE_BYPASS
check_case nodevs-junk invalid SUBAGENT_MISSING_NODEVS

echo "Total: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
