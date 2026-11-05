#!/bin/sh
#
# gefs_crash_test.sh -- a power cut at any point leaves a gefs disk
# that loads, checks clean, has only whole or cut-short files, and goes
# on working.
#
# A workload runs under disk/gefs -W, which journals every block written
# and every device flush. gefs_powercut.py makes from that journal the
# disks a cut could leave: everything up to a flush, and of what was in
# flight after it, any block written or not, in any of its versions, or
# torn into 4 KB sectors of old and new, as a drive whose atomic write
# unit is a sector can leave it. Each disk is then checked, mounted, its
# files compared with what was written, written to, synced and checked
# again.
#
# GEFS_CUTS cuts (default 24), with seeds from GEFS_SEED (default 1).
# Needs python3; runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "gefs_crash_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/disk/gefs.dis" ] || { echo "gefs_crash_test: SKIP (no dis/disk/gefs.dis)"; exit 77; }
command -v python3 >/dev/null || { echo "gefs_crash_test: SKIP (no python3)"; exit 77; }

cuts=${GEFS_CUTS:-24}
seed0=${GEFS_SEED:-1}
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d "$ROOT/.gefscrash.XXXXXX")
trap 'rm -rf "$dir"' EXIT
n=/${dir##*/}
head -c 1024 /dev/urandom > "$dir/p0"
head -c 65536 /dev/urandom > "$dir/p1"
head -c 300000 /dev/urandom > "$dir/p2"
head -c 4194304 /dev/urandom > "$dir/p3"
truncate -s 512M "$dir/base.img" 2>/dev/null || dd if=/dev/zero of="$dir/base.img" bs=1048576 count=0 seek=512 2>/dev/null

with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
disk/gefs -r \`{cat /dev/user} $n/base.img
echo halt > /dev/sysctl" > "$dir/ream.out" 2>&1
cp "$dir/base.img" "$dir/work.img"

# files f<i>.<k> and g<i>.<k> hold p<k>, or the start of it
out=$(with_timeout 600 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
mkdir $n/m $n/a
disk/gefs -W $n/journal -M main:$n/m -M adm:$n/a $n/work.img
mkdir $n/m/d
for(i in 1 2 3 4 5 6) { for(k in 0 1 2) { cp $n/p^\$k $n/m/d/f\$i.\$k } }
for(i in 1 2 3 4) { cp $n/p3 $n/m/d/f\$i.3 }
echo sync > $n/a/ctl
rm $n/m/d/f1.2 $n/m/d/f2.1
mv $n/m/d/f3.2 $n/m/d/g3.2
echo snap main s1 > $n/a/ctl
for(i in 7 8 9) { for(k in 0 1 2) { cp $n/p^\$k $n/m/d/f\$i.\$k } }
rm $n/m/d/f4.*
mkdir $n/m/d/many
for(i in \`{seq 1 150}) { cp $n/p0 $n/m/d/many/f\$i.0 }
for(i in 13 14 15 16 17 18 19 20 21 22) { for(k in 0 1 2) { cp $n/p^\$k $n/m/d/f\$i.\$k } }
for(i in 13 14 15 16 17 18 19 20) { rm $n/m/d/f\$i.2 }
for(i in 5 6 7 8 9 10 11 12) { cp $n/p3 $n/m/d/f\$i.3 }
rm $n/m/d/f1.3 $n/m/d/f6.3
echo sync > $n/a/ctl
echo delsnap s1 > $n/a/ctl
for(i in \`{seq 1 100}) { rm $n/m/d/many/f\$i.0 }
for(i in 10 11 12) { for(k in 0 1 2) { cp $n/p^\$k $n/m/d/f\$i.\$k } }
rm $n/m/d/f5.*
echo halt > $n/a/ctl
echo WORK^DONE
echo halt > /dev/sysctl" 2>&1)
if ! printf '%s\n' "$out" | grep -q WORKDONE; then
    echo "FAIL: gefs_crash: the workload did not finish"
    printf '%s\n' "$out" | tail -20
    exit 1
fi

fail=0
i=0
while [ $i -lt $cuts ]; do
    seed=$((seed0 + i))
    i=$((i + 1))
    what=$(python3 "$here/gefs_powercut.py" "$dir/base.img" "$dir/journal" "$dir/cut.img" $seed)
    rm -rf "$dir/out"; mkdir "$dir/out"
    v=$(with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
disk/gefs -c $n/cut.img
echo CHECK1 \$status
disk/gefs -M main:$n/m -M adm:$n/a $n/cut.img
echo MOUNT \$status
if { ftest -d $n/m/d } { for(f in \`{ls $n/m/d $n/m/d/many | grep '\.[0-9]\$'}) { cp \$f $n/out/^\`{basename \$f} } }
mkdir $n/m/post
for(j in 1 2 3 4 5 6 7 8) { cp $n/p2 $n/m/post/x\$j }
for(j in 1 2 3 4 5 6 7 8) { cmp $n/p2 $n/m/post/x\$j || echo POST^BAD }
rm -r $n/m/post
echo sync > $n/a/ctl
echo SYNC \$status
echo check > $n/a/ctl
echo CHECK2 \$status
echo halt > $n/a/ctl
unmount $n/m; unmount $n/a
disk/gefs -c $n/cut.img
echo CHECK3 \$status
echo VERIFY^DONE
echo halt > /dev/sysctl" 2>&1)
    files=$(python3 -I - "$dir" <<'PY'
import os, re, sys
d = sys.argv[1]
pats = [open(os.path.join(d, 'p%d' % k), 'rb').read() for k in range(4)]
bad = []
names = os.listdir(os.path.join(d, 'out'))
for f in names:
    m = re.match(r'[fg](\d+)\.(\d)$', f)
    b = open(os.path.join(d, 'out', f), 'rb').read()
    if not m or b != pats[int(m.group(2))][:len(b)]:
        bad.append(f)
print('%d files' % len(names), 'BAD ' + ' '.join(bad) if bad else 'whole')
PY
)
    ok=1
    for w in 'CHECK1 ' 'MOUNT ' 'SYNC ' 'CHECK2 ' 'CHECK3 ' 'VERIFYDONE'; do
        printf '%s\n' "$v" | grep -qx "$w" || ok=0
    done
    [ "$(printf '%s\n' "$v" | grep -cx ok)" = 3 ] || ok=0
    printf '%s\n' "$v" | grep -q 'POSTBAD\|double alloc\|read only\|internal error\|corrupt' && ok=0
    case "$files" in *BAD*) ok=0 ;; esac
    if [ $ok = 1 ]; then
        echo "PASS: gefs_crash: seed $seed: $what; $files"
    else
        echo "FAIL: gefs_crash: seed $seed: $what; $files"
        printf '%s\n' "$v" | grep -v '^	' | tail -25
        fail=1
    fi
done
exit $fail
