#!/bin/sh
#
# charon_bigpost_test.sh — a form posted with a body larger than one 9P
# message is sent whole.  webfs(4) kept only the last write to postbody,
# and a body that size is written in several, so a page's long post (a
# SAML response from an institutional sign-in, to OpenAthens) arrived as
# its last few kilobytes and the server refused it.  A loopback server
# answers a POST with a page whose title is the body's length and its
# ends; a page's script posts a form of 20000 bytes, then a short one.
# Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_bigpost_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_bigpost_test: SKIP (no python3)"; exit 77; }
[ -f dis/tests/js/jspage.dis ] || { echo "charon_bigpost_test: SKIP (tests not built)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/bigpost.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_bigpost_test.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server
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
    def page(self, v):
        return self.reply("""<!doctype html><title>start</title>
<form id=f method=post action=/got><input type=hidden name=v value="%s"></form>
<script>document.getElementById('f').submit();</script>""" % v)
    def do_GET(self):
        if self.path == "/big":
            return self.page("S" + "0123456789" * 2000 + "E")
        if self.path == "/small":
            return self.page("short")
        self.send_error(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        self.reply("<!doctype html><title>POST %d %s %s</title>" % (len(body), body[:3], body[-3:]))
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
cat >"$ROOT/tmp/charon_bigpost_test.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
webfs
echo R_BIG
/dis/tests/js/jspage.dis -k -w 1500 $u/big
echo R_SMALL
/dis/tests/js/jspage.dis -k -w 1500 $u/small
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_bigpost_test.sh; echo halt > '#c/sysctl'" 2>&1)

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
check BIG 'POST 20004 v=S 89E' "a 20000-byte field is posted whole"
check SMALL 'POST 7 v=s ort' "a short post after it is not mixed with the long one"
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -20 | sed 's/^/    /'
exit 1
