#!/bin/sh
#
# luciuisrv_data_test.sh — an artifact's data file keeps content longer
# than one 9P message whole.
#
# A file plumbed into Lucifer's presentation view is written to
# /mnt/ui/activity/N/presentation/ID/data in one write(2), which the mount
# driver sends as several Twrites, each at the offset the last ended at.
# luciuisrv took each as the whole of the data, so only the last message
# (README.md's last 8K) was kept, and the view showed only its last line.
# Here: content in several writes kept whole, in order; a rune cut by a
# message's end and a newline at the end of one kept; a new write at
# offset 0 replacing what was there.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/luciuisrv.dis" ] || { echo "SKIP: dis/luciuisrv.dis not built"; exit 77; }

mkdir -p "$ROOT/tmp"
DIR=$(mktemp -d "$ROOT/tmp/luciuisrv_data.XXXXXX")
trap 'rm -rf "$DIR"' EXIT
D=/tmp/$(basename "$DIR")

# Big enough for several messages; an odd byte before two-byte runes puts
# every 8K boundary inside one; lines of every length after that.
python3 - "$DIR/big.md" <<'EOF'
import sys
s = "x" + "®" * 5000 + "\n"
for i in range(300):
    s += "# h%d ®" % i + "®" * (i % 37) + "a" * (i % 11) + "\n"
s += "<sub>last line ®.</sub>\n"
open(sys.argv[1], "w", encoding="utf-8").write(s)
EOF

A=/mnt/ui/activity/0/presentation
timeout 60 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "path=(/dis/veltro /dis/cmd /dis .); luciuisrv; \
	echo 'activity create Main' > /mnt/ui/ctl; \
	echo 'create id=big type=markdown label=Big' > $A/ctl; \
	cp $D/big.md $A/big/data; cat $A/big/data > $D/big.out; \
	echo 'create id=two type=markdown label=Two' > $A/ctl; \
	{echo first; echo second} > $A/two/data; cat $A/two/data > $D/two.out; \
	echo short > $A/big/data; cat $A/big/data > $D/short.out; \
	echo halt > /dev/sysctl" </dev/null >"$DIR/log" 2>&1 || true

FAILED=0
same() {	# description, file, wanted
	if [ ! -f "$2" ]; then
		echo "FAIL: $1 (nothing read back)"; FAILED=$((FAILED + 1))
	elif [ "$(cat "$2"; echo .)" = "$3." ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 ($(wc -c <"$2") bytes, begins $(head -c 40 "$2" | tr '\n' ' '))"
		FAILED=$((FAILED + 1))
	fi
}

# a write's trailing newline is not the data's, as before
same "content in several messages kept whole, runes cut at their ends too" \
	"$DIR/big.out" "$(cat "$DIR/big.md")"
same "two writes, the first ending in a newline, kept in order" \
	"$DIR/two.out" "$(printf 'first\nsecond')"
same "a write at offset 0 replaces the data" "$DIR/short.out" "short"

if [ "$FAILED" -ne 0 ]; then
	cat "$DIR/log"
	echo "luciuisrv_data_test: $FAILED failed"
	exit 1
fi
echo "luciuisrv_data_test: PASS"
