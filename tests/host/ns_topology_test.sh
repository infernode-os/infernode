#!/bin/sh
#
# ns_topology_test.sh - the machines a name space spans, drawn from it
# (#1136):
#
#   {while {} {ns; echo; sleep 1}} | ns2mmd | wm/page -s
#
# A pipe exported over the loopback twice, as a plain mount (ns shows
# its dial string) and an encrypted one (ns shows '#D/n/data'), both
# mounted:
#  - #D/n/lower names the encrypted conversation's connection
#    (/net/tcp/k/data), which nothing a process could read joined it to
#  - ns2mmd draws one machine with both mounts on it, the encrypted one
#    marked so; a snapshot the same as the last writes nothing, one
#    changed (a mount gone) writes a chart without it, each ended by a
#    line holding only a form feed; -a draws a local mount (memfs) too
#  - wm/page -s shows each document of a stream in the last one's place:
#    a chart, then one with more boxes, by pixel (SDL emulator)
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/ns2mmd.dis dis/ns.dis dis/listen.dis dis/export.dis dis/memfs.dis dis/auth/createsignerkey.dis dis/auth/mkauthinfo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

P="$ROOT/.ns_topology_test"
trap 'rm -rf "$P".*' EXIT
PORT=$((20000 + $$ % 20000))
FF=$(printf '\f')

