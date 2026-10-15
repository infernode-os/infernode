#!/bin/sh
#
# pool_nomem_test.sh — an allocation the pool refuses says why (INFR-472).
#
# A long quota pause left Inferno raising "out of memory: main" in Sh and
# Factotum with the main pool at 2MB of 1GB, and nothing said what had been
# asked for or by whom.  Every refusal now prints the pool, the size, the
# reason, the caller (image+offset, for addr2line) and the pool's state.
#
# Under an 8MB main pool, Keyring->aesgcmencrypt is asked for 32MB 25 times
# (pool_nomem_helper): each must raise "out of memory: main", the first ten
# must be reported, with the fields filled in, and no more until the 1000th.
#
# Runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "pool_nomem_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/pool_nomem_helper.dis ] || { echo "pool_nomem_test: SKIP (dis/tests/pool_nomem_helper.dis not built)"; exit 77; }

SIZE=33554432	# 32MB; the request is this plus the allocator's header
out=$(with_timeout 60 "$EMU" -c1 -pmain=8m -r"$ROOT" /dis/tests/pool_nomem_helper.dis 25 $SIZE 2>&1 < /dev/null)
rc=0
fail() { echo "FAIL: $*"; rc=1; }

echo "$out" | grep -q '^HELPER DONE$' || fail "the helper did not finish"
raised=$(echo "$out" | grep -c '^ATTEMPT [0-9]*: raised out of memory: main$')
[ "$raised" = 25 ] || fail "$raised of 25 attempts raised 'out of memory: main'"

reports=$(echo "$out" | grep '^pool main: cannot allocate ')
n=$(echo "$reports" | grep -c .)
[ "$n" = 10 ] || fail "$n refusals reported, want the first 10 only"

first=$(echo "$reports" | head -1)
pat="^pool main: cannot allocate 3355[0-9]* bytes \(beyond the pool's maxsize\) for [^ ]+\+0x[0-9a-f]+: cursize [0-9]+ arenasize [0-9]+ maxsize 8388608 largest free [0-9]+; refusal 1$"
echo "$first" | grep -Eq "$pat" || fail "first report not as expected: $first"
echo "$reports" | tail -1 | grep -q 'refusal 10, now reporting every 1000th$' || fail "the tenth report does not say what follows"

# The caller is the malloc in Keyring_aesgcmencrypt, where addr2line can say.
if command -v addr2line >/dev/null 2>&1; then
	off=$(echo "$first" | sed -n 's/.* for [^ ]*+\(0x[0-9a-f]*\):.*/\1/p')
	fn=$(addr2line -f -e "$EMU" "$off" 2>/dev/null | head -1)
	[ "$fn" = Keyring_aesgcmencrypt ] || fail "caller $off resolves to '$fn', want Keyring_aesgcmencrypt"
fi

if [ $rc = 0 ]; then
	echo "PASS: refusals report size, reason, caller and pool state; 10 reported of 25"
else
	echo "$out" | head -20
fi
exit $rc
