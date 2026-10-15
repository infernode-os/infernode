#!/bin/sh
#
# charon_home_test.sh — Charon's start page is one the release ships.
# Its HOME is a file: URL; the file must exist and lie under a directory
# every release job stages (.github/workflows/release.yml, its
# "for d in ...; do" copies).  It was a test fixture, which no package
# carries, so every released Charon opened on "file does not exist".
# Then, with an emu, headless Charon opens with no URL and must be
# showing that page.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

fail=0
home=$(sed -n 's/^HOME: con "\(.*\)";.*/\1/p' appl/charon/charon.b)
case "$home" in
file:///*) path=${home#file://} ;;
*) echo "FAIL: HOME is not a file: URL: '$home'"; exit 1 ;;
esac
if [ -f ".$path" ]; then
	echo "PASS: HOME $path exists"
else
	echo "FAIL: HOME $path does not exist"; fail=1
fi
top=$(echo "$path" | cut -d/ -f2)
lists=$(grep -E '^[[:space:]]*for d in .*; do' .github/workflows/release.yml | sed 's/.*for d in \(.*\); do.*/\1/')
[ -n "$lists" ] || { echo "FAIL: no staging lists found in release.yml"; exit 1; }
missing=$(echo "$lists" | while read -r l; do
	case " $l " in *" $top "*) ;; *) echo "$l" ;; esac
done)
if [ -z "$missing" ]; then
	echo "PASS: /$top is staged by every release job"
else
	echo "FAIL: /$top is not staged by the release job copying: $(echo "$missing" | sort -u | tr "\n" ";")"; fail=1
fi

if [ -x "$EMU" ]; then
	cat >"$ROOT/tmp/charon_home.sh" <<'RC'
load std
wm/charon -h &
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {! ftest -e '#scharon/fs'} { sleep 1 }
}
mkdir -p /tmp/charon_home
mount -A '#scharon/fs' /tmp/charon_home
sleep 2
echo URL `{cat /tmp/charon_home/url}
echo TITLE `{cat /tmp/charon_home/title}
echo STATUS `{cat /tmp/charon_home/status}
echo halt > /dev/sysctl
RC
	out=$(SDL_VIDEODRIVER=dummy timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "run /tmp/charon_home.sh" </dev/null 2>&1)
	rm -f "$ROOT/tmp/charon_home.sh"
	if echo "$out" | grep -q "^URL $home\$" && echo "$out" | grep -q "^TITLE Charon\$" && echo "$out" | grep -q "^STATUS done"; then
		echo "PASS: Charon opens on its start page"
	else
		echo "FAIL: Charon with no URL:"; echo "$out" | grep -E "^(URL|TITLE|STATUS)" ; fail=1
	fi
else
	echo "SKIP: no emu, start page not opened"
fi

[ $fail = 0 ] && echo "ALL PASS"
exit $fail
