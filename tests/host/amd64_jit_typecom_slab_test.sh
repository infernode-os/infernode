#!/bin/sh
# Regression test for INFR-421: exhausting one typecom slab must not
# leave a compiled frame type with a nil initializer.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

[ "$OBJTYPE" = amd64 ] || {
	echo "SKIP: amd64 JIT test"
	exit 77
}
[ -x "$EMU" ] || {
	echo "SKIP: emu not found at $EMU"
	exit 77
}

REPRO="$ROOT/tmp/amd64_jit_typecom_slab_repro.sh"
LOG="$(mktemp)"
trap 'rm -f "$REPRO" "$ROOT/tmp/amd64-jit-typecom-copy" "$LOG"' EXIT HUP INT TERM

cat >"$REPRO" <<'EOF'
#!/dis/sh.dis

load std
path=(/dis .)

for (i in `{seq 1 2400}) {
	cp /README.md /tmp/amd64-jit-typecom-copy
}
echo '@@TYPECOM-SLAB PASS'
EOF

rc=0
timeout 30 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/amd64_jit_typecom_slab_repro.sh \
	>"$LOG" 2>&1 || rc=$?

case "$rc" in
	0|124|137) ;;
	*)
		echo "FAIL: amd64 JIT exited with status $rc"
		cat "$LOG"
		exit 1
		;;
esac

if ! grep -q '^@@TYPECOM-SLAB PASS$' "$LOG"; then
	echo "FAIL: amd64 JIT did not survive typecom slab rollover"
	cat "$LOG"
	exit 1
fi

echo "PASS: amd64 JIT survives typecom slab rollover"
