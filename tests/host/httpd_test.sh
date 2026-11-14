#!/bin/bash
#
# tests/host/httpd_test.sh
#
# svc/httpd/httpd (httpd(8)) from outside: tests/host/httpd/attack.py
# against four servers in one emu, on a site made here:
#
#   plain    -L -p /post/ctl -w /wiki, wikifs(4) mounted at wiki/ over a
#            copy of services/wiki, /dev/sysname bound at sysname
#   tls      the site over TLS 1.3 with a P-256 certificate made here, -S
#   redirect -r to the TLS port
#   flood    -n 6 -s 3
#
# What it checks: files, HEAD, types, index.html, a directory's 301,
# a compressed copy (name.gz) sent to a client taking gzip, -C's
# Cache-Control, Server-Sent Events from file2chan files (each read an
# event, a comment after 15 s of silence, a client gone mid-stream
# leaving no process), the TLS suite fastest here chosen over the
# client's first, the Date following the clock stepped an hour,
# listings with names escaped, dotfiles not found; ranges and
# conditional requests; a file of no known length chunked; keep-alive,
# pipelining, the 100-request limit, 40 plain and 15 TLS clients at
# once; methods; POST to a -p path, refused elsewhere, from another
# origin, without or past a length, Expect; wikifs's edit form, the
# form's base not followed; -r and its Host checks.  Then it attacks:
# 22 traversals and encodings refused, 13 paths outside the site (the
# emulator's /dis, /dev, #-names, host symlinks out of the site) not
# found; 35 malformed requests (request smuggling, folding, bare CR and
# LF, NUL, oversized lines and headers, versions) refused with the
# right status, and nothing answered after a smuggling attempt;
# slowloris, a silent connection, an unfinished TLS handshake and a
# body never sent all hung up by their deadlines; connections past -s
# closed and 300 dropped half-way; TLS 1.2, plain HTTP, h2 alone, a
# megabyte ClientHello and 200 garbage connections; 1500 mutated
# requests.  The servers must answer at the end, and emu must not
# have faulted.
#
# Run from project root: ./tests/host/httpd_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

