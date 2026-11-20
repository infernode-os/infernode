#!/bin/sh
# ndb/cs with its queries cancelled under it (tests/cs_cancel.b), in an
# emulator of its own, since it starts a connection server on /net.
#
# cs killed a query's Prog whenever its client went away (a killed dial,
# a closed descriptor) or wrote another query, wherever the Prog was.
# Killed in the middle of a database search it died holding attrdb's
# lock, and from then on no name was translated for any program on the
# machine: every dial through cs hung. A client whose write the killed
# Prog was to answer waited for ever too.
#
# With a 1500-entry database of the test's own: forty clients killed in
# their queries and forty queries cancelled by a second write on their
# descriptor, each followed by a translation that must answer; a query
# waiting for a dns file that never answers given up when its client is
# killed, and its writer told when it is cancelled; a network name with
# a slash in it refused; /net/cs for every program and its directory
# its owner's alone, on a first start and when started again.
#
# Nothing here asks the host or the network for a name: addresses are
# numbers, names are in the test's database, and the dns file is the
# test's own.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "cs_cancel_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/cs_cancel.dis ] || { echo "cs_cancel_test: SKIP (dis/tests/cs_cancel.dis not built)"; exit 77; }

rc=0
for mode in -c1 -c0; do
	out=$(with_timeout 150 "$EMU" $mode -r"$ROOT" /dis/tests/cs_cancel.dis 2>&1 < /dev/null)
	echo "$out" | grep '^PASS: \|^FAIL: ' | sed "s/^\(PASS\|FAIL\): /\1: $mode: /"
	if ! echo "$out" | grep -q '^DONE$'; then
		echo "FAIL: $mode: the program did not finish: $(echo "$out" | grep -v '^PASS: \|^fs:' | tail -3 | tr '\n' ' ' | cut -c1-300)"
		rc=1
	fi
	echo "$out" | grep -q '^FAILED 0$' || rc=1
done
rm -rf "$ROOT/tmp/cs_cancel"
exit $rc
