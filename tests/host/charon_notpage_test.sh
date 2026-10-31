#!/bin/sh
#
# charon_notpage_test.sh — a link to what Charon cannot show (an mp3)
# is not a page: it is saved, not parsed (a podcast's megabytes were
# read whole and parsed as HTML), and the page shown says where it went.
# A server on the loopback offers 20 MB of audio/mpeg and logs how much
# went; headless Charon (wm/charon -h) is sent to it through its files,
# with a home of its own to save in.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_notpage_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_notpage_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_notpage.XXXXXX")
home="$ROOT/tmp/charon_notpage_home"
rm -rf "$home"
mkdir -p "$home/Downloads"
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$home" "$ROOT/tmp/charon_notpage.sh"' EXIT
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
home=/tmp/charon_notpage_home
bind -a '#I' /net
ndb/cs
wm/charon -h http://127.0.0.1:$port/page.html &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonnp
mount -A '#scharon/fs' /n/charonnp
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s done /n/charonnp/status} { sleep 1 } }
echo open http://127.0.0.1:$port/big.mp3 > /n/charonnp/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s Saved /n/charonnp/title} { sleep 1 } }
echo R_STATUS \`{cat /n/charonnp/status}
echo R_TITLE \`{cat /n/charonnp/title}
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh /tmp/charon_notpage.sh; echo halt > '#c/sysctl'" 2>&1)
sleep 1

failed=0
st=$(printf '%s\n' "$out" | sed -n 's/^R_STATUS //p')
title=$(printf '%s\n' "$out" | sed -n 's/^R_TITLE //p')
[ "$st" = done ] && echo "PASS: loaded, not an error" || { echo "FAIL: status '$st'"; failed=1; }
[ "$title" = "Saved big.mp3" ] && echo "PASS: the page says it was saved" || { echo "FAIL: title '$title'"; failed=1; }
size=$(wc -c < "$home/Downloads/big.mp3" 2>/dev/null | tr -d ' ')
if [ "$size" = 20971520 ]; then
    echo "PASS: saved whole in \$home/Downloads"
else
    echo "FAIL: saved '${size:-nothing}' of 20971520 bytes"; failed=1
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
exit 1
