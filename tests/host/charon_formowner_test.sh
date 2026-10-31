#!/bin/sh
#
# charon_formowner_test.sh — a form's controls are the ones HTML puts in
# it (§4.10.17.3), and are sent in the document's order (§4.10.21.4),
# both through Charon's files (forms, ctl submit) and from the page's
# scripts (form.elements, form.submit()).  A control in a template's
# content is not in the document; one with a form attribute is in the
# form with that id, wherever it is, or in none; a control a script put
# before another in the form is sent before it, though made after it.
# Each was wrong: the template's input was listed and sent, the form
# attribute ignored, and entries sent in the order nodes were made.
# Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_formowner_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_formowner_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_formowner.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_formowner.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
PAGE = b"""<!doctype html><title>start</title>
<form id=f method=post action=/got>
<input name=b value=2>
<template><input name=t value=x></template>
<input name=z value=9 form=nosuch>
</form>
<input name=c value=3 form=f>
<script>
var f = document.getElementById('f');
var a = document.createElement('input');
a.setAttribute('name', 'a');
a.setAttribute('value', '1');
f.insertBefore(a, f.firstChild);
var z = document.querySelector('[name=z]');
document.title = 'E ' + Array.prototype.map.call(f.elements, function(e) { return e.name; }).join(',') +
	' ' + (document.querySelector('[name=c]').form === f) + ' ' + (z.form === null);
if (location.pathname == '/js')
	setTimeout(function() { f.submit(); }, 1500);
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
        self.reply(b"<!doctype html><title>POST " + self.rfile.read(n) + b"</title>")
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
cat >"$ROOT/tmp/charon_formowner.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonfo
mount -A '#scharon/fs' /n/charonfo
echo scripts on > /n/charonfo/ctl
echo open http://127.0.0.1:$port/ > /n/charonfo/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s '^E ' /n/charonfo/title} { sleep 1 } }
echo R_TITLE \`{cat /n/charonfo/title}
echo R_FORMS
cat /n/charonfo/forms
echo R_SUBMIT
echo submit 1 > /n/charonfo/ctl
for i in 1 2 3 4 5 { if {! grep -s POST /n/charonfo/title} { sleep 1 } }
echo R_POSTED \`{cat /n/charonfo/title}
echo open http://127.0.0.1:$port/js > /n/charonfo/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s POST /n/charonfo/title} { sleep 1 } }
echo R_JSPOSTED \`{cat /n/charonfo/title}
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_formowner.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
forms=$(echo "$out" | sed -n '/^R_FORMS/,/^R_SUBMIT/p' | sed '1d;$d')

got=$(echo "$out" | sed -n 's/^R_TITLE //p')
if [ "$got" = "E a,b,c true true" ]; then
	pass "form.elements and .form follow the form attribute and leave out the template"
else
	fail "title '$got', want 'E a,b,c true true'"
fi
if echo "$forms" | grep -q ' t x$'; then
	fail "a control in a template is listed: $(echo "$forms" | grep ' t x$')"
else
	pass "a control in a template is not listed"
fi
if echo "$forms" | grep -q '^1 [0-9]* text c 3$'; then
	pass "a control outside the form with form=its id is in it"
else
	fail "c: $(echo "$forms" | grep ' c ')"
fi
if echo "$forms" | grep -q '^0 [0-9]* text z 9$'; then
	pass "a control in the form naming another form is in none"
else
	fail "z: $(echo "$forms" | grep ' z ')"
fi
if [ "$(echo "$forms" | sed -n 's/^1 [0-9]* text \([abc]\) .*/\1/p' | tr -d '\n')" = abc ]; then
	pass "forms lists the controls in the document's order"
else
	fail "order: $forms"
fi
got=$(echo "$out" | sed -n 's/^R_POSTED //p')
if [ "$got" = "POST a=1&b=2&c=3" ]; then
	pass "submit through ctl sends the form's controls in order"
else
	fail "posted '$got', want 'POST a=1&b=2&c=3'"
fi
got=$(echo "$out" | sed -n 's/^R_JSPOSTED //p')
if [ "$got" = "POST a=1&b=2&c=3" ]; then
	pass "form.submit() sends the form's controls in order"
else
	fail "form.submit() posted '$got', want 'POST a=1&b=2&c=3'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
