#!/bin/sh
#
# charon_forms_test.sh — the forms file lists the page's controls as the
# document holds them, after its scripts have changed it.  Form numbers
# came from the order nodes were made, so an input a script moved into a
# form it made afterwards was in no form (and was not sent with it), and
# a control a script removed, or made and never put in the document,
# was listed as if on the page (Microsoft's sign-in keeps three such
# copies of its email and password inputs; filling one did nothing).
# Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_forms_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_forms_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_forms.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_forms.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
PAGE = b"""<!doctype html><title>start</title>
<form method=post action=/one><input name=keep value=k><input name=gone value=g></form>
<div><input name=moved value=m></div>
<script>
var f = document.createElement('form');
f.setAttribute('method', 'post');
f.setAttribute('action', '/two');
document.body.appendChild(f);
f.appendChild(document.querySelector('[name=moved]'));
var x = document.createElement('input');
x.setAttribute('name', 'detached');
x.setAttribute('value', 'd');
var g = document.querySelector('[name=gone]');
g.parentNode.removeChild(g);
document.title = 'ready';
</script>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def reply(self, b):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        self.reply(PAGE)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.reply(b"<!doctype html><title>POST " + self.path.encode() + b" " + self.rfile.read(n) + b"</title>")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$d/serve.py" >"$d/port" &
srv=$!
i=0
while [ ! -s "$d/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
port=$(cat "$d/port")
[ -n "$port" ] || { echo "FAIL: the server did not start"; exit 1; }

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/charon_forms.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h http://127.0.0.1:$port/ &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonforms
mount -A '#scharon/fs' /n/charonforms
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s done /n/charonforms/status} { sleep 1 } }
echo scripts on > /n/charonforms/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s ready /n/charonforms/title} { sleep 1 } }
echo R_TITLE \`{cat /n/charonforms/title}
echo R_FORMS
cat /n/charonforms/forms
echo R_SUBMIT
echo submit 2 > /n/charonforms/ctl
for i in 1 2 3 4 5 { if {! grep -s POST /n/charonforms/title} { sleep 1 } }
echo R_POSTED \`{cat /n/charonforms/title}
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_forms.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
forms=$(echo "$out" | sed -n '/^R_FORMS/,/^R_SUBMIT/p' | sed '1d;$d')

got=$(echo "$out" | sed -n 's/^R_TITLE //p')
[ "$got" = ready ] && pass "the page's script ran" || fail "title '$got', want 'ready'"
if echo "$forms" | grep -q '^1 [0-9]* text keep k$'; then
	pass "a control the markup put in form 1 is in form 1"
else
	fail "keep: $forms"
fi
if echo "$forms" | grep -q '^2 [0-9]* text moved m$'; then
	pass "a control moved into a form made after it is in that form"
else
	fail "moved: $(echo "$forms" | grep moved)"
fi
if echo "$forms" | grep -q 'gone'; then
	fail "a removed control is listed: $(echo "$forms" | grep gone)"
else
	pass "a removed control is not listed"
fi
if echo "$forms" | grep -q 'detached'; then
	fail "a control never in the document is listed: $(echo "$forms" | grep detached)"
else
	pass "a control never in the document is not listed"
fi
got=$(echo "$out" | sed -n 's/^R_POSTED //p')
if [ "$got" = "POST /two moved=m" ]; then
	pass "form 2 sends the control moved into it"
else
	fail "posted '$got', want 'POST /two moved=m'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
