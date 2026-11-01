#!/bin/sh
#
# settings_stall_test.sh — wm/settings with a service that never answers
# (/mnt/llm/models, the LLM panel it opens on) through tests/wm/stall.sh:
# the window still comes up, its loop still runs, and a Delete is taken
# in under wm's grace, with nothing of it left.  Its panels were built
# in its loop from blocking reads.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/settings.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

LOG=$(mktemp)
T=tmp/settings_stall_test.$$
mkdir -p "$ROOT/$T"
trap 'rm -f "$LOG"; rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/wm/stall.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
line() { grep "^R $1\( \|\$\)" "$LOG" | head -1 | cut -d' ' -f3-; }
grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; sed -n '/^R /!p' "$LOG" | head; exit 1; }
[ -n "$(line open)" ] && echo "PASS: the window came up: $(line open)" || { echo "FAIL: no window"; failed=1; }
case "$(line alive)" in
*alt*)	echo "PASS: its loop runs" ;;
*)	echo "FAIL: its loop is not running: $(line alive)"; failed=1 ;;
esac
[ -z "$(line deleted)" ] && echo "PASS: Delete took the window at once" || { echo "FAIL: still there: $(line deleted)"; failed=1; }
[ -z "$(line left)" ] && echo "PASS: nothing of it left" || { echo "FAIL: left running: $(line left)"; failed=1; }
if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
