#!/bin/bash
#
# tests/host/mail9p_imap_test.sh
#
# mail9p against an IMAP server (tests/host/mail9p/fake_imap.py), over
# TLS whose certificate the client verifies.  The test's own CA is the
# only root: a directory holding it is bound over /lib/certs in emu's
# name space, where the TLS client reads its roots.  The certificates are
# made here, with openssl, for 127.0.0.1 (an iPAddress subjectAltName).
#
#   - connect over TLS: the account's ctl, its boxes, INBOX's messages by
#     UID; a message's subject, from and body; its flags set (STORE); a
#     search (SEARCH, the UIDs read back from the box's ctl); archive
#     (COPY to Archive and \Deleted)
#   - connect over STARTTLS: the same server's session after the upgrade
#   - refused: a certificate naming only localhost, for 127.0.0.1; one
#     from a CA not trusted; a server declining STARTTLS
#   - disconnect logs out
#
# Run from project root: ./tests/host/mail9p_imap_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0
[[ "${1:-}" = -v ]] && VERBOSE=1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }
info()  { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; }

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/mail9p.dis dis/auth/factotum.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

# The test CA, a server certificate it signs for 127.0.0.1, one it signs
# naming localhost alone, and one from a CA of its own, not trusted.
cert() {	# name CA subjectAltName
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.csr" -subj "/CN=$1" 2>/dev/null
    printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\n' "$3" > "$D/$1.ext"
    openssl x509 -req -in "$D/$1.csr" -CA "$D/$2.pem" -CAkey "$D/$2.key" \
        -CAcreateserial -days 2 -extfile "$D/$1.ext" -out "$D/$1.pem" 2>/dev/null
}
ca() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.pem" -days 2 -subj "/CN=$1" 2>/dev/null
}
ca testca; ca otherca
cert good testca IP:127.0.0.1
cert localonly testca DNS:localhost
cert stranger otherca IP:127.0.0.1
mkdir -p "$D/certs"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" && -s "$D/stranger.pem" ]] ||
    { echo "FAIL: openssl made no certificates"; exit 1; }

