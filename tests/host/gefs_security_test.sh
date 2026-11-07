#!/bin/sh
# A hostile disk may recompute GEFS's unkeyed checksums. Its lengths,
# offsets and chains must still fail closed, without a bounds exception or hang.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "gefs_security_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/disk/gefs.dis" ] || { echo "gefs_security_test: SKIP (no dis/disk/gefs.dis)"; exit 77; }

dir=$(mktemp -d "$ROOT/.gefs-security.XXXXXX")
trap 'rm -rf "$dir"' EXIT
n=/${dir##*/}
truncate -s 256M "$dir/base.img" 2>/dev/null || dd if=/dev/zero of="$dir/base.img" bs=1048576 count=0 seek=256 2>/dev/null

out=$(with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
disk/gefs -r security $n/base.img
echo REAM \$status
echo halt > /dev/sysctl" 2>&1)
printf '%s\n' "$out" | grep -q '^REAM ' || {
	echo "FAIL: gefs security: could not ream fixture"
	printf '%s\n' "$out" | tail -30
	exit 1
}

python3 tests/host/gefs_security_image.py "$dir/base.img" "$dir/loglen.img" log-length
python3 tests/host/gefs_security_image.py "$dir/base.img" "$dir/cycle.img" log-cycle
python3 tests/host/gefs_security_image.py "$dir/base.img" "$dir/deadcycle.img" deadlist-cycle
python3 tests/host/gefs_security_image.py "$dir/base.img" "$dir/tree.img" tree-count
python3 tests/host/gefs_security_image.py "$dir/base.img" "$dir/negative.img" negative-length

fail=0
runbad() {
	image=$1
	want=$2
	name=$3
	out=$(with_timeout 30 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
disk/gefs -c $n/$image
echo STATUS \$status
echo halt > /dev/sysctl" 2>&1)
	if printf '%s\n' "$out" | grep -Fq "$want" \
	&& ! printf '%s\n' "$out" | grep -Eq 'module exception|bounds error'; then
		echo "PASS: gefs security: $name is rejected cleanly"
	else
		echo "FAIL: gefs security: $name"
		printf '%s\n' "$out" | tail -30
		fail=1
	fi
}

runbad loglen.img 'invalid log length' 'oversized log length'
runbad cycle.img 'cyclic arena log' 'cyclic allocation log'
runbad deadcycle.img 'cyclic log chain' 'cyclic deadlist'
runbad tree.img 'invalid value count' 'checksum-valid invalid tree count'
runbad negative.img 'invalid directory value' 'checksum-valid negative file length'

exit "$fail"
