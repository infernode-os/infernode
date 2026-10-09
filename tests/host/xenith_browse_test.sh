#!/bin/sh
#
# xenith_browse_test.sh — Xenith browses: a URL opened is a browser
# window whose links, Back, Fwd, Get and Render work.  The pages are
# file: URLs and, through webfs, the same pages served over HTTP by a
# server on the loopback (skipped without python3).
#
# Runs tests/inferno/xenith_browse_test.sh inside a headless Xenith
# (xenith_inside.sh). Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

# The pages over HTTP: the port goes to the script in tmp/
_port="$ROOT/tmp/xenith_browse.port"
rm -f "$_port"
_srv=
if command -v python3 >/dev/null 2>&1; then
    mkdir -p "$ROOT/tmp"
    _log=$(mktemp)
    python3 -u -m http.server --bind 127.0.0.1 --directory "$ROOT/tests/xenith/html" 0 >"$_log" 2>&1 &
    _srv=$!
    i=0
    while [ $i -lt 50 ] && ! grep -q 'port' "$_log"; do sleep 0.1; i=$((i + 1)); done
    sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$_log" | head -1 > "$_port"
fi

XENITH_INSIDE_NET=1 xenith_inside xenith_browse /tests/inferno/xenith_browse_test.sh
rc=$?
[ -n "$_srv" ] && kill "$_srv" 2>/dev/null
rm -f "$_port" "$_log"
exit $rc
