#!/bin/sh
#
# tests/host/dp9ik_test.sh
#
# dp9ik(2), 9front's authentication, against the answers 9front 11952
# gives (tests/host/dp9ik/9front-vectors.txt, made on 9front by vecgen.c
# beside it): first the Python reference written from 9front's source
# (ref.py, which needs Python's `cryptography` for ChaCha20-Poly1305),
# then tests/dp9ik_test.b in the emulator under -c0 and -c1.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

D="$(dirname "$0")/dp9ik"
rc=0
if python3 -c 'import cryptography' 2>/dev/null; then
	if out=$(python3 "$D/ref.py" check "$D/9front-vectors.txt" 2>&1) && echo "$out" | grep -q '^PASS$'; then
		echo "PASS: ref.py gives 9front's answers"
	else
		echo "FAIL: ref.py differs from 9front:"
		echo "$out" | grep FAIL
		rc=1
	fi
else
	echo "SKIP: ref.py: no python cryptography module"
fi

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/dp9ik_test.dis" ] || { echo "SKIP: dis/tests/dp9ik_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-300}
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/dp9ik_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: dp9ik gives 9front's answers under -c$c"
		echo "$out" | grep -- '--- PASS' | sed 's/^/	/'
	else
		echo "FAIL: dp9ik under -c$c:"
		echo "$out" | grep -v sdl3 | head -30
		rc=1
	fi
done
exit $rc
