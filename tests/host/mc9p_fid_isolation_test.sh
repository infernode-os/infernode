#!/bin/sh
# Responses from an mc9p endpoint belong to the fid that submitted the
# request. Equal endpoint names must not become a cross-client response slot.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -x "$LIMBO" ] || { echo "SKIP: native limbo not built"; exit 77; }
[ -f "$ROOT/dis/veltro/mc9p.dis" ] || { echo "SKIP: mc9p.dis not built"; exit 77; }

SRC="$ROOT/tmp/mc9p_fid_isolation.b"
DIS="$ROOT/tmp/mc9p_fid_isolation.dis"
trap 'rm -f "$SRC" "$DIS"' EXIT HUP INT TERM

cat >"$SRC" <<'EOF'
implement Mc9pFidIsolation;
include "sys.m";
	sys: Sys;
include "draw.m";
Mc9pFidIsolation: module { init: fn(nil: ref Draw->Context, nil: list of string); };

request(fd: ref Sys->FD, path: string): string
{
	b := array of byte path;
	if(sys->write(fd, b, len b) != len b)
		return "write failed";
	if(sys->seek(fd, big 0, Sys->SEEKSTART) < big 0)
		return "seek failed";
	r := array[64] of byte;
	n := sys->read(fd, r, len r);
	if(n < 0)
		return "read failed";
	return string r[0:n];
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	a := sys->open("/tmp/mcp-fid/fs/read", Sys->ORDWR);
	b := sys->open("/tmp/mcp-fid/fs/read", Sys->ORDWR);
	if(a == nil || b == nil) {
		sys->print("MECH: FAIL open: %r\n");
		return;
	}
	ra := request(a, "/tmp/mc9p-a");
	rb := request(b, "/tmp/mc9p-b");
	# Re-read a only after b has completed: a shared endpoint response would
	# now contain b's value.
	sys->seek(a, big 0, Sys->SEEKSTART);
	abuf := array[64] of byte;
	an := sys->read(a, abuf, len abuf);
	if(an >= 0)
		ra = string abuf[0:an];
	fresh := sys->open("/tmp/mcp-fid/fs/read", Sys->OREAD);
	fbuf := array[8] of byte;
	freshn := sys->read(fresh, fbuf, len fbuf);
	if(ra == "alpha" && rb == "beta" && freshn == 0)
		sys->print("MECH: PASS\n");
	else
		sys->print("MECH: FAIL a=%q b=%q fresh=%d\n", ra, rb, freshn);
}
EOF

"$LIMBO" -I"$ROOT/module" -o "$DIS" "$SRC" || {
	echo "FAIL: could not compile mc9p fid probe"; exit 1; }

OUT="$(with_timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c \
    "path=(/dis/veltro /dis/cmd /dis .); echo -n alpha > /tmp/mc9p-a; echo -n beta > /tmp/mc9p-b; mc9p -m /tmp/mcp-fid fs & sleep 2; ${DIS#$ROOT}; echo halt > '#c/sysctl'" 2>&1)"
if echo "$OUT" | grep -q '^MECH: PASS$'; then
	echo "PASS: mc9p endpoint responses are isolated per fid"
else
	echo "FAIL: mc9p leaked or replaced a fid response"
	echo "$OUT" | grep -vE '^JIT|sdl3_pre' | tail -8
	exit 1
fi
