#!/bin/bash
#
# tests/host/mail9p_hostile_test.sh
#
# mail9p, imap(2) and smtp(2) against servers that are hostile, broken or
# gone, and against the holders of its files: the fake IMAP and SMTP
# servers of mail9p_imap_test.sh in their --scen modes, over TLS under
# the test's own CA (bound over /lib/certs), on 127.0.0.1 only.  Each
# scenario has an emulator of its own, so that one that ends mail9p does
# not hide the rest; they run a few at a time.  ONLY=name runs one.
#
#   uid        after another client's expunge, archive, flags and body
#              act on the message named, by UID; sync lists what is there
#   slot       descriptors held on a disconnected account's files name
#              nothing once another account is connected
#   inject     a line break in a box's search or move is refused, and
#              move takes only a box the account lists; a box's ctl
#              reads only its own search
#   reply      a reply goes to the address, not the display form; to
#              Reply-To, which the replyto file shows; never From the
#              writer's choice; \Answered only when stored
#   bigcompose a message of 100K written 8K at a time is sent once, whole
#   authleak   a refused, an echoed and an unanswered AUTH: the error has
#              no credential in it, and no process is left behind
#   smtpproto  a blank reply line ends the send, not the reader; DATA
#              answered 250 sends no message; a carriage return inside a
#              body line ends the line (and a dot after it is doubled),
#              inside a header line refuses the message
#   exists biglit backslash spoof tagforge unsol envcrlf
#              a server's counts, literals and strings (see fake_imap.py):
#              each is refused or read as data, and another account's
#              files answer throughout
#   stall close idleclose
#              a server that stops answering, hangs up, or closes an idle
#              connection: the request ends by its deadline, the other
#              account and the tree answer meanwhile, and the next use
#              connects again
#   unmount    the sessions are logged out and no process is left
#
# Run from project root: ./tests/host/mail9p_hostile_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0
[[ "${1:-}" = -v ]] && VERBOSE=1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/mail9p.dis dis/auth/factotum.dis tests/mail9p_hold.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
trap 'kill $(cat "$D"/*.pid 2>/dev/null) 2>/dev/null; rm -rf "$D"' EXIT
cd "$ROOT"

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

# imap LABEL args...: a fake IMAP server, its port in $D/LABEL.port
imap() {
    local l=$1; shift
    python3 -I "$ROOT/tests/host/mail9p/fake_imap.py" --mode tls --msgs 3 \
        --cert "$D/good.pem" --key "$D/good.key" --log "$D/$l.log" "$@" > "$D/$l.port" 2>"$D/$l.err" &
    echo $! > "$D/$l.pid"
    for i in $(seq 50); do [[ -s "$D/$l.port" ]] && break; sleep 0.1; done
}
# smtp LABEL args...: a fake SMTP server; what it was sent in $D/LABEL.wire
smtp() {
    local l=$1; shift
    python3 -I "$ROOT/tests/host/mail9p/fake_smtp.py" --mode tls \
        --cert "$D/good.pem" --key "$D/good.key" --log "$D/$l.log" --wire "$D/$l.wire" "$@" > "$D/$l.port" 2>"$D/$l.err" &
    echo $! > "$D/$l.pid"
    for i in $(seq 50); do [[ -s "$D/$l.port" ]] && break; sleep 0.1; done
}
port() { head -1 "$D/$1.port"; }

# emu NAME TIMEOUT SCRIPT: mail9p (a deadline of 3 seconds for its
# servers) and the script, the transcript in $D/NAME.out
emu() {
    with_timeout "$2" "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd .)
bind '#U*'$D/certs /lib/certs
mount -ac {mntgen} /mnt
auth/factotum
echo 'key proto=pass service=imap dom=127.0.0.1 user=alice@example.com !password=x' > /mnt/factotum/ctl
mail9p -t 3 &
sleep 1
$3
echo '<<< end >>>'
echo halt > /dev/sysctl
" </dev/null >"$D/$1.out" 2>&1
}

G=/mnt/mail/accounts/g
A=/mnt/mail/accounts/a
B=$A/boxes/INBOX
MSG='From: alice@example.com
To: carol@example.org
Subject: A message

Hi.'

