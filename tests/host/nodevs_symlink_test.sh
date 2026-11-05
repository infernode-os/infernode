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
printf 'inside\n' >"$BASE/plain"
ln -s ../nodevs-symlink-secret "$BASE/dir-rel"
ln -s "$SECRET" "$BASE/dir-abs"
ln -s ../nodevs-symlink-secret/value "$BASE/file-rel"
ln -s "$SECRET/value" "$BASE/file-abs"

cat >"$SRC" <<'EOF'
implement NodevsSymlinkMech;
include "sys.m";
	sys: Sys;
include "draw.m";
NodevsSymlinkMech: module { init: fn(nil: ref Draw->Context, nil: list of string); };

canopen(path: string): int
{
	fd := sys->open(path, Sys->OREAD);
	return fd != nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	paths := array[] of {
		"/tmp/nodevs-symlink-root/dir-rel/value",
		"/tmp/nodevs-symlink-root/dir-abs/value",
		"/tmp/nodevs-symlink-root/file-rel",
		"/tmp/nodevs-symlink-root/file-abs",
	};
	before := 1;
	for(i := 0; i < len paths; i++)
		before &= canopen(paths[i]);
	pctlok := sys->pctl(Sys->NODEVS, nil) >= 0;
	after := 0;
	for(i = 0; i < len paths; i++)
		after |= canopen(paths[i]);
	plain := canopen("/tmp/nodevs-symlink-root/plain");
	if(before && pctlok && !after && plain)
		sys->print("MECH: PASS\n");
	else
		sys->print("MECH: FAIL before=%d pctl=%d after=%d plain=%d err=%r\n",
			before, pctlok, after, plain);
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
