#!/bin/sh
#
# charon_shadowcheck_test.sh — a label clicked in a web component's
# shadow tree checks the checkbox its for names in that tree.  Each such
# component has its own ids, the same in every one (JSTOR's checkboxes
# each hold an input "checkbox-element"); the label's for was looked up
# in the whole document, so a click on one component's label checked
# the first component's box, and the one clicked never changed (JSTOR's
# terms checkbox could not be ticked).  Skipped without python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_shadowcheck_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "charon_shadowcheck_test: SKIP (no python3)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/charon_shadowcheck.XXXXXX")
trap 'kill $srv 2>/dev/null; rm -rf "$d" "$ROOT/tmp/charon_shadowcheck.sh"' EXIT
cat >"$d/serve.py" <<'PY'
import http.server
PAGE = b"""<!doctype html><title>start</title>
<x-check id=one>Remember me</x-check>
<x-check id=two>I agree</x-check>
<script>
customElements.define('x-check', class extends HTMLElement {
	constructor() {
		super();
		const r = this.attachShadow({mode: 'open'});
		r.innerHTML = '<input type=checkbox id=checkbox-element name=' + this.id + '><label for=checkbox-element><slot></slot></label>';
		r.querySelector('input').addEventListener('change', e => { document.title = 'changed ' + this.id + ' ' + e.target.checked; });
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
cat >"$ROOT/tmp/charon_shadowcheck.sh" <<SH
load std
bind -a '#I' /net
ndb/cs
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonsc
mount -A '#scharon/fs' /n/charonsc
echo scripts on > /n/charonsc/ctl
echo open http://127.0.0.1:$port/ > /n/charonsc/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s ready /n/charonsc/title} { sleep 1 } }
sleep 1
labels=()
for n in \`{seq 1 60} {
	if {ftest -e /n/charonsc/dom/\$n/tag && ~ \`{cat /n/charonsc/dom/\$n/tag} label} { labels=(\$labels \$n) }
}
echo R_LABELS \$labels
echo click \${index 2 \$labels} > /n/charonsc/ctl
sleep 2
echo R_TITLE \`{cat /n/charonsc/title}
echo R_FORMS
cat /n/charonsc/forms
echo R_END
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_shadowcheck.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
forms=$(echo "$out" | sed -n '/^R_FORMS/,/^R_END/p' | sed '1d;$d')
if echo "$forms" | grep -q '^0 [0-9]* checkbox two on checked$' &&
   echo "$forms" | grep -q '^0 [0-9]* checkbox one on$'; then
	pass "the second component's label checks its own checkbox, not the first's"
else
	fail "forms: $forms ($(echo "$out" | grep '^R_LABELS'))"
fi
got=$(echo "$out" | sed -n 's/^R_TITLE //p')
if [ "$got" = "changed two true" ]; then
	pass "and the component hears the change"
else
	fail "title '$got'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | tail -30 | sed 's/^/    /'
exit 1
