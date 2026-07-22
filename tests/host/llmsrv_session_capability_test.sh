#!/bin/sh
# Exercise llmsrv session capability isolation without an LLM backend.
set -eu

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
	echo "SKIP: emulator not found at $EMU"
	exit 77
fi

log="${TMPDIR:-/tmp}/llmsrv-session-capability.$$.log"
pid=
cleanup() {
	if [ -n "$pid" ]; then
		kill -9 "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	rm -f "$log"
}
trap cleanup EXIT HUP INT TERM

"$EMU" -c1 -r"$ROOT" /dis/sh.dis \
	/tests/inferno/llmsrv_model_test.sh >"$log" 2>&1 &
pid=$!

i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
	if grep -q '^PASS$' "$log" 2>/dev/null; then
		cat "$log"
		exit 0
	fi
	if grep -q '^sh: fail:' "$log" 2>/dev/null; then
		break
	fi
	sleep 1
	i=$((i + 1))
done

cat "$log"
echo "FAIL: llmsrv session capability test did not pass" >&2
exit 1
