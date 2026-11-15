#!/bin/sh
#
# settings_edit_test.sh — wm/settings's buttons that open a text file
# (the theme, the agent prompts, the profile, the email sources) open it
# through the plumber, so on the Desktop it lands in Xenith under wm/wm
# (tests/wm/settingsedit.sh).  They wrote to Lucifer's presentation ctl
# alone: under wm/wm there is none, and Settings said "cannot reach
# presentation zone — is luciuisrv running?".
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/settings.dis dis/xenith.dis dis/plumber.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

LOG=$(mktemp)
T=tmp/settings_edit_test.$$
mkdir -p "$ROOT/$T"
trap 'rm -f "$LOG"; rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; bind -bc '#splumber' /chan; wm/wm sh /tests/wm/settingsedit.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
line() { grep "^R $1\( \|\$\)" "$LOG" | head -1 | cut -d' ' -f3-; }
grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; sed -n '/^R /!p' "$LOG" | head; exit 1; }
nb=$(line before | wc -w); na=$(line after | wc -w)
[ "$na" -gt "$nb" ] && echo "PASS: a window opened: $(line after)" || { echo "FAIL: no window opened: $(line after)"; failed=1; }
[ -n "$(line xenith)" ] && echo "PASS: Xenith is running" || { echo "FAIL: no Xenith"; failed=1; }
if grep -q 'luciuisrv\|/mnt/ui/activity' "$LOG"; then
	echo "FAIL: Settings looked for Lucifer:"; grep 'luciuisrv\|/mnt/ui' "$LOG" | head -3; failed=1
else
	echo "PASS: Settings did not look for Lucifer"
fi
if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
