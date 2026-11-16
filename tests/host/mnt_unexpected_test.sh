#!/bin/sh
# The mount driver's report of a reply nobody is waiting for (mountmux
# in emu/port/devmnt.c and os/port/devmnt.c), in an emulator of its
# own: the report is a line on the console, and the first eight are
# made (tests/mnt_unexpected.b is the 9P server and its client).
#
# For an Rerror the line has the error's text, which lies in the
# reply's Block, and the Block was freed first: the console (and
# /dev/kprint) got whatever message had the Block next, to its first
# NUL. A server the machine has mounted sends such replies as it likes.
#
# - by the source, both kernels: mountmux's last use of the reply's
#   text comes before it frees the reply's Block
# - three runs: each of the eight lines has the text its Rerror had
#   (four that name the stat they came before, four of another letter),
#   the ninth says the rest are not reported, and the stats are answered
# - where tools/sanemu's emulator is built ($SANEMU, or
#   $ROOT/tmp/sanemu/o.emu), the same under it with no report: there a
#   Block is the sanitizer's own allocation, and the code before is a
#   heap-use-after-free in mountmux's print at the first such reply

. "$(dirname "$0")/common.sh"
cd "$ROOT"

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

for k in emu os; do
	f="$ROOT/$k/port/devmnt.c"
	if awk '
		/^mountmux\(/ { infn = 1; next }
		infn && /^}/ { exit }
		infn && /reply\.ename/ { use = NR }
		infn && /freeblist\(r->b\)/ { fr = NR }
		END { exit !(use && fr && use < fr) }' "$f"; then
		pass "$k/port/devmnt.c: mountmux prints an unexpected Rerror's text before it frees the reply"
	else
		fail "$k/port/devmnt.c: mountmux uses an unexpected Rerror's text after freeing the Block it lies in"
	fi
done

[ -x "$EMU" ] || { echo "mnt_unexpected_test: SKIP the runs (no emu)"; exit $rc; }
[ -f dis/tests/mnt_unexpected.dis ] || { echo "mnt_unexpected_test: SKIP the runs (dis/tests/mnt_unexpected.dis not built)"; exit $rc; }

# the lines of one run against what the program says it sent
checkrun() {
	out=$1
	echo "$out" | grep -a -q '^DONE$' || { echo "the program did not finish"; return 1; }
	[ "$(echo "$out" | grep -a -c '^STAT [0-3] 0 / WANT ')" = 4 ] || { echo "the four stats were not all answered"; return 1; }
	want=$(echo "$out" | grep -a '^STAT ' | sed 's/.* WANT //')
	got=$(echo "$out" | grep -a '^unexpected reply tag [0-9]*; type 107 (error ' | sed -e 's/^[^(]*(error //' -e 's/)$//')
	[ "$(echo "$got" | wc -l | tr -d ' ')" = 8 ] || { echo "$(echo "$got" | grep -c .) reports of 8"; return 1; }
	named=$(echo "$got" | grep -a -v '^ZZZ')
	[ "$named" = "$want" ] || { echo "a report does not have its Rerror's text: $(echo "$named" | cut -c1-40 | tr '\n' '|')"; return 1; }
	z=$(echo "$got" | grep -a '^ZZZ' | sort -u)
	[ "$(echo "$z" | wc -l | tr -d ' ')" = 1 ] && [ "$(echo "$z" | tr -d Z | wc -c | tr -d ' ')" = 1 ] && [ "$(printf %s "$z" | wc -c | tr -d ' ')" = 150 ] || { echo "a filler's report is not 150 Zs"; return 1; }
	echo "$out" | grep -a -q '^unexpected reply tags: one in a thousand reported from here$' || { echo "the eighth report does not say the rest are not made"; return 1; }
	return 0
}

ok=1
for i in 1 2 3; do
	out=$(with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/tests/mnt_unexpected.dis 2>&1 < /dev/null)
	why=$(checkrun "$out") || { fail "run $i: $why"; ok=0; }
done
[ $ok = 1 ] && pass "three runs: eight reports each, every one with the text its Rerror had"

SANEMU=${SANEMU:-$ROOT/tmp/sanemu/o.emu}
if [ -x "$SANEMU" ] && [ -x "$ROOT/tools/sanemu" ]; then
	log=$(mktemp -d)
	out=$(export $("$ROOT/tools/sanemu" env | sed "s|log_path=[^:]*|log_path=$log/san|g"); with_timeout 300 "$SANEMU" -c1 -r"$ROOT" /dis/tests/mnt_unexpected.dis 2>&1 < /dev/null)
	if cat "$log"/san* 2>/dev/null | grep -q 'ERROR: AddressSanitizer'; then
		fail "under the sanitizer: $(cat "$log"/san* | grep -m1 'ERROR: AddressSanitizer' | cut -c1-120); $(cat "$log"/san* | grep -m1 ' in mountmux ' | cut -c1-100)"
	elif why=$(checkrun "$(echo "$out" | grep -a -v 'runtime error\|^    #\|^$')"); then
		pass "under the sanitizer: eight reports, none of a freed Block read"
	else
		fail "under the sanitizer: $why"
	fi
	rm -rf "$log"
else
	echo "mnt_unexpected_test: no sanitizer emulator (tools/sanemu build): that run skipped"
fi
exit $rc