# serve mode cert log -> its port
serve() {
    local pf="$D/$3.port"
    python3 -I "$ROOT/tests/host/mail9p/fake_imap.py" --mode "$1" \
        --cert "$D/$2.pem" --key "$D/$2.key" --log "$D/$3.log" > "$pf" 2>"$D/$3.err" &
    PIDS="$PIDS $!"
    for i in $(seq 50); do [[ -s "$pf" ]] && break; sleep 0.1; done
    head -1 "$pf"
}
P_TLS=$(serve tls good tls)
P_ST=$(serve starttls good starttls)
P_NAME=$(serve tls localonly name)
P_CA=$(serve tls stranger ca)
P_NO=$(serve refuse good refuse)
for p in "$P_TLS" "$P_ST" "$P_NAME" "$P_CA" "$P_NO"; do
    [[ -n "$p" ]] || { echo "FAIL: a fake IMAP server did not start"; cat "$D"/*.err; exit 1; }
done

A=/mnt/mail/accounts/bob
B=$A/boxes/INBOX
T=$D/transcript
with_timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd .)
bind '#U*'$D/certs /lib/certs
mount -ac {mntgen} /mnt
auth/factotum
echo 'key proto=pass service=imap dom=127.0.0.1 user=alice !password=x' > /mnt/factotum/ctl
mail9p &
sleep 1

echo '<<< 01 connect-tls >>>'
echo connect bob 127.0.0.1!$P_TLS > /mnt/mail/ctl

echo '<<< 02 account-ctl >>>'
cat $A/ctl

echo '<<< 03 boxes >>>'
ls $A/boxes

echo '<<< 04 inbox >>>'
ls $B

echo '<<< 05 subject >>>'
cat $B/101/subject

echo '<<< 06 from >>>'
cat $B/101/from

echo '<<< 07 body >>>'
cat $B/101/body

echo '<<< 08 flags-set >>>'
echo '\\Seen' > $B/102/flags
cat $B/102/flags

echo '<<< 09 search >>>'
echo search FROM alice > $B/ctl
cat $B/ctl

echo '<<< 10 archive >>>'
echo archive 101 > $B/ctl

echo '<<< 11 connect-starttls >>>'
echo connect st 127.0.0.1!$P_ST starttls > /mnt/mail/ctl
cat /mnt/mail/accounts/st/ctl

echo '<<< 12 wrong-name >>>'
echo connect name 127.0.0.1!$P_NAME > /mnt/mail/ctl

echo '<<< 13 untrusted-ca >>>'
echo connect ca 127.0.0.1!$P_CA > /mnt/mail/ctl

echo '<<< 14 starttls-refused >>>'
echo connect no 127.0.0.1!$P_NO starttls > /mnt/mail/ctl

echo '<<< 15 disconnect >>>'
echo disconnect bob > /mnt/mail/ctl
echo disconnect st > /mnt/mail/ctl
sleep 1
ls /mnt/mail/accounts

echo '<<< end >>>'
" </dev/null >"$T" 2>&1
info "$(cat "$T")"

slice() {
    awk -v num="$1" '
        $0 ~ ("<<< " num " ") { capture = 1; next }
        capture && /<<< / { exit }
        capture { print }
    ' "$T"
}
# expect NN description pattern: the slice matches
expect() {
    if slice "$1" | grep -q -- "$3"; then pass "$1 $2"; else fail "$1 $2: got: $(slice "$1")"; fi
}
# served log description pattern: the fake server's log has a line matching
served() {
    if grep -q -- "$3" "$D/$1.log"; then pass "$2"; else fail "$2: the server saw: $(cat "$D/$1.log")"; fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

out=$(slice 01)
if [[ -z "$out" ]]; then pass "01 connect over TLS, the certificate verified"; else fail "01 connect over TLS: $out"; fi
expect 02 "the account connected, INBOX selected with its 2 messages" "connected.*box=INBOX.*exists=2"
expect 03 "boxes: INBOX" "/INBOX$"
expect 03 "boxes: Archive" "/Archive$"
expect 04 "INBOX's messages by UID: 101" "/101$"
expect 04 "INBOX's messages by UID: 102" "/102$"
expect 05 "a message's subject" "^Lunch on Friday$"
expect 06 "a message's from" "alice@example.com"
expect 07 "a message's body" "^Shall we meet at noon?"
expect 08 "flags set read back" 'Seen'
served tls "08 flags set: STORE 2 +FLAGS (\\Seen)" '^STORE 2 +FLAGS (\\Seen)$'
expect 09 "search: the matching UID in the box's ctl" "^101$"
served tls "09 search sent: SEARCH FROM alice" '^SEARCH FROM alice$'
served tls "10 archive: COPY 1 to Archive" '^COPY 1 "\?Archive"\?$'
served tls "10 archive: \\Deleted set" '^STORE 1 +FLAGS (\\Deleted)$'
served tls "01 LOGIN with the factotum key's user" '^LOGIN "\?alice"\?$'
expect 11 "connect over STARTTLS, then the session in TLS" "connected.*box=INBOX.*exists=2"
served starttls "11 STARTTLS, then LOGIN inside TLS" '^LOGIN "\?alice"\?$'
expect 12 "a certificate naming only localhost refused for 127.0.0.1" "connect: tlsdial: tls: hostname 127.0.0.1 does not match"
expect 13 "a certificate from an untrusted CA refused" "connect: tlsdial: tls: certificate chain verification failed"
expect 14 "a server declining STARTTLS refused" "connect: STARTTLS refused"
served refuse "14 nothing sent after STARTTLS's NO" '^after NO: nothing$'
served tls "15 disconnect logs out" '^LOGOUT'
out=$(slice 15)
if ! echo "$out" | grep -q /mnt/mail/accounts/; then pass "15 no accounts left"; else fail "15 accounts left: $out"; fi
if grep -q '^LOGIN' "$D/name.log" "$D/ca.log" 2>/dev/null; then
    fail "a refused certificate was logged in to: $(cat "$D/name.log" "$D/ca.log")"
else
    pass "no LOGIN to a server whose certificate was refused"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
