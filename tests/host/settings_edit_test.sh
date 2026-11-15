#!/bin/sh
#
# settings_edit_test.sh — wm/settings's buttons that open a text file
# (the theme, the agent prompts, the profile, the email account) open it
# through the plumber, wherever Settings runs:
#
# On the Desktop (tests/wm/settingsedit.sh) it lands in Xenith under
# wm/wm.  They wrote to Lucifer's presentation ctl alone: under wm/wm
# there is none, and Settings said "cannot reach presentation zone — is
# luciuisrv running?".
#
# In Lucifer (tests/wm/settingsedit_lucifer.sh, a whole boot) every
# button's file goes to the one editor, `editor`, in turn, as it did
# before (plumbed, each had opened another editor); a missing email
# account file is made, in the user's own lib, and opened (it was "not
# accessible"); an editor with unsaved changes keeps them and the next
# file gets an editor of its own; an editor killed is started again.
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

# ── Lucifer ──
for f in dis/lucifer.dis dis/lucipres.dis dis/wm/editor.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
H=$(mktemp -d)
trap 'rm -f "$LOG"; rm -rf "$ROOT/$T" "$H"' EXIT
mkdir -p "$H/tmp"
cp "$ROOT/tests/wm/settingsedit_lucifer.sh" "$H/tmp/drv.sh"
SDL_VIDEODRIVER=dummy HOME=$H with_timeout 300 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; run /tmp/drv.sh" \
	</dev/null >"$LOG" 2>&1 || true

grep -q '^R done' "$LOG" || { echo "FAIL: the Lucifer driver did not finish"; grep -v '^R ' "$LOG" | tail -n 15; exit 1; }
cur() { grep "^R $1 current" "$LOG" | head -1 | cut -d' ' -f4; }
doc() { grep -F "R $1 posted $2 " "$LOG" | head -1 | cut -d' ' -f5-; }
neditors() { grep "^R $1 art .*/dis/wm/editor.dis" "$LOG" | wc -l; }
for s in theme:/lib/lucifer/theme/brimstone theme2:/lib/lucifer/theme/brimstone \
	meta:/lib/veltro/meta.txt task:/lib/veltro/agents/task.txt \
	profile:/lib/sh/profile email:/lib/veltro/sources/email.conf; do
	step=${s%%:*} file=${s#*:}
	if [ "$(cur $step)" = editor ] && [ "$(doc $step fs)" = "1 $file 0" ] && [ "$(neditors $step)" -eq 1 ]; then
		echo "PASS: $step: $file in the one editor, shown"
	else
		echo "FAIL: $step: current $(cur $step), editors $(neditors $step), editor has: $(doc $step fs)"; failed=1
	fi
done
[ -f "$H/.infernode/lib/veltro/sources/email.conf" ] \
	&& echo "PASS: the email account file was made in the user's lib" \
	|| { echo "FAIL: no email.conf under the user's lib"; failed=1; }
[ "$(doc typed fs)" = "1 /lib/veltro/sources/email.conf 1" ] \
	&& echo "PASS: typing into the editor leaves it unsaved" \
	|| { echo "FAIL: typing did not reach the editor: $(doc typed fs)"; failed=1; }
if [ "$(doc dirty fs)" = "1 /lib/veltro/sources/email.conf 1" ] && [ "$(cur dirty)" != editor ] \
	&& [ "$(doc dirty fs.1)" = "1 /lib/lucifer/theme/brimstone 0" ]; then
	echo "PASS: unsaved changes kept; the next file in an editor of its own ($(cur dirty))"
else
	echo "FAIL: unsaved changes: current $(cur dirty), editor has $(doc dirty fs), next has $(doc dirty fs.1)"; failed=1
fi
[ "$(cur reopen)" = editor ] && [ "$(doc reopen fs)" = "1 /lib/veltro/meta.txt 0" ] \
	&& echo "PASS: the editor killed, the next file starts it again" \
	|| { echo "FAIL: after the editor was killed: current $(cur reopen), $(doc reopen fs)"; failed=1; }
if grep -q 'luciuisrv running\|not accessible' "$LOG"; then
	echo "FAIL: Settings refused a file:"; grep 'luciuisrv running\|not accessible\|settings:' "$LOG" | head -3; failed=1
fi

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
