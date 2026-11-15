#!/bin/sh
#
# fetch_tools_test.sh — the agent's fetch tools (webfetch, http, browse,
# payfetch) against a server that does not behave, and one that does.
#
# A fetch that timed out was not gone.  webfetch and payfetch answered
# "request timed out (30s)" and left the request running: its process
# in its read, its connection open, and a buffer as large as the
# response's header had said, allocated before any of the body came.
# Three webfetch calls of a response saying "Content-Length: 67108864"
# and no more pinned 201 MB of the heap every program of the emulator
# shares, and three processes, for as long as the server liked.  http
# and browse had no deadline at all: a server that accepted and said
# nothing held the agent's turn until the user cancelled it.
#
# The four tools are called at once on a server that never finishes
# (two of a promised 64 MB, two of nothing).  Each answers that it timed
# out, at its 30 seconds; the server sees each connection closed then;
# afterwards no process of theirs is left and the heap is where it was.
#
# Before that, quickly, what the tools say of a server that answers: the
# address a page came from leads webfetch's result (the redirect's
# target, not the address asked for), so a page that begins "error:" is
# not a failed call; a page longer than the 512KB read says so; http
# sends a body as it was written, takes PATCH, and gives a HEAD's
# status; browse refuses a private address in the same words as the
# others; payfetch does not go to the wallet for a 402 that came over
# plain http, and refuses an argument it does not know.
#
# The tools dial public addresses only, so the server is reached through
# a connection server of the test's own (tests/fakecs.b), which knows
# one name and nothing else.  Skipped without python3.  Takes 45 s.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "fetch_tools_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "fetch_tools_test: SKIP (no python3)"; exit 77; }
[ -f "$ROOT/tests/toolcall.dis" ] && [ -f "$ROOT/tests/fakecs.dis" ] || { echo "fetch_tools_test: SKIP (tests not built)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/fetch_tools.XXXXXX")
w="$ROOT/tmp/fetch_tools.$$"		# the emulator's /tmp/fetch_tools.$$
e="/tmp/fetch_tools.$$"
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$w" "$ROOT/tmp/fetch_tools.sh"' EXIT
mkdir -p "$w"
python3 "$ROOT/tests/host/fetch_tools/server.py" "$d/log" >"$d/port" &
srv=$!
i=0
while [ ! -s "$d/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
port=$(cat "$d/port")
[ -n "$port" ] || { echo "FAIL: the server did not start"; exit 1; }
u="http://fetch.test:$port"
t=/dis/veltro/tools

cat >"$ROOT/tmp/fetch_tools.sh" <<SH
load std
bind -a '#I' /net
/tests/fakecs.dis 'fetch.test=192.88.99.1' '192.88.99.1=127.0.0.1'
echo R_WEBFETCH
/tests/toolcall.dis -m 600 $t/webfetch.dis '$u/page' '$u/redir' '$u/errtext' '$u/big' 'http://127.0.0.1:$port/page'
echo R_END
echo R_HTTP
/tests/toolcall.dis $t/http.dis 'HEAD $u/missing' 'POST $u/echo a  b	c' 'PATCH $u/echo x'
echo R_END
echo R_BROWSE
/tests/toolcall.dis $t/browse.dis 'http://127.0.0.1:$port/page' '$u/redir'
echo R_END
echo R_PAYFETCH
/tests/toolcall.dis $t/payfetch.dis '$u/pay -a acct1' '$u/page -a' '$u/page -a acct1 --bogus' '$u/page -a acct1'
echo R_END
sleep 1
echo R_MEMBEFORE; cat /dev/memory; echo R_END
{/tests/toolcall.dis $t/webfetch.dis '$u/clstall' > $e/webfetch} &
{/tests/toolcall.dis $t/browse.dis '$u/clstall' > $e/browse} &
{/tests/toolcall.dis $t/http.dis 'GET $u/hang' > $e/http} &
{/tests/toolcall.dis $t/payfetch.dis '$u/hang -a acct1' > $e/payfetch} &
sleep 37
for i in webfetch browse http payfetch { echo R_SLOW_\$i; cat $e/\$i; echo R_END }
echo R_PS; ps; echo R_END
echo R_MEMAFTER; cat /dev/memory; echo R_END
echo R_DONE
SH
out=$(with_timeout 100 "$EMU" -c1 -pheap=512m -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/fetch_tools.sh; echo halt > '#c/sysctl'" </dev/null 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
section() { echo "$out" | sed -n "/^R_$1\$/,/^R_END\$/p" | sed '1d;$d'; }
# call N of a section: its result
call() { section "$1" | sed -n "/^R_CALL $2 /,/^R_RET $2\$/p" | sed '1d;$d'; }
want() {	# section, call, what it is, a pattern its result must match
	r=$(call "$1" "$2")
	if echo "$r" | grep -q -e "$4"; then pass "$3"; else fail "$3: $(echo "$r" | head -3)"; fi
}

echo "$out" | grep -q '^R_DONE' || { echo "FAIL: the session did not finish"; echo "$out" | tail -30 | sed 's/^/    /'; exit 1; }

want WEBFETCH 1 "webfetch leads with the address the page came from" "^\[$u/page\]\$"
if call WEBFETCH 1 | grep -q "the page's words"; then pass "and gives the page's text"; else fail "webfetch /page: $(call WEBFETCH 1)"; fi
want WEBFETCH 2 "after a redirect, the address is where it led" "^\[$u/page\]\$"
r=$(call WEBFETCH 3)
if echo "$r" | head -1 | grep -q '^error:'; then
	fail "a page beginning \"error:\" reads as a failed call: $(echo "$r" | head -1)"
elif echo "$r" | grep -q "^error: these are the page's words"; then
	pass "a page beginning \"error:\" is not a failed call"
else
	fail "webfetch /errtext: $r"
fi
r=$(call WEBFETCH 4)
n=$(echo "$r" | sed -n 's/^\.\.\.\[\([0-9]*\) characters\]\.\.\.$/\1/p')
if [ -n "$n" ] && [ "$n" -le 524600 ] && echo "$r" | grep -q 'only its first 512KB were read'; then
	pass "a 600KB page is cut at 512KB and says so ($n characters)"
else
	fail "webfetch /big: ${n:-?} characters: $(echo "$r" | tail -2)"
fi
blocked='^error: requests to internal/private network addresses are not allowed$'
want WEBFETCH 5 "webfetch refuses the loopback" "$blocked"
want BROWSE 1 "browse refuses it in the same words" "$blocked"
if grep -q 'REQ GET /page host=fetch.test ua=Veltro/1.0 (Infernode)' "$d/log"; then
	pass "browse fetches a public page (and has no Xenith to show it in: $(call BROWSE 2 | cut -c1-40))"
else
	fail "browse /redir: $(call BROWSE 2)"
fi
want HTTP 1 "http HEAD gives the status" '^error: HTTP/1.1 404'
want HTTP 2 "http sends the body as written" '^POST \[a  b	c\]$'
want HTTP 3 "http takes PATCH" '^PATCH \[x\]$'
want PAYFETCH 1 "payfetch does not pay for a 402 over plain http" 'over plain http'
if call PAYFETCH 1 | grep -q wallet; then fail "it went to the wallet: $(call PAYFETCH 1)"; fi
want PAYFETCH 2 "payfetch: -a with no account is an error" '^error: -a needs a value'
want PAYFETCH 3 "payfetch: an unknown argument is an error" "^error: unknown argument '--bogus'"
want PAYFETCH 4 "payfetch fetches a page that asks for nothing" "the page's words"

# the four that never finish
for tool in webfetch browse http payfetch; do
	s=$(section "SLOW_$tool")
	ms=$(echo "$s" | sed -n 's/^R_CALL 1 \([0-9]*\) .*/\1/p')
	if [ -z "$ms" ]; then
		fail "$tool had not returned 37 s after it was called"
	elif ! echo "$s" | grep -q 'timed out (30s)'; then
		fail "$tool: $(echo "$s" | sed -n 2p)"
	elif [ "$ms" -lt 29000 ] || [ "$ms" -gt 36000 ]; then
		fail "$tool answered after $ms ms"
	else
		pass "$tool: timed out, after $ms ms"
	fi
done
closed=$(grep -c '^CLOSED' "$d/log")
late=$(awk '/^CLOSED/ && ($3 < 29000 || $3 > 36500) { n++ } END { print n+0 }' "$d/log")
if [ "$closed" = 4 ] && [ "$late" = 0 ]; then
	pass "the server saw all four connections closed at the deadline"
else
	fail "connections closed: $closed of 4, $late not at the deadline: $(grep '^CLOSED' "$d/log" | tr '\n' ' ')"
fi
left=$(section PS | grep -c -i 'webclient\|toolcall\|Tool')
if [ "$left" = 0 ]; then
	pass "no process of theirs is left"
else
	fail "$left processes left: $(section PS | grep -i 'webclient\|toolcall\|Tool' | tr -s ' ' | tr '\n' ';')"
fi
heap() { section "$1" | awk '$8 == "heap" { print $1 }'; }
hb=$(heap MEMBEFORE); ha=$(heap MEMAFTER)
if [ -n "$hb" ] && [ -n "$ha" ] && [ $((ha - hb)) -lt 2097152 ]; then
	pass "the heap is where it was ($hb, then $ha bytes)"
else
	fail "the heap: $hb bytes before, $ha after"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -40 | sed 's/^/    /'
exit 1
