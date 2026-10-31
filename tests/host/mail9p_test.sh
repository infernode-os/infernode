#!/bin/bash
#
# tests/host/mail9p_test.sh
#
# mail9p (INFR-8) at /mnt/mail with no IMAP server to reach:
#   - mount /mnt/mail succeeds; the root lists ctl and accounts
#   - connect with no credentials is refused, naming factotum
#   - connect with a factotum key, to a server that is not there, is
#     refused with the dial's error
#   - a refused connect leaves no account behind, so the same name can be
#     connected again (the second refusal is the dial's, not "already
#     exists")
#   - malformed ctl writes are refused with their reason: an unknown
#     argument, no server, no name, an unknown verb, disconnect and sync
#     of an account that does not exist
#   - mail9p still answers after all of them
#
# An account's files (ctl, boxes, the messages), and connecting over
# TLS and STARTTLS, are tests/host/mail9p_imap_test.sh's, against a fake
# server.  This test was first written for the scaffold, whose connect
# made an account without dialling, and went stale when connect was
# wired to IMAP.
#
# Run from project root: ./tests/host/mail9p_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0

while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0

pass()  { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail()  { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
skip()  { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); }
info()  { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; }

echo -e "${BOLD}mail9p integration tests${NC}"
echo ""

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
for f in dis/mail9p.dis dis/auth/factotum.dis; do
    [[ -f "$ROOT/$f" ]] || { skip "$f not built"; exit 77; }
done

# One emu for the whole exercise: mail9p's state is its process's.  Each
# check below is a grep on a slice of the one transcript.  emu does not
# exit when the script ends, so it is stopped by the timeout.
T=$(mktemp)
trap 'rm -f "$T"' EXIT
cd "$ROOT"
with_timeout 40 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd .)
mount -ac {mntgen} /mnt
mail9p &
sleep 1

echo '<<< 01 root-listing >>>'
ls /mnt/mail

echo '<<< 02 ctl-read-empty >>>'
cat /mnt/mail/ctl

echo '<<< 03 connect-no-credentials >>>'
echo connect alice imap.example.com > /mnt/mail/ctl

echo '<<< 04 connect-unreachable >>>'
auth/factotum
echo 'key proto=pass service=imap dom=127.0.0.1 user=alice !password=x' > /mnt/factotum/ctl
echo connect alice 127.0.0.1 > /mnt/mail/ctl

echo '<<< 05 no-account-left >>>'
ls /mnt/mail/accounts

echo '<<< 06 bad-arg >>>'
echo connect alice 127.0.0.1 bogus > /mnt/mail/ctl

echo '<<< 07 no-server >>>'
echo connect alice > /mnt/mail/ctl

echo '<<< 08 no-name >>>'
echo connect > /mnt/mail/ctl

echo '<<< 09 unknown-verb >>>'
echo nonsense > /mnt/mail/ctl

echo '<<< 10 disconnect-missing >>>'
echo disconnect nosuch > /mnt/mail/ctl

echo '<<< 11 sync-missing >>>'
echo sync nosuch > /mnt/mail/ctl

echo '<<< 12 still-answers >>>'
ls /mnt/mail
ls /mnt/mail/accounts

echo '<<< end >>>'
" </dev/null >"$T" 2>&1
info "$(cat "$T")"

# the lines between <<< NN ... >>> and the next marker
slice() {
    awk -v num="$1" '
        $0 ~ ("<<< " num " ") { capture = 1; next }
        capture && /<<< / { exit }
        capture { print }
    ' "$T"
}

# expect NN 'description' 'pattern': the slice matches the pattern
expect() {
    local out
    out=$(slice "$1")
    if echo "$out" | grep -q -- "$3"; then
        pass "$1 $2"
    else
        fail "$1 $2: got: $out"
    fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

out=$(slice 01)
if echo "$out" | grep -q '/ctl$' && echo "$out" | grep -q '/accounts$'; then
    pass "01 root lists ctl and accounts"
else
    fail "01 root listing: $out"
fi

out=$(slice 02)
if [[ -z "$out" ]]; then
    pass "02 ctl reads empty"
else
    fail "02 ctl read returned: $out"
fi

expect 03 "connect with no credentials refused" 'connect: no credentials.*factotum'
expect 04 "connect to a server not there refused with the dial's error" 'connect: tls.*dial tcp!127.0.0.1!993'

out=$(slice 05)
if [[ -z "$out" ]]; then
    pass "05 refused connects leave no account"
else
    fail "05 accounts after refused connects: $out"
fi

expect 06 "an unknown connect argument refused" 'connect: unrecognised arg: bogus'
expect 07 "connect with no server refused" 'connect: server required'
expect 08 "connect with no name refused" 'connect: name required'
expect 09 "an unknown verb refused" 'unknown ctl verb'
expect 10 "disconnect of no such account refused" 'disconnect: no such account'
expect 11 "sync of no such account refused" 'sync: no such account'
expect 12 "mail9p still answers" '/mnt/mail/ctl'

echo ""
echo -e "Total: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$SKIPPED skipped${NC}"
[[ "$FAILED" -eq 0 ]]