cat > "$P.sh" <<ISH
load std
ndb/cs
user=\`{cat /dev/user}
mkdir -p /tmp/nst/keys /tmp/nst/pipe /n/plain /n/enc /n/mem
auth/createsignerkey -f /tmp/nst/keys/signer nst-signer > /dev/null
auth/mkauthinfo -k 'key=/tmp/nst/keys/signer' \$user /tmp/nst/keys/default
bind '#|' /tmp/nst/pipe
listen -A tcp!127.0.0.1!$PORT {export /tmp/nst/pipe}
listen -k /tmp/nst/keys/default -a aes_256_gcm tcp!127.0.0.1!$((PORT+1)) {export /tmp/nst/pipe}
sleep 1
mount -A tcp!127.0.0.1!$PORT /n/plain
mount -k /tmp/nst/keys/default -C aes_256_gcm tcp!127.0.0.1!$((PORT+1)) /n/enc
memfs /n/mem
ns > /.ns_topology_test.ns
d=\`{grep ' /n/enc\$' /.ns_topology_test.ns | sed 's/.*#D\/([0-9]+)\/data.*/\1/'}
cat '#D/'\$d'/lower' > /.ns_topology_test.lower
{ns; echo; ns; echo} | ns2mmd > /.ns_topology_test.same
ns | ns2mmd -a > /.ns_topology_test.all
unmount /n/plain
ns > /.ns_topology_test.ns2
{cat /.ns_topology_test.ns; echo; cat /.ns_topology_test.ns2; echo} | ns2mmd > /.ns_topology_test.changed
echo done > /.ns_topology_test.done
echo halt > /dev/sysctl
ISH
with_timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.ns_topology_test.sh </dev/null >"$P.log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

[ -f "$P.done" ] || { echo "FAIL: the session did not finish"; grep -vE '^[A-Za-z0-9+/=]{30,}' "$P.log" | tail -10; exit 1; }
grep -q "^mount tcp!127.0.0.1!$PORT /n/plain\$" "$P.ns" || fail "ns does not show the plain mount's dial string: $(grep /n/plain "$P.ns")"
grep -q "^mount '#D/[0-9]*/data' /n/enc\$" "$P.ns" || fail "ns does not show the encrypted mount as #D/n/data: $(grep /n/enc "$P.ns")"

lower=$(cat "$P.lower" 2>/dev/null || true)
case "$lower" in
/net/tcp/[0-9]*/data) echo "PASS: #D/n/lower names the connection under it ($lower)" ;;
*) fail "#D/n/lower gives '$lower', want /net/tcp/n/data" ;;
esac

ffs() { grep -c "^$FF\$" "$1" || true; }
[ "$(ffs "$P.same")" = 1 ] && echo "PASS: two snapshots the same: one chart, ended by a form feed" ||
	fail "two snapshots the same gave $(ffs "$P.same") charts"
grep -q '^flowchart LR$' "$P.same" || fail "not a flowchart: $(head -1 "$P.same")"
grep -q '^    h0\["127\.0\.0\.1"\]$' "$P.same" && [ "$(grep -c '^    h[0-9]*\[' "$P.same")" = 1 ] &&
	echo "PASS: both mounts' machine one node" || fail "the machine's nodes: $(grep '^    h[0-9]*\[' "$P.same" | tr '\n' ' ')"
grep -q "^    h0 -->|\"$PORT · /n/plain\"| me\$" "$P.same" && echo "PASS: the plain mount an edge, by its dial string" ||
	fail "no edge for the plain mount: $(grep -- '-->' "$P.same" | tr '\n' ' ')"
grep -q "^    h0 -->|\"$((PORT+1)) · /n/enc<br/>encrypted\"| me\$" "$P.same" && echo "PASS: the encrypted mount an edge, through #D/n/lower, marked encrypted" ||
	fail "no encrypted edge for /n/enc: $(grep -- '-->' "$P.same" | tr '\n' ' ')"
grep -q '/n/mem' "$P.same" && fail "a local mount drawn without -a" || echo "PASS: a local mount left out"

second=$(awk -v ff="$FF" 'n == 1; $0 == ff {n++}' "$P.changed" 2>/dev/null || true)
[ "$(ffs "$P.changed")" = 2 ] && echo "$second" | grep '/n/enc' >/dev/null && echo "PASS: a snapshot changed: a second chart" ||
	fail "a changed snapshot gave $(ffs "$P.changed") charts, want 2"
echo "$second" | grep '/n/plain' >/dev/null && fail "the second chart still has the mount that went" ||
	echo "PASS: the second chart without the mount that went"
grep -q '/n/mem' "$P.all" && echo "PASS: -a draws a local mount too" || fail "-a: no /n/mem in $(cat "$P.all" | tr '\n' ' ')"

# wm/page -s, by pixel: a chart of two boxes, then one of three
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep sdl3_mainloop >/dev/null; then
	echo "SKIP: wm/page -s: $EMU is a headless build"
elif ! command -v python3 >/dev/null 2>&1; then
	echo "SKIP: wm/page -s: no python3"
else
	printf 'flowchart LR\n    a[one] --> b[two]\n\f\n' > "$P.d1"
	printf 'flowchart LR\n    a[one] --> b[two]\n    c[three] --> a\n\f\n' > "$P.d2"
	cat > "$P.page" <<ISH
load std
{cat /.ns_topology_test.d1; sleep 4; cat /.ns_topology_test.d2; sleep 60} | wm/page -s &
sleep 3
/dis/scap.dis /.ns_topology_test.p1.img
sleep 4
/dis/scap.dis /.ns_topology_test.p2.img
echo halt > /dev/sysctl
ISH
	SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -g900x500 -r"$ROOT" /dis/sh.dis /.ns_topology_test.page </dev/null >"$P.plog" 2>&1 || true
	if [ ! -f "$P.p1.img" ] || [ ! -f "$P.p2.img" ]; then
		fail "wm/page -s: no screen captured: $(tail -3 "$P.plog")"
	else
		# a node's border: the theme's diagram border, reddish
		counts=$(python3 - "$ROOT/tools" "$P.p1.img" "$P.p2.img" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
for f in sys.argv[2:]:
    im = load(f); rgb = im.rgb; n = 0
    for p in range(0, len(rgb), 3):
        r, g, b = rgb[p], rgb[p+1], rgb[p+2]
        if r > 150 and g < 130 and b < 110 and r - g > 60:
            n += 1
    print(n)
PY
)
		c1=$(echo "$counts" | sed -n 1p); c2=$(echo "$counts" | sed -n 2p)
		if [ "$c1" -gt 0 ] && [ "$c2" -gt $((c1 + c1/4)) ]; then
			echo "PASS: wm/page -s: the second document shown in the first's place ($c1 border pixels, then $c2)"
		else
			fail "wm/page -s: border pixels $c1 then $c2, want the second chart's three boxes"
		fi
	fi
fi

if [ $failed = 0 ]; then echo "ns_topology_test: ALL PASS"; exit 0; fi
exit 1