# HTTPD_EMU (tools/sanemu's emu, say) and HTTPD_EMUFLAGS (-c0) to run it otherwise
EMU="${HTTPD_EMU:-$EMU}"
EMUFLAGS="${HTTPD_EMUFLAGS:--c1}"
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/httpd/httpd.dis dis/lib/crypt/tls.dis dis/wikifs.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v openssl >/dev/null 2>&1 || { echo "SKIP: no openssl"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

NAME="httpd_test.$$"
W="$ROOT/tmp/$NAME"		# emu sees it as /tmp/$NAME
mkdir -p "$W" || exit 1
emupid=
cleanup() {
	[ -n "$emupid" ] && { kill -9 "$emupid" 2>/dev/null; wait "$emupid" 2>/dev/null; }
	rm -rf "$W"
}
trap cleanup EXIT INT TERM

S="$W/site"
mkdir -p "$S/sub" "$S/sub/.hidden" "$S/post" "$S/wiki" "$S/.hidden"
printf 'hello, world\n' > "$S/hello.txt"
printf '<!DOCTYPE html><title>site</title><h1>the site</h1>\n' > "$S/index.html"
head -c 5000000 /dev/urandom > "$S/big.bin"
printf 'a\n' > "$S/sub/a.txt"
printf 'x\n' > "$S/sub/<script>.txt"
printf 'secret\n' > "$S/.hidden/x"
printf 'blank\n' > "$S/sp ace.txt"
printf 'euro\n' > "$S/€.txt"
: > "$S/post/ctl"
: > "$S/sysname"
: > "$S/block"
mkdir -p "$S/events"
: > "$S/events/fast"
: > "$S/events/slow"
printf 'body { color: #123; }\n%.0s' $(seq 1 200) > "$S/style.css"
gzip -9 -n -c "$S/style.css" > "$S/style.css.gz"
ln -s /etc/hostname "$S/link.txt"
ln -s /etc "$S/etcdir"
ln -s /etc "$S/sub/escape"
cp -r "$ROOT/services/wiki" "$W/store"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" \
	-days 2 -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null ||
	{ echo "FAIL: could not make a certificate"; exit 1; }

BASE=$((20000 + $$ % 20000))
P1=$BASE; P2=$((BASE+1)); P3=$((BASE+2)); P4=$((BASE+3))
T=/tmp/$NAME
cat > "$W/run.sh" <<INFERNO
load std
load file2chan
mount {wikifs -d $T/store} $T/site/wiki
bind /dev/sysname $T/site/sysname
file2chan /chan/httpdblock {} {}
bind /chan/httpdblock $T/site/block
file2chan /chan/httpdfast {sleep 1; rread 'line one
line two'} {}
bind /chan/httpdfast $T/site/events/fast
file2chan /chan/httpdslow {sleep 17; rread ping} {}
bind /chan/httpdslow $T/site/events/slow
svc/httpd/httpd -v -L -p /post/ctl -w /wiki -l $T/access.log -a tcp!127.0.0.1!$P1 $T/site &
svc/httpd/httpd -v -c $T/cert.pem -k $T/key.pem -S 600 -C 600 -a tcp!127.0.0.1!$P2 $T/site &
svc/httpd/httpd -r $P2 -a tcp!127.0.0.1!$P3 $T/site &
svc/httpd/httpd -v -n 6 -s 3 -a tcp!127.0.0.1!$P4 $T/site &
sleep 3
ls /prog > $T/procs0
while {! ftest -e $T/step} {sleep 1}
cat $T/step > /dev/time
echo stepped > $T/stepped
while {! ftest -e $T/count} {sleep 1}
ls /prog > $T/procs1
INFERNO
"$EMU" $EMUFLAGS -r"$ROOT" sh "$T/run.sh" </dev/null >"$W/emu.log" 2>&1 &
emupid=$!

up() { python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $1), timeout=1)" 2>/dev/null; }
for _ in $(seq 1 100); do
	up $P1 && up $P2 && up $P3 && up $P4 && break
	sleep 0.1
done
up $P1 && up $P2 && up $P3 && up $P4 || { echo "FAIL: the servers did not start"; cat "$W/emu.log"; exit 1; }

# the kernel's side of the confinement, on this site (its host symlinks)
with_timeout 120 "$EMU" $EMUFLAGS -r"$ROOT" /tests/httpd_confine_test.dis $T/site </dev/null >"$W/confine.log" 2>&1
if grep -q '^1 passed' "$W/confine.log"; then
	echo "PASS: confinement (tests/httpd_confine_test.b)"
	cfails=0
else
	echo "FAIL: confinement (tests/httpd_confine_test.b)"; grep -v 'bad path' "$W/confine.log" | tail -8; cfails=1
fi

with_timeout 900 python3 -I "$ROOT/tests/host/httpd/attack.py" $P1 $P2 $P3 $P4 "$W/cert.pem" "$S" "$W/emu.log"
fails=$(( $? + cfails ))

# no process left over from all that: the Progs now no more than at start
sleep 3
touch "$W/count"
for _ in $(seq 1 50); do [ -s "$W/procs1" ] && break; sleep 0.2; done
n0=$(wc -l < "$W/procs0"); n1=$(wc -l < "$W/procs1" 2>/dev/null || echo 9999)
if [ "$n1" -le "$n0" ]; then
	echo "PASS: no process left over ($n0 Progs at start, $n1 at the end)"
else
	echo "FAIL: processes left over: $n0 Progs at start, $n1 at the end"; fails=$((fails+1))
fi

# the access log is Common Log Format
if grep -qE '^127\.0\.0\.1 - - \[[0-9]{2}/[A-Z][a-z]{2}/[0-9]{4}:[0-9:]{8} \+0000\] "GET /hello.txt HTTP/1\.1" 200 13 ' "$W/access.log"; then
	echo "PASS: the access log is in Common Log Format"
else
	echo "FAIL: the access log is not in Common Log Format"; head -3 "$W/access.log"; fails=$((fails+1))
fi
if ! kill -0 "$emupid" 2>/dev/null; then
	echo "FAIL: emu exited"; fails=$((fails+1))
fi
if grep -qiE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log"; then
	echo "FAIL: emu reported a fault"; grep -iE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log" | head -5; fails=$((fails+1))
fi
[ "$fails" -eq 0 ] || { echo "--- emu (last 30 lines)"; tail -30 "$W/emu.log"; }
echo "httpd_test: $fails failed"
[ "$fails" -eq 0 ]
