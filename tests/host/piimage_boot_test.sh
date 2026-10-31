#!/bin/sh
#
# piimage_boot_test.sh -- boot a Raspberry Pi card image, the one a
# release ships, under QEMU, and require what a board showed when the
# same image was flashed and booted on it:
#
#	the kernel's banner for the board, and its console readable;
#	the card found and mounted, and dis/, lib/, fonts/ and icons/
#	grown from it, and usr/ from it, writable;
#	the shell started, on the serial console, and answering there
#	(it reads /dev/sysctl back);
#	the login screen taking the framebuffer from the text console, and
#	the first-boot login -- a new password typed twice on the USB
#	keyboard -- making its secstore account on the card;
#	no panic or fault on the way.
#
# This is the card as a whole, booted: a file missing from it, a usr/
# that will not mount, a userspace that does not start the login screen.
# QEMU loads the kernel itself and runs neither the boot ROM nor the GPU
# firmware, so what those need of the card is tools/piromcheck.py's,
# which tests/host/piimage_test.sh and release.yml run.
#
# Usage:
#     tests/host/piimage_boot_test.sh BOARD IMAGE KERNEL
#
#     BOARD   rpi3bplus (QEMU's raspi3b) or rpi4b (raspi4b, QEMU 9 or later)
#     IMAGE   the card image, uncompressed; it is not written to (the
#             boot runs on a copy)
#     KERNEL  the kernel that is on the card as infernode8.img; QEMU
#             loads it with -kernel, as the firmware would
#
# QEMU=path picks the emulator (default qemu-system-aarch64), and
# BOOT_TIMEOUT the seconds the boot may take (default 300).
#
# Exit status: 0 the image booted as a board boots it; 1 it did not; 77
# skipped (no QEMU, or one without the board's machine).

BOARD=$1 IMAGE=$2 KERNEL=$3
[ $# -eq 3 ] || { echo "usage: piimage_boot_test.sh rpi3bplus|rpi4b IMAGE KERNEL" >&2; exit 2; }
case $BOARD in
rpi3bplus) MACH=raspi3b; BANNER="InferNode bare-metal (BCM2837" ;;
rpi4b)     MACH=raspi4b; BANNER="InferNode bare-metal (BCM2711" ;;
*) echo "piimage_boot_test: unknown board $BOARD" >&2; exit 2 ;;
esac
QEMU=${QEMU:-qemu-system-aarch64}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}

command -v "$QEMU" >/dev/null 2>&1 || { echo "piimage_boot_test: SKIP (no $QEMU)"; exit 77; }
"$QEMU" -machine help 2>/dev/null | grep -q "^$MACH " \
	|| { echo "piimage_boot_test: SKIP ($QEMU has no $MACH machine)"; exit 77; }
