#!/bin/sh
#
# editor_deputy_test.sh — the editor tool reads and writes files with the
# agent's authority, and the editor writes none for it.
#
# The editor (wm/editor) is the user's program in the user's name space;
# the editor tool drives it through its served files.  The tool used to
# check a path's spelling against the agent's grants and then tell the
# editor to open or save that path itself.  There the path is another
# file and nothing is read-only: "open X", "write T", "close" wrote T to
# any X the agent could see (the editor's quit saved a changed document
# under its name), a read-only grant included; and a name in the scratch
# directory, which is each activity's own in a tool's name space, was the
# shared directory's in the editor's, so one activity read and wrote
# another's scratch file through a file of the same name in its own.
# The editor's ctl files also ran each 9P message of a long request as a
# command of its own, so the end of a long "insert", the agent's text,
# was run as one ("saveas <any path>").
#
# Here, with a real editor and tools9p for activity 5 holding a
# read-only grant: a long insert is refused by the tool and, written to
# the editor's ctl directly, is one insert; a file of activity 7's in the
# shared scratch directory is neither read nor written through a file of
# that name in activity 5's; a file under the read-only grant is opened,
# changed and closed, and is as it was.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/editor.dis dis/veltro/tools9p.dis dis/veltro/tools/editor.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/tmp/veltro/scratch/7" "$H/ro"
echo ORIGINAL > "$H/ro/target.txt"
echo 'ACTIVITY-7 NOTE' > "$H/tmp/veltro/scratch/7/secret.txt"
# a request whose second 9P message is a command if taken alone
python3 - "$H/tmp" <<'PY'
import sys
d = sys.argv[1]
for name, head, tail in (
	('long.tool', 'insert 1 1 ', 'saveas /tmp/planted-by-tool'),
	('long.ctl', 'insert 1 1 ', 'saveas /tmp/planted-direct'),
):
	open(d + '/' + name, 'w').write(head + 'x' * (8192 - len(head)) + tail)
PY

RO=/n/local$H/ro/target.txt
SC=/tmp/veltro/scratch/7/secret.txt
cat > "$H/tmp/drv.sh" <<DRV
load std
path=(/dis/veltro /dis/cmd /dis .)
mount -ac {mntgen} /n
bind '#U*' /n/local
wm/editor >[2] /tmp/editor.err &
sleep 3
tools9p -a 5 -p /n/local$H/ro:ro editor read write >[2] /tmp/tools9p.err &
sleep 4
echo '== LONG-TOOL'; cat /tmp/long.tool > /tool/editor/run; cat /tool/editor/run; echo
echo '== LONG-CTL'; cat /tmp/long.ctl > /edit/1/ctl; echo status \$status
echo '== LONG-BODY'; cat /edit/1/body | wc -c
echo '== SC-DECOY'; echo $SC decoy of activity 5 > /tool/write/run; cat /tool/write/run; echo
echo '== SC-OPEN'; echo open $SC > /tool/editor/run; cat /tool/editor/run; echo
echo '== SC-READ'; echo read > /tool/editor/run; cat /tool/editor/run; echo
echo '== SC-WRITE'; echo write CHANGED BY 5 > /tool/editor/run; cat /tool/editor/run; echo
echo '== SC-SAVE'; echo save > /tool/editor/run; cat /tool/editor/run; echo
echo '== SC-INDEX'; cat /edit/index; echo
echo '== RO-OPEN'; echo open $RO > /tool/editor/run; cat /tool/editor/run; echo
echo '== RO-READ'; echo read > /tool/editor/run; cat /tool/editor/run; echo
echo '== RO-WRITE'; echo write PWNED through the editor > /tool/editor/run; cat /tool/editor/run; echo
echo '== RO-SAVE'; echo save > /tool/editor/run; cat /tool/editor/run; echo
echo '== RO-CLOSE'; echo close > /tool/editor/run; cat /tool/editor/run; echo
echo '== RO-ALIVE'; echo status > /tool/editor/run; cat /tool/editor/run; echo
echo '== CLEAN-OPEN'; echo open $SC > /tool/editor/run; cat /tool/editor/run; echo
echo '== CLEAN-CLOSE'; echo close > /tool/editor/run; cat /tool/editor/run; echo
echo '== DONE'
echo halt > /dev/sysctl
DRV

LOG=$H/log
with_timeout 150 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "bind -c '#U*$H/tmp' /tmp; run /tmp/drv.sh" </dev/null >"$LOG" 2>&1 || true
grep -q '^== DONE' "$LOG" || { echo "FAIL: the driver did not finish"; tail -30 "$LOG"; exit 1; }

sec() {	# the lines of a section
	sed -n "/^== $1\$/,/^== /p" "$LOG" | sed '1d;/^== /d'
}
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
has() {	# description, section, pattern
	if sec "$2" | grep -q "$3"; then pass "$1"; else fail "$1 ($2: $(sec "$2" | head -3 | tr '\n' ' '))"; fi
}
is() {	# description, file, wanted
	if [ -f "$2" ] && [ "$(cat "$2")" = "$3" ]; then pass "$1"; else fail "$1 ($2: $(cat "$2" 2>&1 | head -2))"; fi
}

# a long request
has "an insert longer than one message is refused by the tool" LONG-TOOL '^error:.*too long'
[ ! -e "$H/tmp/planted-by-tool" ] && pass "and its end is not run as a command" || fail "the end of a long insert was run: planted-by-tool"
[ ! -e "$H/tmp/planted-direct" ] && pass "one written to the editor's ctl is one command" || fail "the end of a long request to the editor's ctl was run: planted-direct"
n=$(sec LONG-BODY | tr -d ' \n')
[ "${n:-0}" -gt 8192 ] && pass "the whole of it was inserted ($n bytes)" || fail "the long insert was not the body ($n bytes)"

# another activity's scratch
has "activity 5 makes a file in its scratch directory" SC-DECOY '^wrote'
has "and opens it" SC-OPEN '^ok'
has "the editor shows activity 5's file" SC-READ '^decoy of activity 5'
sec SC-READ | grep -q 'ACTIVITY-7' && fail "activity 7's file was read through the editor" || pass "not activity 7's of the same name"
has "it is changed and saved" SC-SAVE '^ok'
has "the editor has it saved" SC-INDEX "^1 $SC 0"
is "in activity 5's scratch directory" "$H/tmp/veltro/scratch/5/7/secret.txt" 'CHANGED BY 5'
is "activity 7's file is as it was" "$H/tmp/veltro/scratch/7/secret.txt" 'ACTIVITY-7 NOTE'

# a read-only grant
has "a file under a read-only grant opens" RO-OPEN '^ok'
has "and is read" RO-READ '^ORIGINAL'
has "its text is changed in the editor" RO-WRITE '^ok'
has "save is refused: the file is read-only" RO-SAVE 'is read-only'
has "close is refused with the text unsaved" RO-CLOSE '^error:.*unsaved'
has "the editor is still there" RO-ALIVE "^1 $RO 1"
is "the file is as it was" "$H/ro/target.txt" ORIGINAL
has "a document with nothing unsaved" CLEAN-OPEN '^ok'
has "is closed" CLEAN-CLOSE '^ok'

if [ "$FAILED" -ne 0 ]; then
	cat "$LOG"
	echo "editor_deputy_test: $FAILED failed"
	exit 1
fi
echo "editor_deputy_test: PASS"
