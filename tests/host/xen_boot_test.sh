#!/bin/sh
#
# xen_boot_test.sh — lib/xen/boot.sh, the standalone Xenith's entry point.
#
# Runs boot.sh as tools/xen and the Xenith apps do (after the profile,
# with Xenith's arguments), headless (SDL dummy driver), with
# /lib/ndb/llm naming the scripted model.  Xenith gets a dump file whose
# one window runs a driver in Xenith's name space; the driver checks that
# the plumber and the model are there, plumbs a file, and finds it open
# in a window.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/llmsrv.dis dis/xenith.dis dis/plumber.dis dis/plumb.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display to run Xenith on"
	exit 77
fi

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
DRIVER=
OUT="$WORK/out"
DUMP="$ROOT/tmp/xen-boot-test.dump"
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ "${KEEP:-0}" = 1 ] && return 0
	[ -z "$DRIVER" ] || rm -f "$DRIVER"
	rm -rf "$ROOT/usr/xenboot" "$DUMP" "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/xenboot"
mkdir -p "$ROOT/usr/xenboot" "$ROOT/tmp"
echo alpha > "$ROOT/usr/xenboot/a.txt"

# What runs inside Xenith: the services checked, a file plumbed, the
# windows listed.
DRIVER="$ROOT/tests/inferno/.xen-boot-driver.$$.sh"
cat > "$DRIVER" <<'EOF'
#!/dis/sh.dis
load std
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 {
	if {! ftest -e /mnt/llm/new} {
		sleep 1
	}
}
plumb /usr/xenboot/a.txt
found=
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $#found 0} {
		for w in `{ls /chan} {
			if {ftest -f $w/tag} {
				if {grep -s '^/usr/xenboot/a.txt' $w/tag} {
					found=$w
				}
			}
		}
		sleep 1
	}
}
{
	echo '@@ chan'
	ls /chan
	echo '@@ llm'
	ls /mnt/llm
	echo '@@ window'
	echo $found
	echo '@@ body'
	if {! ~ $#found 0} {
		cat $found/body
	}
	echo '@@ end'
	echo DRIVER_DONE
} > /n/local@OUT@
EOF
# The profile unions $HOME/tmp over /tmp, so the result is written to
# the host's file through /n/local.
sed "s#@OUT@#$OUT#" "$DRIVER" > "$DRIVER.new" && mv "$DRIVER.new" "$DRIVER"
chmod +x "$DRIVER"

# The dump: a working directory, no fonts, one column, one window
# running the driver (an 'e' line is an external command's window).
{
	printf '/usr/xenboot\n\n\n'
	printf '%11d \n' 0
	printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0
	printf 'ctl\n'
	printf '/usr/xenboot\n'
	printf 'sh /tests/inferno/%s\n' "$(basename "$DRIVER")"
} > "$DUMP"

# boot.sh's model comes from /lib/ndb/llm: stage one naming the scripted
# backend and bind it over, then boot as the apps do.
CMD="mkdir -p /tmp/xenbootndb; echo 'mode=local' > /tmp/xenbootndb/llm; echo 'backend=openai' >> /tmp/xenbootndb/llm; echo 'url=http://127.0.0.1:$PORT/v1' >> /tmp/xenbootndb/llm; echo 'model=mock' >> /tmp/xenbootndb/llm; bind -bc /tmp/xenbootndb /lib/ndb; cd /usr/xenboot; run /lib/xen/boot.sh -l /tmp/$(basename "$DUMP")"

SDL_VIDEODRIVER=dummy OPENAI_API_KEY=test "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g1024x768 \
	-r"$ROOT" /dis/sh.dis -l -c "$CMD" </dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 120 ]; do
	grep -q '^DRIVER_DONE$' "$OUT" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

if ! { [ -f "$OUT" ] && grep -q '^DRIVER_DONE$' "$OUT"; }; then
	echo "FAIL: driver did not finish"
	[ -f "$OUT" ] && cat "$OUT"
	echo "--- emu:"
	tail -20 "$WORK/emu.log"
	exit 1
fi
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$OUT"; }
FAILED=0
expect() {
	if section "$2" | grep -q -- "$3"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (section $2 lacks /$3/)"
		FAILED=$((FAILED + 1))
	fi
}
expect "the plumber is running" chan 'plumb.edit'
expect "the model is mounted" llm '^/mnt/llm/new$'
expect "a plumbed file opens in a window" window '^/chan/[0-9]'
expect "the window holds the file" body '^alpha$'

[ "$FAILED" -eq 0 ] || { cat "$OUT"; tail -20 "$WORK/emu.log"; echo "xen_boot_test: $FAILED failed"; exit 1; }
echo "xen_boot_test: PASS"
