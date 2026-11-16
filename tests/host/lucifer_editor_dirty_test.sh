#!/bin/sh
#
# Lucifer's editor keeps unsaved changes whoever opens a file in it.
# Matrix's `edit` wrote `create id=editor` whatever was there, which
# luciuisrv refuses while one runs, so a second composition never
# opened (and wm/editor's `open`, which lucictx sends, replaced unsaved
# text with the file); it now plumbs
# the file (lucipres's plumbeditor is the one policy) and, with no
# plumber, gives the running editor the file only when its document is
# clean.  wm/editor's own `open` refuses a document with unsaved changes,
# for every caller (lucictx, the agent's editor tool).
#
# Two boots of Lucifer (SDL dummy, a HOME of its own, skiplogon=1), the
# second with $noplumber=1, each driven by tests/wm/editordirty_lucifer.sh:
# Matrix opens its composition in the editor, the editor is typed into,
# Matrix opens another composition: the first editor and its text are
# kept and the second file has an editor of its own.  Then the editor is
# asked to open a file over its unsaved text and refuses; the file it
# holds is taken, and once `clean` the next file is.
#
set -e
. "$(dirname "$0")/common.sh"
set -u
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/lucipres.dis dis/wm/editor.dis dis/wm/matrix.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

LOG=$(mktemp)
H=$(mktemp -d)
trap 'rm -f "$LOG"; rm -rf "$H"' EXIT
mkdir -p "$H/tmp"
cp "$ROOT/tests/wm/editordirty_lucifer.sh" "$H/tmp/drv.sh"

set +e
failed=0
C=/lib/matrix/compositions
for mode in plumber noplumber; do
	pre="skiplogon=1"
	[ $mode = noplumber ] && pre="skiplogon=1; noplumber=1"
	SDL_VIDEODRIVER=dummy HOME=$H with_timeout 300 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
		/dis/sh.dis -l -c "$pre; run /lib/lucifer/boot.sh & sleep 45; run /tmp/drv.sh" \
		</dev/null >"$LOG" 2>&1 || true

	grep -q '^R done' "$LOG" || { echo "FAIL: $mode: the driver did not finish"; grep -v '^R ' "$LOG" | tail -n 15; failed=1; continue; }
	grep -q '^R nomatrix' "$LOG" && { echo "FAIL: $mode: Matrix's ctl is not in the driver's name space"; failed=1; continue; }
	cur() { grep "^R $1 current" "$LOG" | head -1 | cut -d' ' -f4; }
	doc() { grep -F "R $1 posted $2 " "$LOG" | head -1 | cut -d' ' -f5-; }
	neditors() { grep "^R $1 art .*/dis/wm/editor.dis" "$LOG" | wc -l; }
	said() { grep -q "^R $1 $2\$" "$LOG"; }

	[ "$(neditors start)" -eq 0 ] || { echo "FAIL: $mode: an editor before any was asked for"; failed=1; }
	[ "$(cur first)" = editor ] && [ "$(doc first fs)" = "1 $C/tk-demo 0" ] && [ "$(neditors first)" -eq 1 ] \
		&& echo "PASS: $mode: Matrix's edit starts the editor on its composition" \
		|| { echo "FAIL: $mode: first edit: current $(cur first), editors $(neditors first), editor has: $(doc first fs)"; failed=1; }
	[ "$(doc typed fs)" = "1 $C/tk-demo 1" ] \
		&& echo "PASS: $mode: typing into the editor leaves it unsaved" \
		|| { echo "FAIL: $mode: typing did not reach the editor: $(doc typed fs)"; failed=1; }
	if [ "$(doc second fs)" = "1 $C/tk-demo 1" ] && [ "$(cur second)" != editor ] \
		&& [ "$(doc second fs.1)" = "1 $C/sysmon 0" ] && [ "$(neditors second)" -eq 2 ]; then
		echo "PASS: $mode: unsaved changes kept; Matrix's next file in an editor of its own ($(cur second))"
	else
		echo "FAIL: $mode: second edit: current $(cur second), editors $(neditors second), editor has $(doc second fs), next has $(doc second fs.1)"; failed=1
	fi
	said other refused && [ "$(doc direct fs)" = "1 $C/tk-demo 1" ] \
		&& echo "PASS: $mode: the editor refuses to open a file over unsaved changes" \
		|| { echo "FAIL: $mode: open over unsaved changes: $(grep '^R other' "$LOG"), editor has $(doc direct fs)"; failed=1; }
	said same taken \
		&& echo "PASS: $mode: opening the file it holds is taken, the changes kept" \
		|| { echo "FAIL: $mode: opening the file it holds: $(grep '^R same' "$LOG")"; failed=1; }
	said clean taken && [ "$(doc clean fs)" = "1 /lib/sh/profile 0" ] \
		&& echo "PASS: $mode: once clean, the editor takes the next file" \
		|| { echo "FAIL: $mode: after clean: $(grep '^R clean' "$LOG" | head -1), editor has $(doc clean fs)"; failed=1; }
done

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
