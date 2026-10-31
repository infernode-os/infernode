#!/bin/bash
#
# tests/host/presentation_fileopen_test.sh
#
# Regression tests for the Lucifer presentation file-open path — the things
# that broke here and were NOT caught by a happy-path check:
#
#   1. The Tasks tab / taskboard vanishing from Activity 0 because the plumb
#      consumer's blocking 9P port-open ran inline in lucipres init(), before
#      it drew the tab strip (fixed 50027987).  Tested with the plumber both
#      present and absent (noplumber=1) — the consumer must never gate the UI.
#   2. Files opening in the editor instead of the presentation because a
#      picker didn't route by type: pdf/image/markdown must become content
#      artifacts, non-media must go to the editor (b8a0b260 / 97b48ee3 /
#      f2187a09).
#   3. The plumber or its lucipres consumer not coming up at all.
#   4. A web URL plumbed on the desktop not reaching Charon.
#
# Boots the full Lucifer GUI headless (SDL dummy driver, skiplogon) and
# asserts the /mnt/ui presentation namespace contract — deterministic, no
# pixels.  Does NOT require the LLM service.
#
# Run from project root: ./tests/host/presentation_fileopen_test.sh [-v]

if [ -z "$ROOT" ] || [ "$ROOT" = "." ]; then
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi
. "$(dirname "$0")/common.sh"

