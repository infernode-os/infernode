#!/bin/bash
#
# tests/host/msg_email_bind_test.sh
#
# A reply drafted through /mnt/msg against a mail message goes to that
# message's sender or is not sent: msg9p with the email source
# (appl/veltro/sources/email.b) against the fake IMAP and SMTP servers of
# mail9p_imap_test.sh, over TLS the client verifies (the test's CA bound
# over /lib/certs).
#
# A mail message's id was its IMAP sequence number, which an expunge
# moves: a reply drafted against message 1 and approved after message 1
# had been deleted was addressed to the sender of what had become
# message 1, and /mnt/msg/pending showed the approver a number and no
# recipient.  The id is now <uidvalidity>.<uid>, pending shows To: and
# Subject:, and the reply is refused when the message has gone.
#
#   - pending names whose message each draft answers, and its subject
#   - a sequence number is not an id: a draft against "2" is refused
#   - alice's message expunged between draft and approve: the approved
#     reply to her is refused, and nothing is sent to anyone
#   - the reply to carol, whose message has moved from 2 to 1, is sent to
#     carol, with its subject, authenticated and inside TLS
#   - a flag set by id reaches the message where it now is (STORE 1), and
#     is refused for the message that has gone
#
# Run from project root: ./tests/host/msg_email_bind_test.sh [-v]
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
for f in dis/veltro/msg9p.dis dis/veltro/sources/email.dis dis/auth/factotum.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

# The test's CA and a server certificate it signs for 127.0.0.1.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/testca.key" -out "$D/testca.pem" -days 2 -subj "/CN=testca" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/good.key" -out "$D/good.csr" -subj "/CN=good" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > "$D/good.ext"
openssl x509 -req -in "$D/good.csr" -CA "$D/testca.pem" -CAkey "$D/testca.key" \
    -CAcreateserial -days 2 -extfile "$D/good.ext" -out "$D/good.pem" 2>/dev/null
mkdir -p "$D/certs"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" ]] ||
    { echo "SKIP: openssl made no certificates"; exit 77; }

python3 -I "$ROOT/tests/host/mail9p/fake_imap.py" --mode tls --expunge "$D/expunge" \
    --cert "$D/good.pem" --key "$D/good.key" --log "$D/imap.log" > "$D/imap.port" 2>"$D/imap.err" &
PIDS="$PIDS $!"
python3 -I "$ROOT/tests/host/mail9p/fake_smtp.py" --mode tls \
    --cert "$D/good.pem" --key "$D/good.key" --log "$D/smtp.log" > "$D/smtp.port" 2>"$D/smtp.err" &
PIDS="$PIDS $!"
for i in $(seq 50); do [[ -s "$D/imap.port" && -s "$D/smtp.port" ]] && break; sleep 0.1; done
P=$(head -1 "$D/imap.port"); S=$(head -1 "$D/smtp.port")
[[ -n "$P" && -n "$S" ]] || { echo "FAIL: a fake server did not start"; cat "$D"/*.err; exit 1; }

T=$D/transcript
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd /dis/veltro .)
bind '#U*'$D/certs /lib/certs
mount -ac {mntgen} /mnt
auth/factotum
echo 'key proto=pass service=imap dom=127.0.0.1 user=alice !password=x' > /mnt/factotum/ctl
echo 'key proto=pass service=smtp dom=127.0.0.1 user=bob@example.com !password=x' > /mnt/factotum/ctl
msg9p >[2] /dev/null
echo register email /dis/veltro/sources/email.dis 'server=127.0.0.1!$P' 'smtpserver=127.0.0.1!$S' > /mnt/msg/ctl

echo '<<< 01 status >>>'
cat /mnt/msg/status
echo

echo '<<< 02 draft-carol >>>'
echo 'email
7.102
for carol' > /mnt/msg/draft
echo '<<< 03 draft-alice >>>'
echo 'email
7.101
for alice alone' > /mnt/msg/draft
echo '<<< 04 draft-by-number >>>'
echo 'email
2
by sequence number' > /mnt/msg/draft

echo '<<< 05 pending >>>'
cat /mnt/msg/pending

echo 101 > '#U*'$D/expunge
echo '<<< 06 approve-alice >>>'
echo approve 2 > /mnt/msg/approve
echo '<<< 07 smtp-after-refusal >>>'
cat '#U*'$D/smtp.log

echo '<<< 08 approve-carol >>>'
echo approve 1 > /mnt/msg/approve

echo '<<< 09 flag-gone >>>'
echo email 7.101 seen > /mnt/msg/flag
echo '<<< 10 flag-moved >>>'
echo email 7.102 flagged > /mnt/msg/flag
echo '<<< 11 other-validity >>>'
echo email 8.102 flagged > /mnt/msg/flag

echo '<<< end >>>'
echo halt > /dev/sysctl
" </dev/null >"$T" 2>&1
info "$(cat "$T")"
info "imap: $(cat "$D/imap.log")"
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
empty() {
    out=$(slice "$1")
    if [[ -z "$out" ]]; then pass "$1 $2"; else fail "$1 $2: $out"; fi
}
served() {
    if grep -q -- "$3" "$D/$1.log"; then pass "$2"; else fail "$2: the server saw: $(cat "$D/$1.log")"; fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

expect 01 "the mail source connected, the certificate verified" "email: connected.*2 messages"
empty 02 "a draft against carol's message queued"
empty 03 "a draft against alice's message queued"
expect 04 "a sequence number is not a message's id" "has no message 2"
expect 05 "pending: the reply to carol, by UID" "^1 email 7\.102 9 for carol$"
expect 05 "pending: it goes to carol" "^	To: .*carol"
expect 05 "pending: its subject" "^	Subject: The report$"
expect 05 "pending: the reply to alice" "^	To: .*alice"
expect 05 "pending: its subject" "^	Subject: Lunch on Friday$"
if slice 05 | grep -q "by sequence number"; then fail "05 the refused draft is pending"; else pass "05 the refused draft is not pending"; fi
expect 06 "alice's message expunged: the approved reply is not sent" "not sent.*no longer"
if slice 07 | grep -q "RCPT\|^data\|MAIL"; then
    fail "07 something was sent on the refused approval: $(slice 07)"
else
    pass "07 nothing sent to anyone on the refused approval"
fi
empty 08 "the reply to carol approved"
served smtp "08 sent to carol, whose message is now number 1" '^RCPT TO:<carol@example.org>$'
served smtp "08 with her message's subject" '^data Subject: Re: The report$'
served smtp "08 authenticated, as the factotum key's user" '^user bob@example.com$'
if grep -q 'RCPT TO:<alice' "$D/smtp.log"; then fail "08 a reply went to alice"; else pass "08 nothing went to alice"; fi
if [[ "$(grep -c '^RCPT' "$D/smtp.log")" = 1 ]]; then pass "08 one message sent in all"; else fail "08 messages sent: $(grep '^RCPT' "$D/smtp.log")"; fi
served imap "08 the message found by its UID each time" '^SEARCH UID 102$'
served imap "08 carol's message marked answered where it is now" '^STORE 1 +FLAGS (\\Answered)$'
expect 09 "a flag for the message that has gone is refused" "no longer in INBOX"
empty 10 "a flag for the message that has moved is taken"
served imap "10 and set on it where it is now" '^STORE 1 +FLAGS (\\Flagged)$'
expect 11 "an id from another UIDVALIDITY names nothing" "ids have changed"
if grep -q '^STORE 2 ' "$D/imap.log"; then fail "a flag was set by a stale number: $(grep '^STORE' "$D/imap.log")"; else pass "no STORE by a stale number"; fi

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