s_uid() {
    imap uid-a --expunge "$D/uid.expunge"; smtp uid-s
    emu uid 40 "
echo connect a 127.0.0.1!$(port uid-a) 'smtp=127.0.0.1!$(port uid-s)' > /mnt/mail/ctl
echo 101 > '#U*'$D/uid.expunge
echo '<<< archive >>>'
echo archive 102 > $B/ctl
echo '<<< body >>>'
cat $B/102/body
echo '<<< flags >>>'
echo '\\Flagged' > $B/102/flags
echo '<<< sync >>>'
echo sync > $A/ctl
ls $B
cat $A/ctl"
}
c_uid() {
    served uid-a "after an expunge, archive 102 copies UID 102" '^UID COPY 102 "\?Archive"\?$'
    served uid-a "and marks UID 102 deleted" '^UID STORE 102 +FLAGS (\\Deleted)$'
    expect uid body "102's body is 102's text" '^It is attached'
    served uid-a "a flag written to 102 is stored on UID 102" '^UID STORE 102 +FLAGS (\\Flagged)$'
    expect uid sync "sync lists what is there now: 102" '/102$'
    refuse uid sync "and not the message that has gone" '/101$'
    expect uid sync "the account's ctl counts them" 'exists=2'
}

s_slot() {
    imap slot-a --who A; imap slot-b --who B; smtp slot-s1; smtp slot-s2
    emu slot 40 "
echo connect a 127.0.0.1!$(port slot-a) 'smtp=127.0.0.1!$(port slot-s1)' > /mnt/mail/ctl
/tests/mail9p_hold.dis a 'disconnect a' 'connect b 127.0.0.1!$(port slot-b) smtp=127.0.0.1!$(port slot-s2)'
echo '<<< accounts >>>'
ls /mnt/mail/accounts
cat /mnt/mail/accounts/b/boxes/INBOX/101/subject"
}
c_slot() {
    expect slot "" "the descriptors were on account a" '^hold: before: subject reads: A Lunch'
    expect slot "" "a's ctl descriptor names nothing after b is connected" '^hold: after: ctl: error'
    expect slot "" "nor does a's message's" '^hold: after: subject: error'
    expect slot "" "nor does a's compose" '^hold: after: compose: error'
    refuse slot "" "none of them reads b's mail" '^hold: after: .*reads: '
    expect slot accounts "b is connected, with its own mail" '^B Lunch'
    if grep -q 'MAIL FROM' "$D/slot-s2.log" "$D/slot-s1.log"; then
        fail "slot: mail was sent through an SMTP server by the old descriptor: $(cat "$D/slot-s2.log")"
    else
        pass "slot: nothing was sent through either SMTP server"
    fi
}

s_inject() {
    imap inject-a; smtp inject-s
    emu inject 40 "
echo connect a 127.0.0.1!$(port inject-a) 'smtp=127.0.0.1!$(port inject-s)' > /mnt/mail/ctl
echo '<<< search >>>'
echo 'search ALL
X1 DELETE Archive' > $B/ctl
echo '<<< move >>>'
echo 'move 102 Nowhere
X2 DELETE Sent' > $B/ctl
echo '<<< nobox >>>'
echo 'move 102 Nowhere' > $B/ctl
echo '<<< listed >>>'
echo 'move 102 Sent' > $B/ctl
echo '<<< other >>>'
echo search ALL > $B/ctl
echo inbox: ; cat $B/ctl
echo sent: ; cat $A/boxes/Sent/ctl
echo end-of-sent"
}
c_inject() {
    expect inject search "a search with a line break in it is refused" 'write error: search: .*line break'
    expect inject move "a move to a name with a line break in it is refused" 'write error'
    expect inject nobox "a move to a box the account does not list is refused" 'write error: no such box'
    out=$(slice inject listed)
    if [[ -z "$out" ]]; then pass "inject: a move to a listed box is done"; else fail "inject: a move to a listed box: $out"; fi
    served inject-a "the listed box is the one copied to" '^UID COPY 102 "\?Sent"\?$'
    if grep -q 'DELETE\|Nowhere' "$D/inject-a.log"; then
        fail "inject: the server was sent the injected command: $(grep 'DELETE\|Nowhere' "$D/inject-a.log")"
    else
        pass "inject: nothing after the line break, and no unlisted box, reached the server"
    fi
    expect inject other "the box searched reads its search" '^101$'
    if slice inject other | sed -n '/^sent:/,/^end-of-sent/p' | grep -q '^10'; then
        fail "inject: another box's ctl read the search: $(slice inject other)"
    else
        pass "inject: another box's ctl does not read it"
    fi
}

