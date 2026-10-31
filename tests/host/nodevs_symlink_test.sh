#!/bin/sh
# A confined (NODEVS) process must not follow a host symlink out of a granted
# tree.  cowfs and namespace grants are lexical; allowing #U to resolve the
# link first would bypass both.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -x "$LIMBO" ] || { echo "SKIP: native limbo not built"; exit 77; }

BASE="$ROOT/tmp/nodevs-symlink-root"
SECRET="$ROOT/tmp/nodevs-symlink-secret"
SRC="$ROOT/tmp/nodevs_symlink_mech.b"
DIS="$ROOT/tmp/nodevs_symlink_mech.dis"
trap 'rm -rf "$BASE" "$SECRET"; rm -f "$SRC" "$DIS"' EXIT HUP INT TERM

rm -rf "$BASE" "$SECRET"
mkdir -p "$BASE" "$SECRET"
printf 'outside\n' >"$SECRET/value"
ln -s ../nodevs-symlink-secret "$BASE/link"

cat >"$SRC" <<'EOF'
implement NodevsSymlinkMech;
include "sys.m";
	sys: Sys;
include "draw.m";
NodevsSymlinkMech: module { init: fn(nil: ref Draw->Context, nil: list of string); };

canopen(): int
{
	fd := sys->open("/tmp/nodevs-symlink-root/link/value", Sys->OREAD);
	return fd != nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	before := canopen();
	pctlok := sys->pctl(Sys->NODEVS, nil) >= 0;
	after := canopen();
	if(before && pctlok && !after)
		sys->print("MECH: PASS\n");
	else
		sys->print("MECH: FAIL before=%d pctl=%d after=%d err=%r\n",
			before, pctlok, after);
}
EOF

"$LIMBO" -I"$ROOT/module" -o "$DIS" "$SRC" || {
	echo "FAIL: could not compile NODEVS symlink probe"; exit 1; }

OUT="$(with_timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c "${DIS#$ROOT}" 2>&1)"
if echo "$OUT" | grep -q '^MECH: PASS$'; then
	echo "PASS: NODEVS refuses host symlink traversal"
else
	echo "FAIL: NODEVS followed a host symlink"
	echo "$OUT" | grep -vE '^JIT|sdl3_pre' | tail -5
	exit 1
fi
