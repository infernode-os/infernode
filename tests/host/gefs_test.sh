#!/bin/sh
#
# gefs_test.sh -- disk/gefs, 9front's copy-on-write file system, works:
# ream, files and directories, a big file, many small ones, persistence
# across a restart, a snapshot that keeps what is changed and removed
# after it, deleting it, and the check passing at each step.
#
# In a 256 MB file; runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "gefs_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/disk/gefs.dis" ] || { echo "gefs_test: SKIP (no dis/disk/gefs.dis)"; exit 77; }

dir=$(mktemp -d "$ROOT/.gefs.XXXXXX")
trap 'rm -rf "$dir"' EXIT
n=/${dir##*/}
truncate -s 256M "$dir/g.img" 2>/dev/null || dd if=/dev/zero of="$dir/g.img" bs=1048576 count=0 seek=256 2>/dev/null
head -c 3000000 /dev/urandom > "$dir/big"

out=$(with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
disk/gefs -r \`{cat /dev/user} $n/g.img
echo REAM \$status
disk/gefs -c $n/g.img
echo CHECK0 \$status
mkdir $n/m $n/a $n/d
disk/gefs -M main:$n/m -M adm:$n/a -M dump:$n/d $n/g.img
echo hello gefs > $n/m/hello
mkdir $n/m/dir
echo inner > $n/m/dir/inner
cp $n/big $n/m/big
cmp $n/big $n/m/big && echo BIG^SAME
mv $n/m/hello $n/m/hello2
cat $n/m/hello2
mkdir $n/m/many
for(i in \`{seq 1 500}) { echo file \$i > $n/m/many/f\$i }
ls $n/m/many | wc -l | sed 's/^ */MANY /'
for(i in \`{seq 1 250}) { rm $n/m/many/f\$i }
ls $n/m/many | wc -l | sed 's/^ */LEFT /'
echo halt > $n/a/ctl
echo HALT \$status
unmount $n/m; unmount $n/a; unmount $n/d
disk/gefs -c $n/g.img
echo CHECK1 \$status
disk/gefs -M main:$n/m -M adm:$n/a -M dump:$n/d $n/g.img
cat $n/m/hello2 $n/m/dir/inner $n/m/many/f500
cmp $n/big $n/m/big && echo PERSIST^BIG
echo before > $n/m/snapfile
echo snap main s1 > $n/a/ctl
echo SNAP \$status
echo after > $n/m/snapfile
rm $n/m/big
cat $n/d/s1/snapfile | sed 's/^/INSNAP /'
cat $n/m/snapfile | sed 's/^/INMAIN /'
cmp $n/big $n/d/s1/big && echo SNAP^KEEPS^BIG
echo delsnap s1 > $n/a/ctl
echo DELSNAP \$status
ftest -e $n/d/s1 || echo SNAP^GONE
echo check > $n/a/ctl
echo CHECK2 \$status
echo halt > $n/a/ctl
unmount $n/m; unmount $n/a; unmount $n/d
disk/gefs -c $n/g.img
echo CHECK3 \$status
echo halt > /dev/sysctl" 2>&1)

fail=0
check() {
    if printf '%s\n' "$out" | grep -qx "$1"; then
        echo "PASS: gefs: $2"
    else
        echo "FAIL: gefs: $2 (no '$1')"; fail=1
    fi
}
check 'REAM ' 'ream'
check 'CHECK0 ' 'check of a new file system'
check 'BIGSAME' 'a 3 MB file reads back'
check 'hello gefs' 'rename'
check 'MANY 500' '500 files in a directory'
check 'LEFT 250' 'removing half of them'
check 'HALT ' 'halt'
check 'CHECK1 ' 'check after use'
check 'inner' 'a file in a directory persists'
check 'file 500' 'a small file persists'
check 'PERSISTBIG' 'the big file persists'
check 'SNAP ' 'snapshot'
check 'INSNAP before' 'the snapshot keeps the old contents'
check 'INMAIN after' 'main has the new'
check 'SNAPKEEPSBIG' 'the snapshot keeps a file removed after it'
check 'DELSNAP ' 'delsnap'
check 'SNAPGONE' 'the snapshot is gone'
check 'CHECK2 ' 'check while serving'
check 'CHECK3 ' 'check after delsnap'
n_ok=$(printf '%s\n' "$out" | grep -cx 'ok')
if [ "$n_ok" -ge 4 ]; then echo "PASS: gefs: every check said ok"; else echo "FAIL: gefs: $n_ok checks said ok, want 4"; fail=1; fi
[ $fail = 0 ] || printf '%s\n' "$out" | grep -v '^	' | tail -40
exit $fail
