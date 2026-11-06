#!/bin/sh
#
# wm_camera_test.sh -- wm/camera lets go of the camera while hidden: wm/wm's
# Hide sends the window "visible 0", wm/camera closes the feed, and with no
# other reader camsrv(4) stops streaming; unhidden, it takes the feed back.
# A feed turned (camsrv's rotate) while the window was hidden is shown at
# its new size. Over camsrv -t, so no camera is needed; driven by
# tests/wm/camera.sh.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/camera.dis dis/camsrv.dis dis/mntgen.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

LOG=$(mktemp)
T=tmp/wm_camera_test.$$
mkdir -p "$ROOT/$T"
trap 'rm -f "$LOG"; rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/wm/camera.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
check() {
	if grep -q "^R $1 .*stream=$2" "$LOG"; then
		echo "PASS: $3"
	else
		echo "FAIL: $3 -- $(grep "^R $1 " "$LOG" | head -1)"; failed=1
	fi
}
check shown on "shown, the window streams"
check hidden off "hidden, it lets go and the camera stops"
check unhidden on "shown again, it takes the feed back"
# turned (rotate 90) while hidden: shown again, the window is the turned size
if grep -q "^R turned 0 0 0 170 296" "$LOG"; then
	echo "PASS: turned while hidden, the window takes the turned size"
else
	echo "FAIL: turned while hidden -- $(grep '^R turned' "$LOG" | head -1)"; failed=1
fi
exit $failed
