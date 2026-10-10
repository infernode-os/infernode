#!/bin/sh
#
# emu_root_test.sh — the root (-r, $INFERNO, $ROOT) as long as a host
# path can be, and a root that cannot be used said to be so.
#
# rootdir was 140 bytes and -r was copied into it cut short, so a longer
# root (an app bundle in a deep folder) named a directory that did not
# exist, the bind of #U failed without a word, and emu stopped at
# "loading /dis/emuinit.dis: '/dis' file does not exist". Now:
#
#	a root of 300 bytes or so is used;
#	one longer than rootdir is refused, naming its length;
#	a root that is missing, or not a directory, stops emu saying so.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "emu_root_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/emuinit.dis" ] || { echo "emu_root_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emu_root.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# a root of about 300 bytes, its /dis the tree's
long=$tmp/$(printf '%0100d' 0)/$(printf '%0100d' 1)/$(printf '%0060d' 2)/root
mkdir -p "$long"
ln -s "$ROOT/dis" "$long/dis"
out=$(with_timeout 20 "$EMU" -c0 -r"$long" /dis/sh.dis -c 'echo root ok; echo halt > /dev/sysctl' 2>&1)
if printf '%s\n' "$out" | grep -q '^root ok'; then
    echo "PASS: a root of ${#long} bytes is used"
else
    echo "FAIL: a root of ${#long} bytes:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1
fi

# longer than rootdir: refused, not cut short
huge=/$(printf '%01100d' 0)
out=$(with_timeout 20 "$EMU" -c0 -r"$huge" /dis/sh.dis -c 'echo bad' 2>&1); st=$?
if [ $st != 0 ] && printf '%s\n' "$out" | grep -q 'root path is 1101 bytes'; then
    echo "PASS: -r longer than rootdir is refused"
else
    echo "FAIL: -r of 1101 bytes gave status $st: $(printf '%s' "$out" | head -c 200)"; fail=1
fi
out=$(ROOT=$huge with_timeout 20 "$EMU" -c0 /dis/sh.dis -c 'echo bad' 2>&1); st=$?
if [ $st != 0 ] && printf '%s\n' "$out" | grep -q 'root path is 1101 bytes'; then
    echo "PASS: \$ROOT longer than rootdir is refused"
else
    echo "FAIL: \$ROOT of 1101 bytes gave status $st: $(printf '%s' "$out" | head -c 200)"; fail=1
fi

# a root that cannot be used: said so, not "/dis does not exist"
out=$(with_timeout 20 "$EMU" -c0 -r"$tmp/missing" /dis/sh.dis -c 'echo bad' 2>&1)
if printf '%s\n' "$out" | grep -q "cannot use root $tmp/missing"; then
    echo "PASS: a missing root is named"
else
    echo "FAIL: a missing root gave: $(printf '%s' "$out" | head -c 200)"; fail=1
fi
: > "$tmp/file"
out=$(with_timeout 20 "$EMU" -c0 -r"$tmp/file" /dis/sh.dis -c 'echo bad' 2>&1)
if printf '%s\n' "$out" | grep -q "cannot use root $tmp/file: not a directory"; then
    echo "PASS: a root that is a file is named"
else
    echo "FAIL: a root that is a file gave: $(printf '%s' "$out" | head -c 200)"; fail=1
fi

exit $fail
