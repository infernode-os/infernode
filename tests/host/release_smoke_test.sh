#!/bin/sh
#
# release_smoke_test.sh pkgdir emu root [gui]
#
# Charon in a release package, as a user meets it.  pkgdir is the staged
# package (what is archived and shipped); emu and root are the emulator
# and the runtime tree within it (emu/Linux/o.emu and . in the headless
# tarball, bin/emu and resources in the GUI one, InferNode.app's
# Contents/MacOS/emu and Contents/Resources).  It runs on a copy, so the
# package is left as it is.
#
#   every package: headless Charon (wm/charon -h) with no URL is showing
#     its start page; told to open a page of forty sections with scripts
#     off (the default), it has all their text and links.
#   gui: the same page in Xenith (xenith -l, the page opened as a browser
#     window), and Charon in Lucifer's presentation view: with no URL its
#     start page, then the page.
#
# 0.8.0 shipped a Charon whose start page was a test fixture, in no
# package; every test ran on the source tree, so none saw it.

pkg=$1; emu=$2; root=$3; gui=$4
[ -d "$pkg" ] && [ -n "$emu" ] && [ -n "$root" ] || { echo "usage: release_smoke_test.sh pkgdir emu root [gui]" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/release_smoke.XXXXXX")
trap 'rm -rf "$t"' EXIT
cp -a "$pkg" "$t/pkg"
E="$t/pkg/$emu"; R=$(cd "$t/pkg/$root" && pwd)
[ -x "$E" ] || { echo "FAIL: no emulator at $emu"; exit 1; }
case "$E" in */bin/emu) LD_LIBRARY_PATH="$(dirname "$E")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; export LD_LIBRARY_PATH;; esac
export SDL_VIDEODRIVER=dummy
# macOS has no timeout(1)
command -v timeout >/dev/null 2>&1 || timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
HOME="$t/home"; mkdir -p "$HOME"; export HOME

home=$(sed -n 's/^HOME: con "\(.*\)";.*/\1/p' "$(dirname "$0")/../../appl/charon/charon.b")
[ -n "$home" ] || { echo "FAIL: cannot read Charon's HOME"; exit 1; }

# the page: forty sections, each a heading, a paragraph and a link
mkdir -p "$R/lib/release_smoke"
{
	echo '<!doctype html><title>Release smoke</title><body style="font-family: sans-serif; max-width: 640px; margin: 0 auto">'
	i=1
	while [ $i -le 40 ]; do
		echo "<h2>Section $i</h2><p>Paragraph $i of the release smoke page, long enough to wrap onto a second line in a narrow view.</p><p><a href=\"#s$i\">link $i</a></p>"
		i=$((i+1))
	done
	echo '<p>END-OF-SMOKE</p>'
} >"$R/lib/release_smoke/page.html"
PAGE=file:///lib/release_smoke/page.html

fail=0
check() {	# name output pattern...  (its own names: sh has no locals)
	ck_n=$1; ck_o=$2; shift 2
	for ck_p in "$@"; do
		if ! printf '%s\n' "$ck_o" | grep -q -- "$ck_p"; then
			echo "FAIL: $ck_n: no '$ck_p'"; printf '%s\n' "$ck_o" | grep -E '^(URL|TITLE|STATUS|TEXT|LINKS|BODY|IMAGE) ' | sed 's/^/    /'
			fail=1; return
		fi
	done
	echo "PASS: $ck_n"
}

# The page files of the Charon posted at #scharon/fs, as lines to check
cat >"$R/lib/release_smoke/report.sh" <<'RC'
fn report {
	mkdir -p /tmp/rs
	mount -A '#scharon/fs' /tmp/rs
	for i in `{seq 1 30} {
		s=`{cat /tmp/rs/status}
		if {~ $s loading* fetching*} { sleep 1 }
	}
	echo URL `{cat /tmp/rs/url} > '#c/cons'
	echo TITLE `{cat /tmp/rs/title} > '#c/cons'
	echo STATUS `{cat /tmp/rs/status} > '#c/cons'
	echo TEXT `{grep 'Paragraph|END-OF-SMOKE' /tmp/rs/text | wc -l} `{grep END-OF-SMOKE /tmp/rs/text | wc -l} > '#c/cons'
	echo LINKS `{cat /tmp/rs/links | wc -l} > '#c/cons'
	unmount /tmp/rs
}
RC