s_reply() {
    imap reply-a; smtp reply-s
    emu reply 50 "
echo connect a 127.0.0.1!$(port reply-a) 'smtp=127.0.0.1!$(port reply-s)' > /mnt/mail/ctl
echo '<<< files >>>'
ls $B/103
echo '<<< who >>>'
echo from: ; cat $B/103/from
echo replyto: ; cat $B/103/replyto
echo '<<< r101 >>>'
echo 'Thanks.' > $B/101/draft-reply
cat $A/compose
echo '<<< r103 >>>'
echo 'Here they are.' > $B/103/draft-reply
cat $A/compose
cat $B/103/flags
echo '<<< rfrom >>>'
echo 'From: ceo@corp.example

Pay the invoice.' > $B/102/draft-reply
cat $A/compose
cat $B/102/flags"
}
c_reply() {
    expect reply files "a message has a replyto file" '/replyto$'
    expect reply who "which shows where a reply will go" '^Collector <collector@elsewhere.example>$'
    expect reply r101 "a reply to a sender with a display name is sent" '^sent to alice@example.com$'
    wired reply-s "its RCPT is the address" "^cmd b'RCPT TO:<alice@example.com>"
    expect reply r103 "a reply to a message with a Reply-To goes there" '^sent to collector@elsewhere.example$'
    wired reply-s "as its RCPT says" "^cmd b'RCPT TO:<collector@elsewhere.example>"
    expect reply r103 "and the message is marked answered" 'Answered'
    expect reply rfrom "a reply with a From of its own is not sent" '^not sent: a reply is from the account'
    refuse reply rfrom "nor marked answered" 'Answered'
    if grep -q 'ceo@corp' "$D/reply-s.wire"; then
        fail "reply: the writer's From reached the SMTP server: $(grep ceo "$D/reply-s.wire")"
    else
        pass "reply: the writer's From did not reach the SMTP server"
    fi
}

s_bigcompose() {
    imap big-a; smtp big-s
    python3 -c "
print('From: alice@example.com\nTo: carol@example.org\nSubject: big\n')
for i in range(1600): print('line %04d of the body, sixty-four characters long, more or less.' % i)
print('.\n..leading dots\nlast line')" > "$D/big.txt"
    emu bigcompose 50 "
echo connect a 127.0.0.1!$(port big-a) 'smtp=127.0.0.1!$(port big-s)' > /mnt/mail/ctl
echo '<<< send >>>'
cat '#U*'$D/big.txt > $A/compose
cat $A/compose"
}
c_bigcompose() {
    expect bigcompose send "a 100K message written 8K at a time is sent" '^sent to carol@example.org$'
    n=$(grep -c "^cmd b'DATA" "$D/big-s.wire")
    lines=$(grep -c "^data b'line [0-9]* of the body" "$D/big-s.wire")
    if [[ "$n" = 1 && "$lines" = 1600 ]]; then
        pass "bigcompose: one message, with every line of it"
    else
        fail "bigcompose: $n messages with $lines of the 1600 lines"
    fi
    wired big-s "a line that is a dot is sent with another" "^data b'\.\.\\\\r\\\\n'"
    wired big-s "its last line is the last sent before the end" "^data b'last line"
}

