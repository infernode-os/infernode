#!/bin/bash
#
# tests/host/mail9p_send_test.sh
#
# Who a message written to mail9p's compose goes to, and with whose
# password, against the fake IMAP and SMTP servers of
# mail9p_imap_test.sh over TLS under the test's own CA.  A connection
# server of the test's own (tests/fakecs.b) gives the IMAP server the
# name imap.test; no other name is translated, so nothing here is looked
# up or dialled but the loopback.
#
#   - an account connected to imap.test with no smtp= has smtp.test as
#     its SMTP server, a name mail9p made up.  The password of the key
#     "service=imap dom=imap.test" is not sent there: the send is
#     refused, saying which key is wanted.  (It was tried: the send went
#     on to dial smtp.test with the IMAP key's user and password.)  With
#     a "service=smtp dom=smtp.test" key the send goes on to dial; with
#     smtp= naming the host, the IMAP key is used as before.
#   - compose's recipients are its To:, Cc: and Bcc: addresses, every
#     occurrence, folded lines and names with a comma in them included;
#     the Bcc: header is not in what is sent.  (To: alone was read: a Cc
#     got nothing, and a Bcc was only a header every recipient saw.)
#   - a draft-reply with a Cc: or Bcc: of its own is refused: a reply
#     goes to the message's sender.
#   - a mailbox's UIDVALIDITY past 2^31 is kept whole: the msg service's
#     ids are "<uidvalidity>.<uid>" with the server's number, and an id
#     under the validity one above it names nothing.  (Both were
#     2147483647.)
#
# Run from project root: ./tests/host/mail9p_send_test.sh [-v]
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
for f in dis/mail9p.dis dis/auth/factotum.dis dis/veltro/msg9p.dis dis/veltro/sources/email.dis tests/fakecs.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

# The test's CA and a certificate it signs for imap.test and 127.0.0.1.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/testca.key" -out "$D/testca.pem" -days 2 -subj "/CN=testca" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/good.key" -out "$D/good.csr" -subj "/CN=good" 2>/dev/null
printf 'subjectAltName=DNS:imap.test,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > "$D/good.ext"
openssl x509 -req -in "$D/good.csr" -CA "$D/testca.pem" -CAkey "$D/testca.key" \
    -CAcreateserial -days 2 -extfile "$D/good.ext" -out "$D/good.pem" 2>/dev/null
mkdir -p "$D/certs"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" ]] ||
    { echo "SKIP: openssl made no certificates"; exit 77; }

