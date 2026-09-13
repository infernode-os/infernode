#!/bin/sh
# Model-facing tools receive a fresh environment group.  Restricting /env is
# insufficient by itself because Inferno deliberately permits #e under NODEVS.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/veltro/tools9p.dis" ] || { echo "SKIP: tools9p.dis not built"; exit 77; }

DRIVE="$ROOT/tmp/tools9p_env_isolation_drive.sh"
LOG="$(mktemp)"
trap 'rm -f "$DRIVE" "$LOG"' EXIT HUP INT TERM
mkdir -p "$ROOT/tmp"

cat >"$DRIVE" <<'EOF'
path=(/dis/veltro /dis/cmd /dis .)
echo campaign-secret > /env/INFR480_SECRET
echo /tmp/veltro/session-safe > /env/VELTRO_SESSION
tools9p read list &
sleep 2
echo '@@DEVICE'
echo '#e' > /tool/list/ctl
cat /tool/list/ctl
echo '#e/INFR480_SECRET' > /tool/read/ctl
cat /tool/read/ctl
echo
echo '@@CANONICAL'
echo '/env' > /tool/list/ctl
cat /tool/list/ctl
echo '/env/VELTRO_SESSION' > /tool/read/ctl
cat /tool/read/ctl
echo
echo '@@DONE'
EOF

timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"run /tmp/tools9p_env_isolation_drive.sh" >"$LOG" 2>&1
rc=$?
case "$rc" in
0|124|137) ;;
*) echo "FAIL: driver exited with status $rc"; sed -n '1,120p' "$LOG"; exit 1 ;;
esac

out="$(grep -vE '^JIT|sdl3_pre|mounted on' "$LOG")"
device="$(printf '%s\n' "$out" | sed -n '/^@@DEVICE$/,/^@@CANONICAL$/p')"
canonical="$(printf '%s\n' "$out" | sed -n '/^@@CANONICAL$/,/^@@DONE$/p')"

if printf '%s\n' "$device" |
	grep -Eq '^[fd][[:space:]].*[[:space:]]INFR480_SECRET$|campaign-secret'; then
	echo "FAIL: a fixed-function tool recovered the launcher environment through #e"
	printf '%s\n' "$device"
	exit 1
fi
if ! printf '%s\n' "$canonical" | grep -q 'VELTRO_SESSION'; then
	echo "FAIL: canonical /env lost the permitted session entry"
	printf '%s\n' "$out"
	exit 1
fi
if ! printf '%s\n' "$canonical" | grep -q '/tmp/veltro/session-safe'; then
	echo "FAIL: canonical /env lost the permitted session value"
	printf '%s\n' "$out"
	exit 1
fi

echo "PASS: tool workers expose only their explicitly preserved environment"