# alice@example.com NUL alice@example.com NUL x
CRED=YWxpY2VAZXhhbXBsZS5jb20AYWxpY2VAZXhhbXBsZS5jb20AeA==
s_authleak() {
    imap leak-a; smtp leak-f --scen authfail; smtp leak-e --scen authecho; smtp leak-st --scen authstall
    emu authleak 60 "
echo connect a 127.0.0.1!$(port leak-a) 'smtp=127.0.0.1!$(port leak-f)' > /mnt/mail/ctl
echo connect e 127.0.0.1!$(port leak-a) 'smtp=127.0.0.1!$(port leak-e)' > /mnt/mail/ctl
echo connect st 127.0.0.1!$(port leak-a) 'smtp=127.0.0.1!$(port leak-st)' > /mnt/mail/ctl
ps > /tmp/mail9p.ps.before
echo '<<< refused >>>'
echo '$MSG' > $A/compose
cat $A/compose
echo '$MSG' > $A/compose
cat $A/compose
echo '$MSG' > $A/compose
cat $A/compose
echo '<<< echoed >>>'
echo '$MSG' > /mnt/mail/accounts/e/compose
cat /mnt/mail/accounts/e/compose
echo '<<< unanswered >>>'
echo '$MSG' > /mnt/mail/accounts/st/compose
cat /mnt/mail/accounts/st/compose
echo '<<< procs >>>'
sleep 1
ps > /tmp/mail9p.ps.after
echo before: ; wc -l < /tmp/mail9p.ps.before
echo after: ; wc -l < /tmp/mail9p.ps.after
grep -i 'broken' /tmp/mail9p.ps.after"
}
c_authleak() {
    expect authleak refused "a refused AUTH is the send's error" '^not sent: .*AUTH credentials refused: 535'
    expect authleak echoed "so is one whose refusal says the credential back" '^not sent: .*AUTH credentials refused: 535'
    expect authleak unanswered "and one never answered, at its deadline" '^not sent: .*AUTH credentials receive failed (smtp timed out)'
    if grep -q "$CRED" "$D/authleak.out"; then
        fail "authleak: the credential is in what the sender was told: $(grep "$CRED" "$D/authleak.out" | head -3)"
    else
        pass "authleak: the credential is in nothing the sender was told"
    fi
    b=$(slice authleak procs | sed -n '/^before:/{n;p}' | tr -d ' ')
    a=$(slice authleak procs | sed -n '/^after:/{n;p}' | tr -d ' ')
    if [[ -n "$b" && "$a" -le "$b" ]]; then
        pass "authleak: five failed sends left no process ($b before, $a after)"
    else
        fail "authleak: processes left by failed sends: $b before, $a after"
    fi
    refuse authleak procs "no process is broken" 'roken'
}

s_smtpproto() {
    imap proto-a; smtp proto-b --scen blank; smtp proto-d --scen data250; smtp proto-c
    printf 'From: alice@example.com\nTo: carol@example.org\nSubject: cr\n\na\r.\rb\n' > "$D/crbody.txt"
    printf 'From: alice@example.com\nTo: carol@example.org\nSubject: x\rBcc: w@f.example\n\nbody\n' > "$D/crhdr.txt"
    emu smtpproto 50 "
echo connect a 127.0.0.1!$(port proto-a) 'smtp=127.0.0.1!$(port proto-b)' > /mnt/mail/ctl
echo connect d 127.0.0.1!$(port proto-a) 'smtp=127.0.0.1!$(port proto-d)' > /mnt/mail/ctl
echo connect c 127.0.0.1!$(port proto-a) 'smtp=127.0.0.1!$(port proto-c)' > /mnt/mail/ctl
echo '<<< crbody >>>'
cat '#U*'$D/crbody.txt > /mnt/mail/accounts/c/compose
cat /mnt/mail/accounts/c/compose
echo '<<< crhdr >>>'
cat '#U*'$D/crhdr.txt > /mnt/mail/accounts/c/compose
cat /mnt/mail/accounts/c/compose
echo '<<< blank >>>'
echo '$MSG' > $A/compose
cat $A/compose
ps | grep -i 'broken'
echo '<<< data250 >>>'
echo '$MSG' > /mnt/mail/accounts/d/compose
cat /mnt/mail/accounts/d/compose"
}
c_smtpproto() {
    expect smtpproto blank "a reply line of no characters ends the send with an error" '^not sent: .*not an SMTP reply'
    refuse smtpproto blank "and breaks no process" 'roken'
    expect smtpproto data250 "DATA answered 250 is refused" '^not sent: .*DATA refused: 250'
    if grep -q "Subject\|Hi\." "$D/proto-d.wire"; then
        fail "smtpproto: the message was sent after DATA was not answered 354: $(cat "$D/proto-d.wire")"
    else
        pass "smtpproto: no line of the message was sent"
    fi
    expect smtpproto crbody "a message with carriage returns in a body line is sent" '^sent to carol@example.org$'
    wired proto-c "the carriage return ends the line" "^data b'a\\\\r\\\\n'\$"
    wired proto-c "and the dot after it is sent with another" "^data b'\.\.\\\\r\\\\n'\$"
    if grep -q "^data b'\.\\\\r'\|^data b'a\\\\r\.\\\\rb" "$D/proto-c.wire"; then
        fail "smtpproto: a bare carriage return was sent: $(grep '^data' "$D/proto-c.wire")"
    else
        pass "smtpproto: no bare carriage return was sent"
    fi
    expect smtpproto crhdr "a carriage return inside a header line refuses the message" '^not sent: .*header line of the message holds a carriage return'
    if grep -q 'Bcc' "$D/proto-c.wire"; then
        fail "smtpproto: the header after the carriage return was sent: $(grep Bcc "$D/proto-c.wire")"
    else
        pass "smtpproto: nothing of it was sent"
    fi
}

