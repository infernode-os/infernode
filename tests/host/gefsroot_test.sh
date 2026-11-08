#!/bin/sh
#
# gefsroot_test.sh -- disk/gefsroot puts a userland on a gefs root and
# updates it: ream and install from a source tree; change the source
# (a file gone, a file new, a file changed) and install again. The
# disk must then hold the new tree exactly, keep the machine's own
# usr/ as it was left, have a snapshot per install with the old tree
# in the first, and check clean.
#
# In a 256 MB file; runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "gefsroot_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/disk/gefs.dis" ] || { echo "gefsroot_test: SKIP (no dis/disk/gefs.dis)"; exit 77; }

dir=$(mktemp -d "$ROOT/.gefsroot.XXXXXX")
trap 'rm -rf "$dir"' EXIT
n=/${dir##*/}
truncate -s 256M "$dir/g.img" 2>/dev/null || dd if=/dev/zero of="$dir/g.img" bs=1048576 count=0 seek=256 2>/dev/null
mkdir -p "$dir/n/gefs" "$dir/n/gefs.adm" "$dir/n/dump" \
    "$dir/src/dis/lib" "$dir/src/lib" "$dir/src/fonts" "$dir/src/usr/inferno"
cp "$ROOT/dis/echo.dis" "$ROOT/dis/cat.dis" "$dir/src/dis/"
cp "$ROOT/dis/lib/arg.dis" "$dir/src/dis/lib/"
echo one > "$dir/src/lib/keep"
echo gone > "$dir/src/lib/gone"
echo font > "$dir/src/fonts/f"
echo card > "$dir/src/usr/inferno/home"

out=$(with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
bind -c $n/n /n
disk/gefsroot -r -s $n/src $n/g.img
echo INSTALL1 \$status
cmp $n/src/dis/echo.dis /n/gefs/dis/echo.dis && echo DIS^SAME
cat /n/gefs/lib/gone
cat /n/gefs/usr/inferno/home
echo mine > /n/gefs/usr/inferno/home
echo halt > /n/gefs.adm/ctl
unmount /n/gefs; unmount /n/gefs.adm; unmount /n/dump
sleep 1
echo halt > /dev/sysctl" 2>&1)

# the source changes between the installs
rm "$dir/src/lib/gone"
echo two > "$dir/src/lib/keep"
echo new > "$dir/src/lib/new"
echo card2 > "$dir/src/usr/inferno/home"

out2=$(with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
load std
bind -c $n/n /n
disk/gefsroot -s $n/src $n/g.img
echo INSTALL2 \$status
cat /n/gefs/lib/keep | sed 's/^/KEEP /'
cat /n/gefs/lib/new | sed 's/^/NEW /'
ftest -e /n/gefs/lib/gone || echo GONE^GONE
cat /n/gefs/usr/inferno/home | sed 's/^/HOME /'
ls /n/dump | grep install | wc -l | sed 's/^ */SNAPS /'
for(s in \`{ls /n/dump | grep install | sort}) { cat \$s/lib/keep | sed 's/^/OLD /'; ftest -e \$s/lib/gone && echo OLD^HAS^GONE }
echo check > /n/gefs.adm/ctl
echo CHECK \$status
echo halt > /n/gefs.adm/ctl
echo halt > /dev/sysctl" 2>&1)

fail=0
check() {
    if printf '%s\n%s\n' "$out" "$out2" | grep -qx "$1"; then
        echo "PASS: gefsroot: $2"
    else
        echo "FAIL: gefsroot: $2 (no '$1')"; fail=1
    fi
}
check 'INSTALL1 ' 'ream and first install'
check 'DISSAME' 'dis/ copied'
check 'gone' 'lib/ copied'
check 'card' 'usr/ copied the first time'
check 'INSTALL2 ' 'second install'
check 'KEEP two' 'a changed file is the new one'
check 'NEW new' 'a new file is there'
check 'GONEGONE' 'a file the source dropped is gone'
check 'HOME mine' "the machine's usr/ is kept, not the card's"
check 'SNAPS 2' 'a snapshot for each install'
check 'OLD one' 'the snapshot before the second install has the old file'
check 'OLDHASGONE' 'and the file since dropped'
check 'CHECK ' 'check clean'
if printf '%s\n' "$out2" | grep -qx ok; then echo "PASS: gefsroot: the check said ok"; else echo "FAIL: gefsroot: the check did not say ok"; fail=1; fi
[ $fail = 0 ] || printf '%s\n----\n%s\n' "$out" "$out2" | grep -v '^	' | tail -40
exit $fail
