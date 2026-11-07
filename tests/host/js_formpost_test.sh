#!/bin/sh
#
# js_formpost_test.sh — a form a page's script submits by POST is posted
# (lib/js/dom.js submitform, through the host's navigate).  It was only
# logged as unsupported, so a sign-in whose script posts the password
# (Microsoft's) greyed its page and went nowhere, and an OAuth form_post
# page never returned to the site.  A loopback server answers a POST with
# a page whose title is the body it was sent; the page's scripts submit
# with form.submit(), and from a button's click.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "js_formpost_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "js_formpost_test: SKIP (no python3)"; exit 77; }
[ -f dis/tests/js/jspage.dis ] || { echo "js_formpost_test: SKIP (tests not built)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/formpost.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/js_formpost_test.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def reply(self, body):
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/submit":
            return self.reply("""<!doctype html><title>start</title>
<form id=f method=post action=/got><input name=login value="k1@example.ac.uk"><input name=passwd value="a b&c"></form>
<script>document.getElementById('f').submit();</script>""")
        if self.path == "/click":
            return self.reply("""<!doctype html><title>start</title>
<form method=post action=/got><input name=ctx value=x1><input type=submit id=go name=go value=Next></form>
<script>document.getElementById('go').click();</script>""")
        self.send_error(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        ctype = self.headers.get("Content-Type", "")
        self.reply("<!doctype html><title>POST %s %s</title>" % (ctype, body))
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
u="http://127.0.0.1:$port"

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/js_formpost_test.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
webfs
echo R_SUBMIT
/dis/tests/js/jspage.dis -k -w 1500 $u/submit
echo R_CLICK
/dis/tests/js/jspage.dis -k -w 1500 $u/click
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/js_formpost_test.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
check() {
	got=$(echo "$out" | sed -n "/^R_$1/,/^R_/p" | sed -n 's/^title: //p' | tail -1)
	if [ "$got" = "$2" ]; then
		echo "PASS: $3"
	else
		echo "FAIL: $3: title '$got', want '$2'"
		failed=1
	fi
}
check SUBMIT 'POST application/x-www-form-urlencoded login=k1%40example.ac.uk&passwd=a+b%26c' "form.submit() posts the form's entries"
check CLICK 'POST application/x-www-form-urlencoded ctx=x1&go=Next' "a submit button clicked by script posts, naming the button"
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -20 | sed 's/^/    /'
exit 1