# A hostile server's account beside a good one: after the connect, the
# good account's files and the tree answer, and the scenario's own checks.
s_parse() {
    local sc=$1
    imap $sc-g --who G; imap $sc-a --scen $sc; smtp $sc-s
    emu $sc 50 "
echo connect g 127.0.0.1!$(port $sc-g) 'smtp=127.0.0.1!$(port $sc-s)' > /mnt/mail/ctl
echo '<<< connect >>>'
echo connect a 127.0.0.1!$(port $sc-a) 'smtp=127.0.0.1!$(port $sc-s)' > /mnt/mail/ctl
echo '<<< good >>>'
cat $G/ctl
cat $G/boxes/INBOX/102/body
ls /mnt/mail
echo '<<< ctl >>>'
cat $A/ctl
echo '<<< list >>>'
ls $B
echo '<<< m103 >>>'
echo from: ; cat $B/103/from
echo subject: ; cat $B/103/subject
echo '<<< b102 >>>'
cat $B/102/body
echo '<<< reply >>>'
sh -c {echo 'A reply.' > $B/103/draft-reply; cat $A/compose}
echo '<<< procs >>>'
ps | grep -i 'broken'"
}
c_parse() {
    local sc=$1
    grep -q '<<< end >>>' "$D/$sc.out" || fail "$sc: the script did not finish: $(tail -3 "$D/$sc.out")"
    expect $sc good "the good account's ctl answers after the hostile one's connect" '^connected .*exists=3'
    expect $sc good "and its message's text" '^G It is attached'
    expect $sc good "and the tree" '/mnt/mail/accounts$'
    refuse $sc procs "no process is broken" 'roken'
    case $sc in
    exists)
        expect $sc ctl "2^31 messages said to exist: the account is connected, with none listed" 'exists=2147483647 .*listed=0'
        ;;
    biglit)
        expect $sc connect "a literal of 1.5GB is refused, with the connect" 'write error: connect: .*literal of 1500000000 bytes'
        ;;
    backslash)
        expect $sc list "a string ending in a backslash: the mailbox is listed all the same" '/101$'
        expect $sc list "with the messages after it" '/103$'
        ;;
    spoof)
        expect $sc m103 "a subject sent as a literal is the subject" '^((.Alice Example. NIL .alice. .example.com.))'
        expect $sc m103 "and the From is the message's own" '^Mallory <mallory@evil.example>$'
        refuse $sc m103 "not the one the subject holds" '^Alice'
        expect $sc reply "a reply goes to the address the server gave" "^sent to mallory@evil.example\$"
        ;;
    tagforge)
        expect $sc list "two literals in one line: every message is listed, 101" '/101$'
        expect $sc list "102" '/102$'
        expect $sc list "and 103, after the line that held a tagged answer" '/103$'
        ;;
    unsol)
        expect $sc b102 "a message's text is the one asked for" '^It is attached'
        refuse $sc b102 "not another's the server sent after it" 'Shall we meet'
        ;;
    envcrlf)
        expect $sc reply "a reply to an address with a line break in it is refused" '^not sent: .*not an address'
        if grep -q 'victim\|X-Injected' "$D/$sc-s.wire" 2>/dev/null; then
            fail "$sc: the SMTP server was sent the injected lines: $(grep 'victim\|X-Injected' "$D/$sc-s.wire")"
        else
            pass "$sc: nothing of it reached the SMTP server"
        fi
        ;;
    esac
}

