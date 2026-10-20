#!/bin/sh
#
# charon_shadowlabel_test.sh — a button's label in Charon's files is the
# one shown.  A web component's button is in its shadow tree, and its
# label is what the page put in the component, shown through a slot; the
# forms file and dom/N/text read the button's own subtree, so such a
# button had no label, and nothing reading the files (a script, an
# agent) could tell one from another (JSTOR's sign-in buttons are all
# such).  A host's text left out its shadow tree, and took the shadow
# tree's style sheet as text when it was shown.  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_shadowlabel_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_shadowlabel_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_shadowlabel.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_shadowlabel.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server, sys
PAGE = b"""<!doctype html><title>start</title>
<x-btn id=one><span>Find my institution</span></x-btn>
<x-btn id=two>Log in</x-btn>
<button>Plain</button>
<script>
customElements.define('x-btn', class extends HTMLElement {
	constructor() {
		super();
		this.attachShadow({mode: 'open'}).innerHTML =
			'<style>button { color: red }</style><button class=b><span>&#x2192; </span><slot></slot></button>';
	}
});
document.title = 'ready';
</script>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)
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
cat >"$ROOT/tmp/charon_shadowlabel.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonsl
mount -A '#scharon/fs' /n/charonsl
echo scripts on > /n/charonsl/ctl
echo open http://127.0.0.1:$port/ > /n/charonsl/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s ready /n/charonsl/title} { sleep 1 } }
sleep 1
echo R_FORMS
cat /n/charonsl/forms
echo R_TEXT
getlines {
	n=\${index 2 \${split ' ' \$line}}
	echo T \$n \`{cat /n/charonsl/dom/\$n/text}
} < /n/charonsl/forms
echo R_HOST
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 {
	if {grep -s '^id one' /n/charonsl/dom/\$n/attrs} { echo H \$n \`{cat /n/charonsl/dom/\$n/text} }
}
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_shadowlabel.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
forms=$(echo "$out" | sed -n '/^R_FORMS/,/^R_TEXT/p' | sed '1d;$d')
if echo "$forms" | grep -q '^0 [0-9]* submit - → Find my institution$' &&
   echo "$forms" | grep -q '^0 [0-9]* submit - → Log in$'; then
	pass "forms labels a component's buttons with what the page put in them"
else
	fail "forms: $forms"
fi
if echo "$forms" | grep -q '^0 [0-9]* submit - Plain$'; then
	pass "a plain button keeps its label"
else
	fail "plain: $forms"
fi
if echo "$out" | grep -q '^T [0-9]* → Find my institution$'; then
	pass "dom/N/text of a component's button is its label as shown"
else
	fail "text: $(echo "$out" | grep '^T ')"
fi
got=$(echo "$out" | sed -n 's/^H [0-9]* //p')
if [ "$got" = "→ Find my institution" ]; then
	pass "a host's text is its shadow tree's, without the style sheet"
else
	fail "host text '$got'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
