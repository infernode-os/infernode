#!/bin/sh
#
# charon_scriptimg_test.sh — an image a page's script puts in after the
# page loaded is fetched and shown.  The page's images were sent for
# once, as it loaded; one a script added later (JSTOR's logo, in a header
# its script makes, a data: URL) was never fetched and its alt text was
# shown in its place.  A data: SVG and a file's, each 40 by 40 and given
# no size by CSS, put in by a timer: laid out 40 by 40 once fetched.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_scriptimg_test: SKIP (no emu)"; exit 77; }

mkdir -p "$ROOT/tmp"
trap 'rm -f "$ROOT/tmp/charon_scriptimg.sh" "$ROOT/tmp/charon_scriptimg.html" "$ROOT/tmp/charon_scriptimg.svg"' EXIT
svg='<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#900"/></svg>'
echo "$svg" >"$ROOT/tmp/charon_scriptimg.svg"
b64=$(printf '%s' "$svg" | base64 | tr -d '\n')
cat >"$ROOT/tmp/charon_scriptimg.html" <<HTML
<!doctype html>
<html><head><title>start</title><style>body { margin: 0 } img { display: block }</style></head><body>
<div id=a></div><div id=b></div>
<script>
setTimeout(() => {
	const i = document.createElement('img');
	i.id = 'data';
	i.alt = 'a data: image';
	i.src = 'data:image/svg+xml;base64,$b64';
	document.getElementById('a').appendChild(i);
	const j = document.createElement('img');
	j.id = 'file';
	j.alt = 'a file';
	j.src = 'charon_scriptimg.svg';
	document.getElementById('b').appendChild(j);
	document.title = 'ready';
}, 1000);
</script>
</body></html>
HTML
cat >"$ROOT/tmp/charon_scriptimg.sh" <<'SH'
load std
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonsi
mount -A '#scharon/fs' /n/charonsi
echo scripts on > /n/charonsi/ctl
echo size 600x300 > /n/charonsi/ctl
echo open file:///tmp/charon_scriptimg.html > /n/charonsi/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s ready /n/charonsi/title} { sleep 1 } }
for d in /n/charonsi/dom/* { if {~ `{cat $d/tag} img} { cat $d/box > /dev/null } }
sleep 3
for d in /n/charonsi/dom/* {
	if {~ `{cat $d/tag} img} { echo R_IMG `{grep '^id ' $d/attrs} '=>' `{cat $d/box} }
}
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -g600x300 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_scriptimg.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
for id in data file; do
	got=$(echo "$out" | sed -n "s/^R_IMG id $id => //p" | head -1)
	case "$got" in
	"replaced "*" 40 40") pass "a $id image a script put in is fetched and shown ($got)";;
	*) fail "the $id image: '$got'";;
	esac
done
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | grep '^R_' >&2
exit 1
