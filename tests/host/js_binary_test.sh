#!/bin/sh
#
# js_binary_test.sh — a page's scripts get a response's bytes as they
# came, and send theirs as they are.  A body was kept as text only, so
# bytes that are not UTF-8 (an image, a compressed or encrypted payload)
# read through arrayBuffer(), bytes(), blob() or an XHR's arraybuffer
# came back with U+FFFD's encoding in their place, and an ArrayBuffer
# sent was sent as its bytes decoded as UTF-8 and encoded again.  A
# sign-in check that fetches a binary payload and decodes it itself
# failed that way.  A loopback server gives every byte value and echoes
# what is posted, in hex; the page's script puts what it found in the
# title.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "js_binary_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "js_binary_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/js_binary.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/js_binary.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
PAGE = """<!doctype html><title>start</title>
<script>
function same(b, n) {
	if (b.length !== n) return 'length ' + b.length;
	for (var k = 0; k < n; k++) if (b[k] !== (k & 255)) return 'byte ' + k + ' is ' + b[k];
	return 'ok';
}
var r = [];
fetch('/bin').then(function(x) { return x.arrayBuffer(); }).then(function(b) {
	r.push('fetch ' + same(new Uint8Array(b), 512));
	return fetch('/bin').then(function(x) { return x.blob(); }).then(function(b) { return b.arrayBuffer(); });
}).then(function(b) {
	r.push('blob ' + same(new Uint8Array(b), 512));
	return new Promise(function(done) {
		var x = new XMLHttpRequest();
		x.open('GET', '/bin');
		x.responseType = 'arraybuffer';
		x.onload = function() { done(x.response); };
		x.send();
	});
}).then(function(b) {
	r.push('xhr ' + same(new Uint8Array(b), 512));
	var u = new Uint8Array(256);
	for (var k = 0; k < 256; k++) u[k] = k;
	return fetch('/echo', {method: 'POST', body: u}).then(function(x) { return x.text(); });
}).then(function(t) {
	var w = '';
	for (var k = 0; k < 256; k++) w += (k < 16 ? '0' : '') + k.toString(16);
	r.push('post ' + (t === w ? 'ok' : t.slice(0, 40)));
	return fetch('/text').then(function(x) { return x.text(); });
}).then(function(t) {
	r.push('text ' + (t === 'caf\\u00e9 \\u2713' ? 'ok' : t));
	return fetch('/text').then(function(x) { return x.arrayBuffer(); });
}).then(function(b) {
	r.push('textbytes ' + Array.prototype.join.call(new Uint8Array(b), ','));
	document.title = 'R ' + r.join('; ');
}).catch(function(e) { document.title = 'R ' + r.join('; ') + '; error ' + e; });
</script>""".encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def reply(self, b, t="text/html"):
        self.send_response(200)
        self.send_header("Content-Type", t)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/bin":
            self.reply(bytes(k & 255 for k in range(512)), "application/octet-stream")
        elif self.path == "/text":
            self.reply("café ✓".encode(), "text/plain; charset=utf-8")
        else:
            self.reply(PAGE)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.reply(self.rfile.read(n).hex().encode(), "text/plain")
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
cat >"$ROOT/tmp/js_binary.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/jsbin
mount -A '#scharon/fs' /n/jsbin
echo scripts on > /n/jsbin/ctl
echo open http://127.0.0.1:$port/ > /n/jsbin/ctl
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 { if {! grep -s '^R ' /n/jsbin/title} { sleep 1 } }
echo R_TITLE \`{cat /n/jsbin/title}
echo R_CONSOLE
cat /n/jsbin/console
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/js_binary.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
got=$(echo "$out" | sed -n 's/^R_TITLE R //p')
check() {	# name, what it should say, what it is
	v=$(echo "$got" | tr ';' '\n' | sed -n "s/^ *$1 //p")
	if [ "$v" = "$2" ]; then pass "$3"; else fail "$3: '$v'"; fi
}
[ -n "$got" ] || fail "the page's script did not finish: $(echo "$out" | sed -n 's/^R_TITLE //p')"
check fetch ok "fetch() arrayBuffer() has every byte value"
check blob ok "a response's blob() has every byte value"
check xhr ok "an XHR's arraybuffer response has every byte value"
check post ok "an ArrayBuffer view posted is sent as its bytes"
check text ok "a UTF-8 response's text() is its text"
check textbytes "99,97,102,195,169,32,226,156,147" "a UTF-8 response's arrayBuffer() is its bytes"
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