# 1. headless Charon
cat >"$R/lib/release_smoke/headless.sh" <<RC
load std
run /lib/release_smoke/report.sh
wm/charon -h &
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {! ftest -e '#scharon/fs'} { sleep 1 }
}
sleep 2
report
mkdir -p /tmp/rs
mount -A '#scharon/fs' /tmp/rs
echo open $PAGE > /tmp/rs/ctl
unmount /tmp/rs
sleep 3
report
echo halt > /dev/sysctl
RC
o=$(timeout 120 "$E" -c1 -pheap=1536m -pmain=1024m -pimage=1024m -r"$R" /dis/sh.dis -c "run /lib/release_smoke/headless.sh" </dev/null 2>&1)
check "headless Charon opens on its start page" "$(printf '%s\n' "$o" | sed -n '1,/^LINKS/p')" "^URL $home\$" "^TITLE Charon\$" "^STATUS done"
check "headless Charon shows a page with scripts off" "$(printf '%s\n' "$o" | sed '1,/^LINKS/d')" "^URL $PAGE\$" "^TITLE Release smoke\$" "^STATUS done" "^TEXT 41 1\$" "^LINKS 40\$"

if [ "$gui" = gui ]; then
	# 2. Xenith: the page as a browser window
	cat >"$R/lib/release_smoke/xenith.sh" <<RC
load std
X=/mnt/xenith
id=\`{cat \$X/new/ctl}
id=\${index 1 \$id}
echo -n $PAGE > \$X/\$id/body
n=\`{echo -n $PAGE | wc -c}
echo 'ML0 '^\$n > \$X/\$id/event
echo clean > \$X/\$id/ctl
echo delete > \$X/\$id/ctl
w=()
for i in \`{seq 1 30} {
	if {~ \$#w 0} {
		for l in \${split '
' "{cat \$X/index}} {
			fl := \${split ' 	' \$l}
			if {~ \${index 6 \$fl} $PAGE} { w=\${index 1 \$fl} }
		}
		sleep 1
	}
}
sleep 3
echo BODY \`{grep 'Paragraph|END-OF-SMOKE' \$X/\$w/body | wc -l} > '#c/cons'
echo IMAGE \`{cat \$X/\$w/image} > '#c/cons'
echo halt > '#c/sysctl'
RC
	d=/lib/release_smoke/dump
	{ echo /; echo; echo; printf '%11d \n' 0; printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0; echo; echo /; echo "sh /lib/release_smoke/xenith.sh"; } >"$R$d"
	o=$(timeout 120 "$E" -c1 -pheap=1536m -pmain=1024m -pimage=1024m -g1280x800 -r"$R" /dis/sh.dis -c "load std; mkdir -p /tmp; xenith -l $d" </dev/null 2>&1)
	check "Xenith shows the page" "$o" "^BODY 41\$" "^IMAGE ."

	# 3. Lucifer: Charon in the presentation view
	cat >"$R/lib/release_smoke/lucifer.sh" <<RC
load std
run /lib/release_smoke/report.sh
echo 'activity create Main' > /mnt/ui/ctl
sleep 2
echo 'create id=charon type=app label=charon dis=/dis/wm/charon.dis' > /mnt/ui/activity/0/presentation/ctl
echo 'center id=charon' > /mnt/ui/activity/0/presentation/ctl
for i in \`{seq 1 30} {
	if {! ftest -e '#scharon/fs'} { sleep 1 }
}
sleep 3
report
mkdir -p /tmp/rs
mount -A '#scharon/fs' /tmp/rs
echo open $PAGE > /tmp/rs/ctl
unmount /tmp/rs
sleep 3
report
echo halt > /dev/sysctl
RC
	o=$(timeout 240 "$E" -c1 -pheap=1536m -pmain=1024m -pimage=1024m -g1440x900 -r"$R" /dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; run /lib/release_smoke/lucifer.sh" </dev/null 2>&1)
	check "Lucifer's Charon opens on its start page" "$(printf '%s\n' "$o" | sed -n '1,/^LINKS/p')" "^URL $home\$" "^TITLE Charon\$" "^STATUS done"
	check "Lucifer's Charon shows a page with scripts off" "$(printf '%s\n' "$o" | sed '1,/^LINKS/d')" "^URL $PAGE\$" "^TITLE Release smoke\$" "^STATUS done" "^TEXT 41 1\$" "^LINKS 40\$"
fi

[ $fail = 0 ] && echo "ALL PASS"
exit $fail
