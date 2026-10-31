#!/bin/sh
#
# wstat_nulldir_test.sh — renaming or chmodding a host file from inside
# InferNode changes only what was asked.
#
# A wstat leaves a field alone by sending ~0 for it. On 64-bit hosts the
# decoder used to keep that as a 32-bit 0xFFFFFFFF in a 64-bit field,
# which devfs's ~0 checks never matched: mv made the file mode 777 and
# set its modification time to 2106-02-07, and chmod set that time too.
#
# Runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "wstat_nulldir_test: SKIP (no emu)"; exit 77; }

dir=$(mktemp -d "$ROOT/.wstat_nulldir.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}

# file mode in octal, and modification time in seconds
if stat -c %a "$dir" >/dev/null 2>&1; then
    perm() { stat -c %a "$1"; }
    mtime() { stat -c %Y "$1"; }
else
    perm() { stat -f %Lp "$1"; }
    mtime() { stat -f %m "$1"; }
fi

echo a > "$dir/a"
echo c > "$dir/c"
chmod 644 "$dir/a" "$dir/c"
touch -t 202001020304 "$dir/a" "$dir/c"
want_mtime=$(mtime "$dir/a")

with_timeout 30 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "
mv /$name/a /$name/b
chmod +x /$name/c
echo halt > /dev/sysctl" >/dev/null 2>&1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1: got $2, want $3"
        fail=1
    fi
}

if [ ! -f "$dir/b" ]; then
    echo "FAIL: mv inside InferNode did not rename the file"
    exit 1
fi
check "mv keeps the mode" "$(perm "$dir/b")" 644
check "mv keeps the modification time" "$(mtime "$dir/b")" "$want_mtime"
check "chmod +x sets the mode" "$(perm "$dir/c")" 755
check "chmod keeps the modification time" "$(mtime "$dir/c")" "$want_mtime"
exit $fail
