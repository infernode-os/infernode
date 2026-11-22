#!/bin/sh
#
# charon_netfile_test.sh — a page from the network does not take the
# browser to a file.  Charon reads file: addresses from its own name
# space, as the user who runs it, and went wherever the page shown said:
# a link to file:///usr/someone/notes followed (by the user's click, or
# by an agent's "follow 1" through the charon tool, which refuses to
# navigate to such an address itself) made the file the next page, and
# "read body" gave it to the agent.  A form's action, a refresh, a
# script's location and a frame went the same way; and a page saying
# <base href="file:///dir/"> became a file: page altogether: its address
# shown as that, its scripts given the directory.
#
# A loopback page with each of those, and a file that is not the page's:
# every way is refused, the address stays the page's, and the file's
# text is in nothing the session shows.  What the user asks for by name
# still opens, and a file's own link to a file is still followed.
#
# The charon tool's own waiting is checked on the way: each navigation
# through it left two processes behind for good (a reader of the
# session's events and a timer), so six of them are made and the
# emulator's processes counted.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_netfile_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_netfile_test: SKIP (no python3)"; exit 77; }
[ -f "$ROOT/dis/tests/toolcall.dis" ] || [ -f "$ROOT/tests/toolcall.dis" ] || { echo "charon_netfile_test: SKIP (tests not built)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_netfile.XXXXXX")
w="$ROOT/tmp/charon_netfile.$$"		# what the emulator sees as /tmp/charon_netfile.$$
e="/tmp/charon_netfile.$$"
# (with scripts on, Charon keeps a store for each origin under the user's lib)
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$w" "$ROOT/tmp/charon_netfile.sh" "$ROOT/usr/$(id -un)/lib/charon/store/http_127.0.0.1_$port"' EXIT
mkdir -p "$w"
echo "NOT-THE-PAGES-c0ffee" >"$w/secret.txt"
cat >"$w/local.html" <<HTML
<!doctype html><title>a local page</title><a href="file://$e/secret.txt">the file beside it</a>
HTML