# start name program args... -> its port
start() {
    local name=$1 prog=$2; shift 2
    python3 -I "$ROOT/tests/host/mail9p/$prog" --mode tls --cert "$D/good.pem" --key "$D/good.key" \
        --log "$D/$name.log" "$@" > "$D/$name.port" 2>"$D/$name.err" &
    PIDS="$PIDS $!"
    for i in $(seq 50); do [[ -s "$D/$name.port" ]] && break; sleep 0.1; done
    head -1 "$D/$name.port"
}
P=$(start imap fake_imap.py)
PV=$(start imapv fake_imap.py --validity 4000000000)
S=$(start smtp fake_smtp.py --wire "$D/smtp.wire")
for p in "$P" "$PV" "$S"; do
    [[ -n "$p" ]] || { echo "FAIL: a fake server did not start"; cat "$D"/*.err; exit 1; }
done

G=/mnt/mail/accounts/g
N=/mnt/mail/accounts/n
T=$D/transcript
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd /dis/veltro .)
bind '#U*'$D/certs /lib/certs
/tests/fakecs.dis 'imap.test=127.0.0.1' '127.0.0.1=127.0.0.1'
mount -ac {mntgen} /mnt
auth/factotum
echo 'key proto=pass service=imap dom=imap.test user=alice !password=x' > /mnt/factotum/ctl
echo 'key proto=pass service=imap dom=127.0.0.1 user=alice !password=x' > /mnt/factotum/ctl
mail9p &
sleep 1

echo '<<< 01 connect >>>'
echo connect g imap.test!$P > /mnt/mail/ctl
cat $G/ctl

echo '<<< 02 guessed-host >>>'
echo 'From: alice@example.com
To: carol@example.org
Subject: To a guessed host

Hi.' > $G/compose
cat $G/compose

echo '<<< 03 its-own-key >>>'
echo 'key proto=pass service=smtp dom=smtp.test user=alice !password=y' > /mnt/factotum/ctl
echo 'From: alice@example.com
To: carol@example.org
Subject: With the key of the SMTP host

Hi.' > $G/compose
cat $G/compose

echo '<<< 04 named-host >>>'
echo connect n imap.test!$P 'smtp=127.0.0.1!$S' > /mnt/mail/ctl
echo 'From: alice@example.com
To: carol@example.org, \"Doe, John\" <john@example.net>
Cc: dave@example.org,
	Erin <erin@example.org>
Bcc: frank@example.org,
 grace@example.org
Subject: To all of them
cc: heidi@example.org

Hi.' > $N/compose
cat $N/compose

echo '<<< 05 reply-cc >>>'
echo 'Cc: mallory@evil.example

Sure.' > $N/boxes/INBOX/102/draft-reply
cat $N/boxes/INBOX/102/draft-reply

echo '<<< 06 nobody >>>'
echo 'From: alice@example.com
Subject: To nobody

Hi.' > $N/compose
cat $N/compose

echo disconnect g > /mnt/mail/ctl
echo disconnect n > /mnt/mail/ctl

echo '<<< 07 validity >>>'
msg9p >[2] /dev/null
echo register email /dis/veltro/sources/email.dis 'server=127.0.0.1!$PV' 'smtpserver=127.0.0.1!$S' > /mnt/msg/ctl
cat /mnt/msg/status
echo
echo 'email
4000000000.102
for carol' > /mnt/msg/draft
echo '<<< 08 pending >>>'
cat /mnt/msg/pending
echo '<<< 09 other-validity >>>'
echo email 4000000001.102 flagged > /mnt/msg/flag
echo '<<< 10 clamped-validity >>>'
echo email 2147483647.102 flagged > /mnt/msg/flag

echo '<<< end >>>'
echo halt > /dev/sysctl
" </dev/null >"$T" 2>&1
info "$(cat "$T")"
info "smtp: $(cat "$D/smtp.log")"

slice() {
    awk -v num="$1" '
        $0 ~ ("<<< " num " ") { capture = 1; next }
        capture && /<<< / { exit }
        capture { print }
    ' "$T"
}
expect() {
    if slice "$1" | grep -q -- "$3"; then pass "$1 $2"; else fail "$1 $2: got: $(slice "$1")"; fi
}
refuse() {
    if slice "$1" | grep -q -- "$3"; then fail "$1 $2: got: $(slice "$1")"; else pass "$1 $2"; fi
}
served() {
    if grep -q -- "$3" "$D/$1"; then pass "$2"; else fail "$2: the server saw: $(cat "$D/$1")"; fi
}
unserved() {
    if grep -q -- "$3" "$D/$1"; then fail "$2: the server saw: $(grep -- "$3" "$D/$1")"; else pass "$2"; fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

expect 01 "the account connected to imap.test, its certificate verified" "connected.*box=INBOX.*exists=2"
expect 02 "the IMAP key is not sent to a host mail9p made up" "^not sent: no service=smtp key in factotum for smtp.test"
refuse 02 "no connection was tried with it" "authopen"
expect 03 "with the SMTP host's own key the send goes on to dial it" "^not sent: smtp authopen"
expect 04 "a host named with smtp= is sent the IMAP key, and the message" "^sent to "
served smtp.log "04 authenticated as the IMAP key's user" '^user alice$'
for r in carol@example.org john@example.net dave@example.org erin@example.org \
         frank@example.org grace@example.org heidi@example.org; do
    served smtp.log "04 delivered to $r" "^RCPT TO:<$r>\$"
done
if [[ "$(grep -c '^RCPT' "$D/smtp.log")" = 7 ]]; then pass "04 and to nobody else"; else fail "04 recipients: $(grep '^RCPT' "$D/smtp.log")"; fi
unserved smtp.wire "04 no Bcc header in what was sent" "^data b'[Bb]cc:"
unserved smtp.wire "04 nor a Bcc's address anywhere in it" "^data b'.*\(frank\|grace\)@"
served smtp.wire "04 the Cc header is in it" "^data b'Cc: dave@example.org,"
served smtp.wire "04 with its continuation line" "^data b'.*Erin <erin@example.org>"
served smtp.wire "04 and the subject after the header taken out" "^data b'Subject: To all of them"
expect 05 "a reply with a Cc of its own is refused" "leave Cc and Bcc out"
unserved smtp.log "05 nothing went to the address it named" 'mallory'
expect 06 "a message naming nobody is refused, saying so" "names nobody to send to"
expect 07 "the msg service's mail source connected" "email: connected.*2 messages"
expect 08 "a UIDVALIDITY past 2^31 is the id's, whole" "^1 email 4000000000\.102 "
expect 09 "an id under the validity one above it names nothing" "ids have changed"
expect 10 "nor does one under the largest int" "ids have changed"

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
