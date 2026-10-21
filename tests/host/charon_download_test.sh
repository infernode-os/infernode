#!/bin/sh
#
# charon_download_test.sh — a page navigated to that Charon does not
# show (a PDF) is saved and opened.  It gave a page saying Charon does
# not show it, and the file was lost (JSTOR's Download).  Saved in
# $home/Downloads under the name Content-Disposition gives, made safe
# for a file name; a second with the same name beside it, not over it;
# the path plumbed; the page shown saying where it went.  A frame's PDF
# is not saved.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_download_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_download_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_download.XXXXXX")
home="$ROOT/tmp/charon_download_home"
rm -rf "$home"
mkdir -p "$home/Downloads"
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$home" "$ROOT/tmp/charon_download.sh" "$ROOT/tmp/charon_download.rules"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server
PDF = b"%PDF-1.4\n" + bytes(range(256)) * 20
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def send(self, ctype, body, extra=()):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/stable/pdf/"):
            return self.send("application/pdf", PDF, [("Content-Disposition", 'attachment; filename="Oakeshott on Politics.pdf"')])
        if self.path == "/framed.pdf":
            return self.send("application/pdf", PDF)
        if self.path == "/frame":
            return self.send("text/html", b"<!doctype html><title>framed</title><iframe src=/framed.pdf></iframe>")
        self.send_error(404)
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
cat >"$ROOT/tmp/charon_download.rules" <<'R'
kind is text
data matches '.+'
plumb to edit
R
cat >"$ROOT/tmp/charon_download.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
home=/tmp/charon_download_home
bind -bc '#splumber' /chan
plumber /tmp/charon_download.rules
for i in 1 2 3 4 5 { if {! ftest -e /chan/plumb.edit} { sleep 1 } }
cat /chan/plumb.edit > /tmp/charon_download_home/plumbed &
sleep 1
# a port's reader is known to the plumber by a start message from it
echo -n 'edit
plumb

text

5
start' > /chan/plumb.input
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charondl
mount -A '#scharon/fs' /n/charondl
echo open http://127.0.0.1:$port/stable/pdf/10.2307_2130135.pdf > /n/charondl/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s Saved /n/charondl/title} { sleep 1 } }
echo R_TITLE1 \`{cat /n/charondl/title}
echo R_TEXT1 \`{cat /n/charondl/text}
echo open http://127.0.0.1:$port/stable/pdf/10.2307_2130135.pdf?again > /n/charondl/ctl
sleep 3
echo open http://127.0.0.1:$port/frame > /n/charondl/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s framed /n/charondl/title} { sleep 1 } }
sleep 3
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_download.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
dl="$home/Downloads"
want=$(python3 -c 'import sys; sys.stdout.buffer.write(b"%PDF-1.4\n" + bytes(range(256)) * 20)' | cksum)
if [ -f "$dl/Oakeshott_on_Politics.pdf" ] && [ "$(cksum < "$dl/Oakeshott_on_Politics.pdf")" = "$want" ]; then
	pass "a PDF navigated to is saved whole, named as Content-Disposition says, made safe"
else
	fail "saved: $(ls "$dl")"
fi
if [ -f "$dl/Oakeshott_on_Politics-1.pdf" ]; then
	pass "a second of the same name is saved beside it, not over it"
else
	fail "second: $(ls "$dl")"
fi
if ! ls "$dl" | grep -q framed; then
	pass "a frame's PDF is not saved"
else
	fail "a frame's PDF was saved: $(ls "$dl")"
fi
if grep -q "/tmp/charon_download_home/Downloads/Oakeshott_on_Politics.pdf" "$home/plumbed" 2>/dev/null; then
	pass "the file saved is plumbed"
else
	fail "plumbed: $(cat "$home/plumbed" 2>/dev/null)"
fi
if echo "$out" | grep -q '^R_TITLE1 Saved Oakeshott_on_Politics.pdf$' &&
   echo "$out" | grep -q '^R_TEXT1 .*/tmp/charon_download_home/Downloads/Oakeshott_on_Politics.pdf'; then
	pass "the page says where it went"
else
	fail "page: $(echo "$out" | grep '^R_T')"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
