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
	budget=$4
	dir="$FIXTURE/$name"
	mkdir -p "$dir/meta"
	printf '%s\n' wallet > "$dir/tools"
	: > "$dir/paths"
	printf '%s\n' "$role" > "$dir/meta/role"
	printf '%s\n' 0 > "$dir/meta/xenith"
	printf '%s\n' 0 > "$dir/meta/actid"
	if [ "$nodevs" != MISSING ]; then
		printf '%s\n' "$nodevs" > "$dir/meta/nodevs"
	fi
	if [ "$budget" != MISSING ]; then
		printf '%s\n' "$budget" > "$dir/walletbudget"
	fi
}

check_case()
{
	name=$1
	nodevs_status=$2
	wallet_status=$3
	nodevs_violation=$4
	wallet_violation=$5
	log="/tmp/nsaudit-metadata-$name-$$.log"
	"$EMU" -r"$ROOT" "$SH" -c \
		"path=(/dis/veltro /dis/cmd /dis .); nsaudit -m /tests/.nsaudit-metadata-$$/$name" \
		</dev/null >"$log" 2>&1

	ok=yes
	grep -q "nodevs_status=$nodevs_status" "$log" || ok=no
	grep -q "walletbudget_status=$wallet_status" "$log" || ok=no
	if [ "$nodevs_violation" = NONE ]; then
		grep -q 'violation=DEVICE_GATE_BYPASS\|violation=SUBAGENT_MISSING_NODEVS' "$log" && ok=no
	else
		grep -q "violation=$nodevs_violation" "$log" || ok=no
	fi
	if [ "$wallet_violation" = NONE ]; then
		grep -q 'violation=UNBOUNDED_SPEND' "$log" && ok=no
	else
		grep -q "violation=$wallet_violation" "$log" || ok=no
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

MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
OVERFLOW=115792089237316195423570985008687907853269984665640564039457584007913129639936

make_fixture nodevs-set toplevel set '1 USDC'
make_fixture nodevs-unset toplevel unset '1 USDC'
make_fixture nodevs-missing toplevel MISSING '1 USDC'
make_fixture nodevs-empty toplevel '' '1 USDC'
make_fixture nodevs-uppercase toplevel SET '1 USDC'
make_fixture nodevs-junk child arbitrary '1 USDC'

make_fixture budget-missing child set MISSING
make_fixture budget-empty child set ''
make_fixture budget-zero child set '0 USDC'
make_fixture budget-negative child set '-1 USDC'
make_fixture budget-junk child set not-a-budget
make_fixture budget-whitespace child set '   '
make_fixture budget-trailing child set '1 USDC junk'
make_fixture budget-overflow child set "$OVERFLOW USDC"
make_fixture budget-min child set '1 USDC'
make_fixture budget-max child set "$MAX ETH"

check_case nodevs-set valid bounded NONE NONE
check_case nodevs-unset valid bounded DEVICE_GATE_BYPASS NONE
check_case nodevs-missing missing bounded DEVICE_GATE_BYPASS NONE
check_case nodevs-empty missing bounded DEVICE_GATE_BYPASS NONE
check_case nodevs-uppercase invalid bounded DEVICE_GATE_BYPASS NONE
check_case nodevs-junk invalid bounded SUBAGENT_MISSING_NODEVS NONE

check_case budget-missing valid missing NONE UNBOUNDED_SPEND
check_case budget-empty valid missing NONE UNBOUNDED_SPEND
check_case budget-zero valid invalid NONE UNBOUNDED_SPEND
check_case budget-negative valid invalid NONE UNBOUNDED_SPEND
check_case budget-junk valid invalid NONE UNBOUNDED_SPEND
check_case budget-whitespace valid missing NONE UNBOUNDED_SPEND
check_case budget-trailing valid invalid NONE UNBOUNDED_SPEND
check_case budget-overflow valid invalid NONE UNBOUNDED_SPEND
check_case budget-min valid bounded NONE NONE
check_case budget-max valid bounded NONE NONE

echo "Total: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
