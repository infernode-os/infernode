#!/bin/sh
#
# charon_accept_test.sh — what Charon's engine says it will take.  An
# image fetch says image/webp first, as browsers do, so a server that
# picks the format by it (an image CDN) sends WebP; a page or style
# sheet fetch says nothing, which is anything.  A server on the
# loopback logs each request's Accept; headless Charon (wm/charon -h)
# loads a page with an image and a style sheet from it.  Skipped
# without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_accept_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_accept_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_accept.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_accept.sh"' EXIT
cp tests/imgload/rb.png "$d/rb.png"
echo 'body { color: black }' >"$d/s.css"
cat >"$d/page.html" <<'HTML'
<html><head><title>Accept</title><link rel="stylesheet" href="s.css"></head>
<body><img src="rb.png"></body></html>
HTML
cat >"$d/serve.py" <<'PY'
import http.server, os, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, f, *a):
        print("%s %s" % (self.path, self.headers.get("Accept")), flush=True)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open("port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$d/serve.py" "$d" >"$d/log" 2>&1 &
srv=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/port" ] && break; sleep 0.5; done
port=$(cat "$d/port")

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/charon_accept.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h http://127.0.0.1:$port/page.html &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mount -A '#scharon/fs' /n/remote
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s rb.png /n/remote/status} { sleep 1 } }
sleep 2
SH
SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh /tmp/charon_accept.sh; echo halt > '#c/sysctl'" >/dev/null 2>&1

failed=0
check() {
    got=$(grep "^$1 " "$d/log" | head -1 | cut -d' ' -f2-)
    if [ "$got" = "$2" ]; then
        echo "PASS: $3"
    else
        echo "FAIL: $3: Accept '$got', want '$2'"
        failed=1
    fi
}
check /page.html None 'the page: no Accept'
check /s.css None 'the style sheet: no Accept'
check /rb.png 'image/webp,image/svg+xml,image/*,*/*;q=0.8' 'the image: image/webp first'
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
sed 's/^/    /' "$d/log"
exit 1