cat >"$d/serve.py" <<'PY'
import http.server, sys
S = sys.argv[1]		# the file's address
D = sys.argv[2]		# its directory's
PAGES = {
 "/link": "<!doctype html><title>link</title><a href=\"%s\">here</a>"
	"<form action=\"%s\"><input name=q value=1><input type=submit value=Go></form>" % (S, S),
 "/frame": "<!doctype html><title>frame</title><p>framed:</p><iframe src=\"%s\" width=300 height=100></iframe>" % S,
 "/refresh": "<!doctype html><title>refresh</title><meta http-equiv=refresh content=\"0; url=%s\"><p>wait</p>" % S,
 "/script": "<!doctype html><title>script</title><p>scripted</p><script>location.href = \"%s\";</script>" % S,
 "/base": "<!doctype html><title>base</title><base href=\"%s/\"><a href=\"secret.txt\">relative</a>"
	"<script>try { var x = new XMLHttpRequest(); x.open('GET', 'secret.txt', false); x.send();"
	" document.title = 'xhr ' + x.status + ' ' + x.responseText; } catch(e) { document.title = 'xhr failed'; }</script>" % D,
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def do_GET(self):
        if self.path == "/redir":
            self.send_response(302)
            self.send_header("Location", S)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        b = PAGES.get(self.path.split("?")[0], "<!doctype html><title>none</title>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$d/serve.py" "file://$e/secret.txt" "file://$e" >"$d/port" &
srv=$!
i=0
while [ ! -s "$d/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
port=$(cat "$d/port")
[ -n "$port" ] || { echo "FAIL: the server did not start"; exit 1; }
u="http://127.0.0.1:$port"

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/charon_netfile.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mount -A '#scharon/fs' /mnt/charon
c=/mnt/charon
fn settle { sleep 1; for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s '^done|^error' \$c/status} { sleep 1 } } }
fn show { echo R_\$1; echo url \`{cat \$c/url}; echo title \`{cat \$c/title}; cat \$c/text; echo; echo R_END }
fn try { if {echo \$* > \$c/ctl >[2] /tmp/charon_netfile.$$/err} { echo ctl took it } { echo ctl refused: \`{cat /tmp/charon_netfile.$$/err} } }

echo open $u/link > \$c/ctl; settle
echo R_TOOL
/tests/toolcall.dis /dis/veltro/tools/charon.dis 'read links' 'follow 1' 'read body' 'read url'
echo R_END
settle
echo R_NAV
/tests/toolcall.dis /dis/veltro/tools/charon.dis 'navigate $u/link' 'reload' 'reload' 'reload' 'navigate $u/none' 'back' 'status'
echo R_END
settle
echo R_FOLLOW; try follow 1; echo R_END; settle; show AFTERFOLLOW
echo R_SUBMIT; try submit 1; echo R_END; settle; show AFTERSUBMIT

echo open $u/frame > \$c/ctl; settle
echo R_FRAMEERRS; cat \$c/errors; echo R_END
show FRAME

echo open $u/refresh > \$c/ctl; settle; sleep 2; settle; show REFRESH
echo open $u/redir > \$c/ctl; settle; show REDIR

echo scripts on > \$c/ctl; settle
echo open $u/script > \$c/ctl; settle; sleep 2; settle; show SCRIPT
echo open $u/base > \$c/ctl; settle; sleep 1; show BASE
echo R_BASEFOLLOW; try follow 1; echo R_END; settle; show AFTERBASE
echo scripts off > \$c/ctl; settle

echo open file://$e/secret.txt > \$c/ctl; settle; show USEROPEN
echo open file://$e/local.html > \$c/ctl; settle
echo R_LOCALFOLLOW; try follow 1; echo R_END; settle; show LOCAL
echo R_DONE
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_netfile.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
section() { echo "$out" | sed -n "/^R_$1\$/,/^R_END/p" | sed '1d;$d'; }
# $1 a section, $2 what it is: the page's address is still the server's and the file is not in it
kept() {
	s=$(section "$1")
	if echo "$s" | grep -q 'c0ffee'; then
		fail "$2: the file's text is shown: $(echo "$s" | grep c0ffee | head -1)"
	elif ! echo "$s" | grep -q "^url $u/"; then
		fail "$2: the address is $(echo "$s" | grep '^url ')"
	else
		pass "$2: the page stays, the file is not shown"
	fi
}

echo "$out" | grep -q '^R_DONE' || { echo "FAIL: the session did not finish"; echo "$out" | tail -30 | sed 's/^/    /'; exit 1; }

s=$(section TOOL)
if echo "$s" | grep -q "^1 file://$e/secret.txt here"; then
	pass "the page's link is to the file"
else
	fail "links: $s"
fi
if echo "$s" | grep -q 'c0ffee'; then
	fail "the charon tool was given the file: $(echo "$s" | grep c0ffee | head -1)"
elif echo "$s" | grep -q '^error: .*may not open a file: address'; then
	pass "the charon tool's follow is refused, saying why"
else
	fail "the charon tool's follow: $s"
fi
s=$(section NAV)
first=$(echo "$s" | sed -n 's/^R_CALL 1 [0-9]* \([0-9]*\)$/\1/p')
last=$(echo "$s" | sed -n 's/^R_CALL 7 [0-9]* \([0-9]*\)$/\1/p')
if [ "$(echo "$s" | grep -c '^Status: done')" != 7 ]; then
	fail "the charon tool's navigations: $s"
elif [ -n "$first" ] && [ -n "$last" ] && [ $((last - first)) -le 2 ]; then
	pass "six navigations through the charon tool leave no processes ($first, then $last)"
else
	fail "the charon tool left processes: ${first:-?} after its first navigation, ${last:-?} after its seventh call"
fi
if section FOLLOW | grep -q 'ctl refused: .*may not open a file: address'; then
	pass "follow is refused"
else
	fail "follow: $(section FOLLOW)"
fi
kept AFTERFOLLOW "after follow"
if section SUBMIT | grep -q 'ctl refused: .*may not open a file: address'; then
	pass "a form whose action is the file is not sent"
else
	fail "submit: $(section SUBMIT)"
fi
kept AFTERSUBMIT "after submit"
if section FRAMEERRS | grep -q "secret.txt: .*may not open a file: address"; then
	pass "a frame of the file is not loaded"
else
	fail "the frame: errors '$(section FRAMEERRS)'"
fi
kept FRAME "the framing page"
kept REFRESH "a refresh to the file"
kept REDIR "a redirect to the file"
kept SCRIPT "a script's location"
kept BASE "a page with a file: base"
if section BASE | grep -q '^title xhr 200'; then
	fail "the page's script read the file: $(section BASE | grep '^title')"
else
	pass "a file: base gives the page's script no file ($(section BASE | grep '^title'))"
fi
if section BASEFOLLOW | grep -q 'ctl refused: .*may not open a file: address'; then
	pass "its relative link, a file's address, is refused"
else
	fail "follow under a file: base: $(section BASEFOLLOW)"
fi
kept AFTERBASE "after that follow"

if section USEROPEN | grep -q 'c0ffee'; then
	pass "a file the user opens by name is shown"
else
	fail "open file://: $(section USEROPEN)"
fi
if section LOCALFOLLOW | grep -q 'ctl took it' && section LOCAL | grep -q 'c0ffee'; then
	pass "a file's link to a file is followed"
else
	fail "a local page's link: $(section LOCALFOLLOW) / $(section LOCAL)"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -40 | sed 's/^/    /'
exit 1
