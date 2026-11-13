#!/bin/sh
#
# tests/host/usbclass_selftest_test.sh
#
# The USB class drivers' self-tests (os/init: mouseusb, kbdusb,
# usbserial, diskusb, etherusb), each "-t": what a device's descriptors
# and reports say, at the edges, with no device and no kernel. The
# drivers are part of the native kernel's root and are otherwise run
# only by tests/host/baremetal_test.sh under QEMU; their self-tests are
# plain Limbo, so the hosted emulator runs them too.
#
#   mouseusb   a wheel as wide as an int, a range that is the whole of
#              one, a contact with id -1, hostile report sizes
#   kbdusb     the keyboard's endpoint in a composite device, a short
#              endpoint descriptor, the endpoint's three numbers
#   usbserial  endpoint 0, an endpoint under two interfaces, packet
#              sizes, offsets into the status text, breaks, the queue
#   diskusb    READ CAPACITY(16), ranges that wrap, names, endpoints
#   etherusb   RNDIS offsets and lengths, NTB parameters, which parts
#              are a LAN78xx, bulk packet sizes, a lease, SNTP
#
# Each is compiled to a scratch directory (never to dis/) and run under
# -c0 and -c1; "selftest OK" and no crash signature is a pass.
#
# Skips (exit 77) when there is no emulator or no native limbo.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -x "$LIMBO" ] || { echo "SKIP: no limbo at $LIMBO"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: dis/ not built"; exit 77; }

TIMEOUT=${TIMEOUT:-60}
REL=tmp/usbclass.$$
BUILD=$ROOT/$REL
mkdir -p "$BUILD" || exit 1
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

rc=0
for d in mouseusb kbdusb usbserial diskusb etherusb; do
	if ! "$LIMBO" -I"$ROOT/module" -o "$BUILD/$d.dis" "$ROOT/os/init/$d.b" > "$BUILD/$d.err" 2>&1; then
		echo "FAIL: $d does not compile: $(head -3 "$BUILD/$d.err" | tr '\n' ' ')"
		rc=1
		continue
	fi
	for c in 0 1; do
		out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/$REL/$d.dis -t; echo halt > /dev/sysctl" 2>&1 < /dev/null)
		if echo "$out" | grep -q "^$d: selftest OK" &&
		   ! echo "$out" | grep -q 'selftest FAILED\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
			echo "PASS: $d -t under -c$c"
		else
			echo "FAIL: $d -t under -c$c:"
			echo "$out" | grep -v sdl3 | head -20
			rc=1
		fi
	done
done
exit $rc
