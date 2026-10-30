#!/bin/sh
#
# themefs_test.sh — the theme's current and event served (themefs,
# lucitheme's serve), through tests/theme/serve.sh: current and event
# are in /lib/lucifer/theme beside the themes' files; current reads the
# name; a reader of event gets each name written, whole, at any offset;
# a name that is no theme is refused; the last name written is kept in
# the directory's own current; a second themefs finds it served.  With
# it nothing polls the theme (watchers read event).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/themefs.dis" ] || { echo "SKIP: dis/themefs.dis not built"; exit 77; }

T=tmp/themefs_test.$$
mkdir -p "$ROOT/$T"
trap 'rm -rf "$ROOT/$T"' EXIT
printf brimstone > "$ROOT/$T/current"
cd "$ROOT"
with_timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis /tests/theme/serve.sh "/$T" \
	</dev/null >"$ROOT/$T/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$ROOT/$T/$1" 2>/dev/null || true; }

grep -q '^R done' "$ROOT/$T/log" || { fail "the driver did not finish"; tail -20 "$ROOT/$T/log"; exit 1; }

if f ls | grep -qx /lib/lucifer/theme/event && f ls | grep -qx /lib/lucifer/theme/halo; then
	pass "current and event served beside the themes' files"
else
	fail "listing: $(f ls | tr '\n' ' ')"
fi
[ "$(f cur.before)" = brimstone ] && [ "$(f cur.after)" = halo ] &&
	pass "current reads the name, and the name written" ||
	fail "current: '$(f cur.before)' then '$(f cur.after)'"
[ "$(f events | tr '\n' ' ')" = "halo brimstone " ] &&
	pass "a reader of event gets each name written, whole" ||
	fail "events: '$(f events | tr '\n' ' ')'"
f err | grep -q 'no theme nosuch' && pass "a name that is no theme is refused" ||
	fail "nosuch: '$(f err)'"
[ "$(cat "$ROOT/$T/current")" = brimstone ] && pass "the last name is kept in the directory's current" ||
	fail "kept: '$(cat "$ROOT/$T/current")'"
[ -z "$(f again)" ] && pass "a second themefs finds it served" || fail "again: $(f again)"

[ $failed = 0 ] && echo "themefs_test: PASS"
exit $failed