s_net() {
    local sc=$1
    imap $sc-g --who G; imap $sc-a --scen $sc; smtp $sc-s
    emu $sc 60 "
echo connect g 127.0.0.1!$(port $sc-g) 'smtp=127.0.0.1!$(port $sc-s)' > /mnt/mail/ctl
echo '<<< connect >>>'
{echo connect a 127.0.0.1!$(port $sc-a) 'smtp=127.0.0.1!$(port $sc-s)' > /mnt/mail/ctl; echo connect returned}&
sleep 1
{cat $B/102/body; echo body returned}&
sleep 1
echo '<<< meanwhile >>>'
ls /mnt/mail/accounts
cat $G/ctl
cat $G/boxes/INBOX/101/subject
echo answered
echo '<<< later >>>'
sleep 6
cat $A/ctl
echo '<<< again >>>'
cat $B/102/body
cat $A/ctl
echo '<<< procs >>>'
ps | grep -i 'broken'"
}
c_net() {
    local sc=$1
    grep -q '<<< end >>>' "$D/$sc.out" || fail "$sc: the script did not finish: $(tail -3 "$D/$sc.out")"
    expect $sc meanwhile "while its server is silent the tree is listed" '/mnt/mail/accounts/g$'
    expect $sc meanwhile "the other account's ctl is read" '^connected .*exists=3'
    expect $sc meanwhile "and its mail" '^G Lunch on Friday'
    expect $sc meanwhile "at once" '^answered$'
    refuse $sc procs "no process is broken" 'roken'
    case $sc in
    stall)
        expect $sc "" "a connect never answered ends at its deadline, naming the account" 'write error: connect: .*a: .*timed out'
        ;;
    close)
        expect $sc "" "a connect hung up on ends with an error" 'write error: connect: '
        ;;
    idleclose)
        expect $sc "" "a read on a connection the server closed ends with an error" 'error reading .*/102/body: fetch: '
        expect $sc later "and the account says it is not connected, and why" '^disconnected .*(.*)'
        expect $sc again "the next read connects again and has the text" '^It is attached'
        expect $sc again "and the account is connected" '^connected '
        ;;
    esac
}

s_unmount() {
    imap un-a; smtp un-s
    emu unmount 40 "
echo connect a 127.0.0.1!$(port un-a) 'smtp=127.0.0.1!$(port un-s)' > /mnt/mail/ctl
cat $A/ctl
unmount /mnt/mail
sleep 2
echo '<<< log >>>'
cat '#U*'$D/un-a.log
echo '<<< procs >>>'
ps | grep -i 'mail9p\|mailconn\|imap\|webclient\|tls'
echo end-of-procs"
}
c_unmount() {
    expect unmount log "after the unmount the session is logged out" '^LOGOUT'
    refuse unmount procs "and no process of mail9p or its connection is left" 'Mail9p\|Mailconn\|Imap\|Webclient\|TLS'
}

slice() {	# name marker: the transcript from "<<< marker >>>" to the next
    if [[ -z "$2" ]]; then cat "$D/$1.out"; return; fi
    awk -v m="<<< $2 >>>" '
        $0 == m { capture = 1; next }
        capture && /^<<< / { exit }
        capture { print }
    ' "$D/$1.out"
}
expect() {	# name marker description pattern
    if slice "$1" "$2" | grep -q -- "$4"; then pass "$1: $3"; else fail "$1: $3: got: $(slice "$1" "$2" | head -12)"; fi
}
refuse() {	# name marker description pattern: the slice has no such line
    if slice "$1" "$2" | grep -q -- "$4"; then fail "$1: $3: got: $(slice "$1" "$2" | grep -- "$4" | head -5)"; else pass "$1: $3"; fi
}
served() {	# label description pattern: the IMAP server was sent it
    if grep -q -- "$3" "$D/$1.log"; then pass "${1%-*}: $2"; else fail "${1%-*}: $2: the server saw: $(cat "$D/$1.log")"; fi
}
wired() {	# label description pattern: the SMTP server was sent it
    if grep -q -- "$3" "$D/$1.wire"; then pass "${1%-*}: $2"; else fail "${1%-*}: $2: the server was sent: $(cat "$D/$1.wire")"; fi
}

PARSE="exists biglit backslash spoof tagforge unsol envcrlf"
NET="stall close idleclose"
ALL="uid slot inject reply bigcompose authleak smtpproto $PARSE $NET unmount"
[[ -n "${ONLY:-}" ]] && ALL=$ONLY

start() {
    case " $PARSE " in *" $1 "*) s_parse $1; return;; esac
    case " $NET " in *" $1 "*) s_net $1; return;; esac
    s_$1
}
check() {
    [[ "$VERBOSE" -eq 1 ]] && sed 's/^/  /' "$D/$1.out"
    case " $PARSE " in *" $1 "*) c_parse $1; return;; esac
    case " $NET " in *" $1 "*) c_net $1; return;; esac
    grep -q '<<< end >>>' "$D/$1.out" || fail "$1: the script did not finish: $(tail -3 "$D/$1.out")"
    c_$1
}

# four emulators at a time
n=0
for sc in $ALL; do
    start $sc &
    n=$((n+1))
    if [[ $((n % 4)) -eq 0 ]]; then wait; fi
done
wait
for sc in $ALL; do
    check $sc
done

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
