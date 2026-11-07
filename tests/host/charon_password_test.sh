#!/bin/sh
#
# charon_password_test.sh — a password field's value is not in the page's
# files.  Charon's forms and dom/N/attrs files showed it as typed, so
# anything that could read a browser window's files (an agent given the
# window) could read a password entered there.  They now show that the
# field holds something, not what or how much; the page's own scripts
# still see the value, and the form still sends it.  A loopback page has
# a password field filled by its markup and one filled through ctl; its
# script puts what it sees in the title.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_password_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_password_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_password.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_password.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
PAGE = b"""<!doctype html><title>start</title>
<form method=post action=/got>
<input name=user id=u value=k1>
<input type=password name=old id=o value="markup secret">
<input type=password name=pw id=p>
<input type=submit id=go value=Go>
</form>
<script>
function upd(){document.title='saw '+document.getElementById('p').value+'/'+document.getElementById('o').value}
document.getElementById('p').addEventListener('input',upd);
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
cat >"$ROOT/tmp/charon_password.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h http://127.0.0.1:$port/ &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonpw
mount -A '#scharon/fs' /n/charonpw
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s done /n/charonpw/status} { sleep 1 } }
echo scripts on > /n/charonpw/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s done /n/charonpw/status} { sleep 1 } }
sleep 1
f=\`{grep ' pw ' /n/charonpw/forms}
p=\${index 2 \$f}
f=\`{grep ' old ' /n/charonpw/forms}
o=\${index 2 \$f}
echo set \$p 'typed secret' > /n/charonpw/ctl
sleep 1
echo R_TITLE \`{cat /n/charonpw/title}
echo R_FORMS
cat /n/charonpw/forms
echo R_ATTRS
cat /n/charonpw/dom/\$p/attrs /n/charonpw/dom/\$o/attrs
echo R_TEXT
cat /n/charonpw/text
echo R_SUBMIT
echo submit 1 > /n/charonpw/ctl
for i in 1 2 3 4 5 { if {! grep -s POST /n/charonpw/title} { sleep 1 } }
echo R_POSTED \`{cat /n/charonpw/title}
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_password.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
section() { echo "$out" | sed -n "/^R_$1/,/^R_/p" | sed '$d'; }

files=$(section FORMS; section ATTRS; section TEXT)
if echo "$files" | grep -q 'secret'; then
	fail "a password is in the page's files: $(echo "$files" | grep secret)"
else
	pass "no password in forms, attrs or text"
fi
if section FORMS | grep -q '^1 [0-9]* password pw \*\*\*\*\*\*\*\*$' &&
   section FORMS | grep -q '^1 [0-9]* password old \*\*\*\*\*\*\*\*$'; then
	pass "forms says each password field holds something"
else
	fail "forms: $(section FORMS | grep password)"
fi
if [ "$(section ATTRS | grep -c '^value \*\*\*\*\*\*\*\*$')" = 2 ]; then
	pass "attrs masks a password field's value"
else
	fail "attrs: $(section ATTRS)"
fi
if section FORMS | grep -q '^1 [0-9]* text user k1$'; then
	pass "a text field's value is shown"
else
	fail "forms, the text field: $(section FORMS | grep user)"
fi
got=$(echo "$out" | sed -n 's/^R_TITLE //p')
if [ "$got" = "saw typed secret/markup secret" ]; then
	pass "the page's script sees both values"
else
	fail "title '$got', want 'saw typed secret/markup secret'"
fi
got=$(echo "$out" | sed -n 's/^R_POSTED //p')
if [ "$got" = "POST user=k1&old=markup+secret&pw=typed+secret" ]; then
	pass "the form sends both values"
else
	fail "posted '$got'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
