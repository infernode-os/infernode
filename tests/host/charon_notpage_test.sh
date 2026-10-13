#!/bin/sh
#
# charon_notpage_test.sh — a link to what Charon cannot show (an mp3)
# is not a page: Charon says what it is, and does not fetch it past its
# header (a podcast's megabytes were read whole and parsed as HTML).
# A server on the loopback offers 20 MB of audio/mpeg and logs how much
# went; headless Charon (wm/charon -h) is sent to it through its files.
# Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_notpage_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_notpage_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_notpage.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_notpage.sh"' EXIT
cat >"$d/page.html" <<'HTML'
<html><head><title>Start</title></head><body><a href="big.mp3">listen</a></body></html>
HTML
cat >"$d/serve.py" <<'PY'
import http.server, os, sys
os.chdir(sys.argv[1])
SIZE = 20 * 1024 * 1024
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def do_GET(self):
        if self.path == "/big.mp3":
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(SIZE))
            self.end_headers()
            sent = 0
            chunk = b"\xff" * 65536
            try:
                while sent < SIZE:
                    self.wfile.write(chunk)
                    sent += len(chunk)
            except Exception:
                pass
            print("mp3 sent %d of %d" % (sent, SIZE), flush=True)
            return
        b = open("page.html", "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open("port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$d/serve.py" "$d" >"$d/log" 2>&1 &
srv=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/port" ] && break; sleep 0.5; done
port=$(cat "$d/port")

mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/charon_notpage.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h http://127.0.0.1:$port/page.html &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonnp
mount -A '#scharon/fs' /n/charonnp
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s done /n/charonnp/status} { sleep 1 } }
echo open http://127.0.0.1:$port/big.mp3 > /n/charonnp/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s error /n/charonnp/status} { sleep 1 } }
echo R_STATUS \`{cat /n/charonnp/status}
echo R_TITLE \`{cat /n/charonnp/title}
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh /tmp/charon_notpage.sh; echo halt > '#c/sysctl'" 2>&1)
sleep 1

failed=0
st=$(printf '%s\n' "$out" | sed -n 's/^R_STATUS //p')
title=$(printf '%s\n' "$out" | sed -n 's/^R_TITLE //p')
case "$st" in
*audio/mpeg*) echo "PASS: the page says what it is ($st)";;
*) echo "FAIL: status '$st', want an error naming audio/mpeg"; failed=1;;
esac
[ "$title" = "Cannot load page" ] && echo "PASS: the error page is shown" || { echo "FAIL: title '$title'"; failed=1; }
sent=$(sed -n 's/^mp3 sent \([0-9]*\) of.*/\1/p' "$d/log" | head -1)
if [ -n "$sent" ] && [ "$sent" -lt 20971520 ]; then
    echo "PASS: not fetched whole ($sent of 20971520 bytes went)"
else
    echo "FAIL: the mp3 was fetched whole (sent '${sent:-?}')"; failed=1
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
exit 1
