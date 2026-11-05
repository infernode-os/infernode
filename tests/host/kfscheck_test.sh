#!/bin/sh
#
# kfscheck_test.sh -- "disk/kfscmd check" returns.
#
# kfscmd writes "check" to /chan/kfs.NAME.cmd and reads the report until
# end of file. When the check ended, a read already waiting for more of
# it was never answered, so kfscmd -- and on a console, the shell it ran
# in -- waited for ever after printing the whole report. Found on a Pi 5,
# where it looked like a frozen machine.
#
# Reams a 64 MB kfs in a file, checks it twice, and fails if either
# check does not come back. Runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "kfscheck_test: SKIP (no emu)"; exit 77; }

dir=$(mktemp -d "$ROOT/.kfscheck.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}
dd if=/dev/zero of="$dir/k.img" bs=1048576 count=64 2>/dev/null

out=$(with_timeout 60 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "
mkdir /$name/mnt
mount -c {disk/kfs -r -n kfscheck /$name/k.img} /$name/mnt
echo hello > /$name/mnt/a
disk/kfscmd -n kfscheck check
echo FIRST^CHECK^RETURNED
disk/kfscmd -n kfscheck check
echo SECOND^CHECK^RETURNED
echo halt > /dev/sysctl" 2>&1)

fail=0
for w in FIRSTCHECKRETURNED SECONDCHECKRETURNED; do
    if printf '%s\n' "$out" | grep -q "$w"; then
        echo "PASS: kfscheck: $w"
    else
        echo "FAIL: kfscheck: $w -- kfscmd check did not return"
        fail=1
    fi
done
if printf '%s\n' "$out" | grep -q "free blocks"; then
    echo "PASS: kfscheck: the check reported"
else
    echo "FAIL: kfscheck: no check report"; fail=1
fi
[ $fail = 0 ] || printf '%s\n' "$out" | tail -20
exit $fail