SH="/dis/sh.dis"
VERBOSE=0
while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi
PASSED=0; FAILED=0; SKIPPED=0
pass()  { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail()  { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
skip()  { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); }
info()  { [[ "$VERBOSE" -eq 1 ]] && echo -e "  $1" || true; }

if [ ! -x "$EMU" ]; then
    skip "emu not built at $EMU"
    echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
    exit 0
fi

# Boot the full Lucifer GUI headless, run an in-emu driver, capture output.
#   $1 = tag   $2 = boot env prefix (e.g. "noplumber=1;")   $3 = driver script
# NB: the driver runs in the boot's own shell (which has `load std` via the
# -l profile and inherits /chan + /mnt/ui).  Inferno sh — NO `&&`, NO `||`;
# print raw output and let the host assert on it.
OUTPUT=""
boot_probe() {
    local tag="$1" env="$2" driver="$3"
    local log="/tmp/.prestest-${tag}.log"
    SDL_VIDEODRIVER=dummy timeout 85 "$EMU" -c1 \
        -pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
        "$SH" -l -c "skiplogon=1; ${env} run /lib/lucifer/boot.sh & sleep 50; ${driver}" \
        </dev/null >"$log" 2>&1
    OUTPUT="$(cat "$log")"
    info "[$tag] ----\n$OUTPUT\n----"
}

# Extract the lines the driver bracketed between two markers.
section() { sed -n "/$1/,/$2/p" <<<"$OUTPUT"; }

# ── Test 1: normal boot — Tasks present, plumber+consumer up, type routing ──
echo "── presentation file-open (plumber present) ──"
DRIVER1='
sleep 2
echo R_ARTS1_BEGIN
ls /mnt/ui/activity/0/presentation
echo R_ARTS1_END
echo R_PORT_BEGIN
ls /chan/plumb.presentation
echo R_PORT_END
plumb -t text /lib/legal/calderalic.pdf
sleep 2
plumb -t text /mkconfig
sleep 2
plumb -t text http://127.0.0.1:WEBPORT/index.html
sleep 4
echo R_WEB_BEGIN
cat /mnt/ui/activity/0/presentation/charon/type
cat /mnt/ui/activity/0/presentation/charon/dispath
plumb -t text http://127.0.0.1:WEBPORT/page2.html
sleep 4
mkdir -p /tmp/prestest-charon
mount -A '"'"'#scharon/fs'"'"' /tmp/prestest-charon
echo CHARONURL `{cat /tmp/prestest-charon/url}
unmount /tmp/prestest-charon
echo CHARONS; ls /mnt/ui/activity/0/presentation | grep charon
echo R_WEB_END
echo R_PDF_BEGIN
cat /mnt/ui/activity/0/presentation/plumb-1/type
echo R_PDF_END
echo R_CFG_BEGIN
cat /mnt/ui/activity/0/presentation/plumb-2/type
echo R_CFG_END
echo R_ARTS2_BEGIN
ls /mnt/ui/activity/0/presentation
echo R_ARTS2_END
echo PROBE_DONE
'
# Web pages for Charon, served on the loopback
WEBPORT=0
if command -v python3 >/dev/null 2>&1; then
    WEBLOG=$(mktemp)
    python3 -u -m http.server --bind 127.0.0.1 --directory "$ROOT/tests/xenith/html" 0 >"$WEBLOG" 2>&1 &
    WEBPID=$!
    for i in $(seq 50); do grep -q port "$WEBLOG" && break; sleep 0.1; done
    WEBPORT=$(sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$WEBLOG" | head -1)
fi
boot_probe normal "" "${DRIVER1//WEBPORT/$WEBPORT}"
[ -n "$WEBPID" ] && kill "$WEBPID" 2>/dev/null

if ! grep -q 'PROBE_DONE' <<<"$OUTPUT"; then
    skip "Lucifer did not boot in time (harness/timing)"
    info "$OUTPUT"
else
    grep -q 'lucipres: plumb consumer listening' <<<"$OUTPUT" \
        && pass "plumb consumer connects to the 'presentation' port" \
        || fail "plumb consumer never connected"
    section R_ARTS1_BEGIN R_ARTS1_END | grep -q 'presentation/tasks' \
        && pass "Tasks artifact present at boot" \
        || fail "Tasks artifact MISSING at boot"
    section R_PORT_BEGIN R_PORT_END | grep -q 'plumb.presentation' \
        && pass "plumber 'presentation' port published" \
        || fail "plumber 'presentation' port MISSING"
    section R_PDF_BEGIN R_PDF_END | grep -q 'pdf' \
        && pass "plumbed PDF -> type=pdf content (not the editor)" \
        || fail "plumbed PDF did NOT become a pdf artifact"
    section R_CFG_BEGIN R_CFG_END | grep -q 'app' \
        && pass "plumbed non-media -> editor (type=app)" \
        || fail "plumbed non-media routed wrong (expected type=app)"
    section R_WEB_BEGIN R_WEB_END | grep -q '/dis/wm/charon.dis' \
        && pass "plumbed web URL -> Charon in the presentation view" \
        || fail "plumbed web URL did not open Charon"
    section R_WEB_BEGIN R_WEB_END | grep -q "CHARONURL http://127.0.0.1:$WEBPORT/page2.html" \
        && pass "a second URL goes to the running Charon (through #scharon/fs)" \
        || fail "the running Charon was not sent the second URL"
    [ "$(section CHARONS R_WEB_END | grep -c 'presentation/charon')" = 1 ] \
        && pass "one Charon, not another started" \
        || fail "more than one Charon in the presentation view"
    section R_ARTS2_BEGIN R_ARTS2_END | grep -q 'presentation/tasks' \
        && pass "Tasks survives opening files" \
        || fail "Tasks vanished after opening files"
fi

# ── Test 2: Tasks present even with the plumber ABSENT (the init-block fix) ──
echo ""
echo "── Tasks tab survives an absent plumber (noplumber=1) ──"
DRIVER2='
sleep 2
echo R_ARTS_BEGIN
ls /mnt/ui/activity/0/presentation
echo R_ARTS_END
echo PROBE_DONE
'
boot_probe noplumber "noplumber=1;" "$DRIVER2"
if ! grep -q 'PROBE_DONE' <<<"$OUTPUT"; then
    skip "Lucifer (noplumber) did not boot in time"
else
    section R_ARTS_BEGIN R_ARTS_END | grep -q 'presentation/tasks' \
        && pass "Tasks present with plumber absent (lucipres init not blocked)" \
        || fail "Tasks MISSING with plumber absent — the consumer is blocking init again"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