[ -f "$IMAGE" ] && [ -f "$KERNEL" ] || { echo "piimage_boot_test: no $IMAGE or $KERNEL" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/piimageboot.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
cp "$IMAGE" "$tmp/card.img" || exit 1

# The boot, driven from Python for the timeouts: the console is the
# second -serial on both machines (the first is the PL011, the radio's).
# Wait for the milestones, then type to the shell and read its answer.
python3 - "$QEMU" "$MACH" "$tmp/card.img" "$KERNEL" "$BOOT_TIMEOUT" "$tmp/qmp" > "$tmp/console.txt" 2> "$tmp/driver.txt" <<'EOF'
import json, socket, subprocess, sys, threading, time
qemu, mach, card, kernel, limit, qmp = sys.argv[1:7]
limit = int(limit)
p = subprocess.Popen([qemu, "-M", mach, "-kernel", kernel,
                      "-drive", "file=%s,if=sd,format=raw" % card,
                      "-netdev", "user,id=n0", "-device", "usb-net,netdev=n0",
                      "-device", "usb-kbd", "-qmp", "unix:%s,server=on,wait=off" % qmp,
                      "-display", "none", "-serial", "null", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read1(4096) if hasattr(p.stdout, "read1") else p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
def wait(marks, until):
    while time.time() < until:
        if all(m in buf for m in marks) or p.poll() is not None:
            break
        time.sleep(0.5)
end = time.time() + limit
# the shell, and the login screen taking the framebuffer, in either order
wait([b"init: starting the shell", b"console released to the draw device"], end)
if b"init: starting the shell" in buf:
    time.sleep(2)
    try:
        # /dev/sysctl ends without a newline: the echo gives the marker its own line
        p.stdin.write(b"cat /dev/sysctl; echo; echo SYSCTL-READ\r")
        p.stdin.flush()
    except OSError:
        pass
    # the echoed command holds "echo SYSCTL-READ"; only its output starts a line with it
    wait([b"\nSYSCTL-READ"], min(end, time.time() + 30))
    time.sleep(1)
# The first boot's login, as a person makes it: a new password typed
# twice on the USB keyboard, at the login screen. A card whose home
# was missing failed exactly here, on a 4B ("cannot create
# /usr/inferno/secstore/inferno"), and no test had ever typed one:
# every other boot under QEMU sets skiplogon.
if b"console released to the draw device" in buf:
    def qkey(f, ch):
        q = {"\n": "ret"}.get(ch, ch)
        for down in (True, False):
            f.write(json.dumps({"execute": "input-send-event", "arguments": {"events":
                [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": q}}}]}}) + "\n")
            f.flush(); f.readline()
            time.sleep(0.05)
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(qmp)
        f = s.makefile("rw"); f.readline()
        f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
        time.sleep(3)
        for word in ("piboottest42\n", "piboottest42\n"):
            for ch in word:
                qkey(f, ch)
            time.sleep(2)
    except OSError as e:
        sys.stderr.write("qmp: %s\n" % e)
    # the account is made, then unlocked, then the desktop starts; the
    # key derivation is slow under emulation
    deadline = min(end, time.time() + 90)
    while time.time() < deadline:
        p.stdin.write(b"ls /usr/inferno/secstore/inferno/PAK; echo; echo PAK-CHECKED\r")
        p.stdin.flush()
        time.sleep(4)
        if b"/usr/inferno/secstore/inferno/PAK\r\n" in buf or b"/usr/inferno/secstore/inferno/PAK\n" in buf:
            break
        time.sleep(4)
    time.sleep(1)
p.kill()
p.wait()
sys.stdout.buffer.write(bytes(buf))
EOF

C=$tmp/console.txt
fail=0
pass() { echo "PASS: $BOARD: $1"; }
failed() { echo "FAIL: $BOARD: $1"; fail=1; }
need() {	# need <what> <fixed string>
	if grep -qF -- "$2" "$C"; then pass "$1"; else failed "$1 (no \"$2\")"; fi
}

need "the kernel's banner for the board" "$BANNER"
need "the console's rate, from the clock it asked for" "115200 baud"
need "the card's partition table read" "sd: MBR ok"
need "the card mounted" "init: /dev/sd0 mounted on /n/dos"
for d in dis lib fonts icons; do
	need "/$d from the card" "init: /$d grown from /n/dos/$d"
done
need "/usr from the card, writable" "init: /usr from /n/dos/usr (writable)"
need "the shell started" "init: starting the shell"
need "the login screen took the framebuffer" "fb:   console released to the draw device"
# The shell answers on the serial console: /dev/sysctl is the build's
# name, and the marker is a line of the shell's output, not the echo of
# what was typed.
if tr -d '\r' < "$C" | grep -qx 'SYSCTL-READ' && grep -q '(based on Inferno' "$C"; then
	pass "the shell answers on the serial console ($(grep -m1 '(based on Inferno' "$C" | grep -o 'InferNode [^(]*'))"
else
	failed "the shell did not answer on the serial console"
fi
# The first-boot login made its secstore account on the card: ls names
# the PAK file on a line of its own (the echoed command, and a "does not
# exist", both have more on that line).
if tr -d '\r' < "$C" | grep -qx '/usr/inferno/secstore/inferno/PAK'; then
	pass "the first-boot login made its secstore account on the card"
else
	failed "the first-boot login made no secstore account ($(tr -d '\r' < "$C" | grep -v 'PAK-CHECKED' | grep -m1 -E 'cannot create|does not exist|logon:' || echo 'no PAK'))"
fi
if grep -q 'wm/logon failed' "$C"; then
	failed "logon failed: $(grep -m1 'wm/logon failed' "$C")"
else
	pass "logon did not fail"
fi
# What sercap.py, the bench's capture, marks as a fault -- less the
# self-tests that name one and pass.
if grep -E '\b(panic|PANIC|unhandled)\b|exception:' "$C" | grep -v -e 'exception path' -e 'would fault with MMU off' | head -3 | grep -q .; then
	failed "a panic or fault on the console: $(grep -E '\b(panic|PANIC|unhandled)\b|exception:' "$C" | grep -v -e 'exception path' | head -1)"
else
	pass "no panic or fault on the console"
fi

if [ $fail != 0 ]; then
	echo "--- the console's last 40 lines:"
	tail -40 "$C" | tr -d '\r'
	exit 1
fi
exit 0
