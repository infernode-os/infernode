#!/bin/sh
#
# originfs_test.sh — the origin filter in front of webfs that a page's
# realm sees as /mnt/web (appl/lib/web/originfs.b).  One loopback server
# answers on two ports, which are two origins.  tests/originfs_test.dis
# drives the filter's files directly (CORS, preflight, Opaque Response
# Blocking, forbidden headers, cookies); then a page on the first origin,
# loaded with its scripts on, fetches from the second.  Skipped without
# python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "originfs_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "originfs_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/originfs.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/originfs_test.sh"; rm -rf "$ROOT"/usr/*/lib/charon/store/http_127.0.0.1_*' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, os, sys, threading, urllib.parse
os.chdir(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def reply(self, code, ctype, body, extra=()):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)
    def cors(self, q):
        h = []
        if "acao" in q:
            h.append(("Access-Control-Allow-Origin", q["acao"][0]))
        if "cred" in q:
            h.append(("Access-Control-Allow-Credentials", "true"))
        return h
    def route(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if self.command == "OPTIONS":
            h = self.cors(q)
            if "pre" in q:
                h += [("Access-Control-Allow-Methods", "PUT"), ("Access-Control-Allow-Headers", "x-custom")]
            return self.reply(204, "text/plain", "", h)
        if u.path == "/echo":
            return self.reply(200, "text/plain", "".join("%s: %s\n" % kv for kv in self.headers.items()), self.cors(q))
        if u.path == "/setcookie":
            return self.reply(200, "text/plain", "set", [("Set-Cookie", "vis=1; Path=/"), ("Set-Cookie", "hid=2; Path=/; HttpOnly")])
        if u.path == "/script.js":
            return self.reply(200, "application/javascript", "window.ran = 'ran';")
        if u.path == "/data.json":
            return self.reply(200, "application/json", '{"secret": 1}')
        p = u.path.lstrip("/")
        if os.path.isfile(p):
            return self.reply(200, "text/html", open(p).read())
        self.reply(404, "text/plain", "no")
    do_GET = do_HEAD = do_POST = do_OPTIONS = route
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        self.route()
ports = []
for i in range(2):
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    ports.append(s.server_address[1])
    threading.Thread(target=s.serve_forever, daemon=True).start()
open("ports.tmp", "w").write("%d %d" % tuple(ports))
os.rename("ports.tmp", "ports")
threading.Event().wait()
PY
python3 "$d/serve.py" "$d" >"$d/log" 2>&1 &
srv=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/ports" ] && break; sleep 0.5; done
set -- $(cat "$d/ports")
a=http://127.0.0.1:$1/
b=http://127.0.0.1:$2/

cat >"$d/page.html" <<HTML
<html><head><title>origin</title>
<script src="${b}script.js"></script>
<script src="${b}data.json" onerror="console.log('R json-script-error')"></script>
</head><body><script>
console.log('R script ' + window.ran);
fetch('${b}echo').then(() => console.log('R cross-unoffered resolved'), () => console.log('R cross-unoffered rejected'));
fetch('${b}echo?acao=' + encodeURIComponent(location.origin)).then((r) => r.text()).then((t) => console.log('R cross-offered ' + /Origin: /.test(t)), (e) => console.log('R cross-offered failed ' + e));
fetch('${a}echo').then((r) => r.text()).then((t) => console.log('R same ' + !/Origin: /.test(t)));
try {
	const x = new XMLHttpRequest();
	x.open('GET', '${b}echo', false);
	x.send();
	console.log('R sync-xhr read ' + x.status);
} catch (e) {
	console.log('R sync-xhr blocked');
}
</script></body></html>
HTML

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/originfs_test.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
webfs
echo R_UNIT_BEGIN
/dis/tests/originfs_test.dis -v $a $b
echo R_UNIT_END
/dis/tests/js/jspage.dis -w 3000 ${a}page.html
SH
out=$(with_timeout 120 "$EMU" -c1 -pheap=512m -pmain=512m -r"$ROOT" /dis/sh.dis -c "sh /tmp/originfs_test.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
unit=$(echo "$out" | sed -n '/R_UNIT_BEGIN/,/R_UNIT_END/p')
echo "$unit" | grep -q "^PASS" || { echo "FAIL: the filter's own tests"; echo "$unit" | sed 's/^/    /'; failed=1; }
[ $failed = 0 ] && echo "PASS: the filter's own tests"
[ -n "$VERBOSE" ] && echo "$unit"
check() {
    if echo "$out" | grep -q "R $1"; then
        echo "PASS: $2"
    else
        echo "FAIL: $2 (no 'R $1')"
        failed=1
    fi
}
check 'script ran' "another origin's script runs"
check 'json-script-error' "another origin's JSON does not load as a script"
check 'cross-unoffered rejected' "a fetch another origin does not offer fails"
check 'cross-offered true' "one it offers succeeds, carrying this origin"
check 'same true' "a same-origin fetch sends no Origin"
check 'sync-xhr blocked' "a synchronous XMLHttpRequest is held to CORS too"
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | grep -v "^R \|^js:.*: R " | tail -20 | sed 's/^/    /'
exit 1
