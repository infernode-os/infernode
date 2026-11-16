#!/bin/sh
#
# mount_cmd_hangup_test.sh - a server mounted with mount {cmd} ends when
# it is unmounted.  mount(1) ran the command with a copy of every fd it
# had (FORKFD), the mount's own end of the pipe among them, so the
# unmount never hung the server up: camsrv, an export, any server mounted
# with {} ran on for ever.  A Pi 5 soak's hourly camera probe (mount
# {camsrv} ...; unmount) left five processes behind each hour.
#
#  - camsrv -t and export, each mounted with {}, serve (fmt, a listing)
#  - once each is unmounted, no Camsrv, Nametree or Export process is left
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in camsrv export mount; do
	[ -f "$ROOT/dis/$f.dis" ] || { echo "SKIP: dis/$f.dis not built"; exit 77; }
done

P="$ROOT/.mount_cmd_hangup_test"
trap 'rm -rf "$P".*' EXIT
mkdir -p "$P.d"
: > "$P.d/hello"

cat > "$P.sh" <<'ISH'
load std
mkdir -p /tmp/mch.cam /tmp/mch.ex
mount {camsrv -t} /tmp/mch.cam
cat /tmp/mch.cam/0/fmt > /.mount_cmd_hangup_test.fmt
unmount /tmp/mch.cam
mount {export /.mount_cmd_hangup_test.d} /tmp/mch.ex
ls /tmp/mch.ex > /.mount_cmd_hangup_test.ls
unmount /tmp/mch.ex
sleep 2
ps > /.mount_cmd_hangup_test.ps
echo done > /.mount_cmd_hangup_test.done
echo halt > /dev/sysctl
ISH
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.mount_cmd_hangup_test.sh </dev/null >"$P.log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

[ -f "$P.done" ] || { echo "FAIL: the session did not finish: $(tail -3 "$P.log")"; exit 1; }
[ "$(cat "$P.fmt" 2>/dev/null)" = "288 162 i420 30" ] && echo "PASS: camsrv mounted with {} serves" ||
	fail "camsrv's fmt read '$(cat "$P.fmt" 2>/dev/null)': $(tail -3 "$P.log")"
grep -q hello "$P.ls" 2>/dev/null && echo "PASS: export mounted with {} serves" ||
	fail "export's listing was '$(cat "$P.ls" 2>/dev/null)'"
left=$(grep -E ' (Camsrv|Nametree|Export)' "$P.ps" || true)
[ -z "$left" ] && echo "PASS: no server left once unmounted" ||
	fail "servers left after unmount (the command kept the mount's end of its pipe):
$left"

if [ $failed = 0 ]; then echo "mount_cmd_hangup_test: ALL PASS"; exit 0; fi
exit 1
