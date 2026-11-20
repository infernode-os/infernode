#!/bin/bash
#
# tests/host/charon_werc_test.sh
#
# Charon (wm/charon -h, driven through its files by tests/charonsite.b)
# browsing a werc site and a wiki served by svc/httpd/httpd (httpd(8))
# in one emu: wercfs(4) mounted as the site, wikifs mounted at its
# wiki/ with the store's web/ (index.html, create.html) bound before it,
# httpd -T text/html -w /wiki in front.
#
# In Charon: the werc front page (title, menu, body, its style sheet
# fetched); a menu link to a directory and to a page in it, titled from
# the path; the top bar's link to /wiki/, sent on to the front page by
# its refresh; a page created from create.html, its text with quotes,
# < and & shown as typed, an external link to where it says (wikifs
# wrote href=" http://..." and Charon took it for a path of the site);
# the edit form's textarea holding the text as typed; an edit from a
# form another writer has overtaken sent to werror.html, the other's
# text kept.  tests/host/werc/wiki_check.py makes that other edit and
# then checks the wiki from outside (edits in one second, a stale
# edit, one sent twice, what anyone may write kept out of the markup,
# timings).  Each Charon load must finish; the times are printed.
#
# Run from project root: ./tests/host/charon_werc_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

# CHARON_WERC_EMU (a headless emu, tools/sanemu's) to run it otherwise:
# Charon's files need no draw device
EMU="${CHARON_WERC_EMU:-$EMU}"
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/httpd/httpd.dis dis/wercfs.dis dis/wikifs.dis dis/wiki.dis dis/wm/charon.dis dis/tests/charonsite.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

NAME="charon_werc.$$"
W="$ROOT/tmp/$NAME"		# emu sees it as /tmp/$NAME
T=/tmp/$NAME
mkdir -p "$W" || exit 1
emupid=
cleanup() {
	[ -n "$emupid" ] && { kill -9 "$emupid" 2>/dev/null; wait "$emupid" 2>/dev/null; }
	rm -rf "$W"
}
trap cleanup EXIT INT TERM

R="$W/werc"
S="$R/sites/example.test"
mkdir -p "$R/lib" "$R/pub/style" "$S/_werc" "$S/docs" "$S/wiki"
printf '<div class="right"><a href="/wiki/">wiki</a></div>\n' > "$R/lib/top_bar.inc"
printf '<div>werc footer</div>\n' > "$R/lib/footer.inc"
printf 'body { color: black }\n#side-bar { float: left }\n' > "$R/pub/style/style.css"
printf "siteTitle='Example'\nsiteSubTitle='a werc site'\n" > "$S/_werc/config"
printf 'Welcome Home\n============\n\nThe site'"'"'s front page, see the [guide](guide).\n' > "$S/index.md"
printf 'The guide.\n' > "$S/guide.md"
printf 'Docs\n====\n\nthe docs\n' > "$S/docs/index.md"
printf 'Set up with `wercfs`.\n' > "$S/docs/setup-guide.md"
cp -r "$ROOT/services/wiki" "$W/store"

PORT=$((20000 + $$ % 20000))
U="http://127.0.0.1:$PORT"
cat > "$W/cmds" <<EOF
go open $U/
cat title
cat text
cat errors
golink $U/docs/
golink $U/docs/setup-guide
go open $U/
golink $U/wiki/
cat links
golink $U/wiki/create.html
field title Made In Charon
field text Made in Charon, "quoted" <angle> & amp.\n\nSee [the example | http://example.com/] and [wiki syntax].\n
go submit 1
cat text
cat links
golink $U/wiki/made_in_charon/edit.html
cat forms
touch $T/conflict-ready
waitfor $T/conflict-go
field text Charon's edit, which must not win.\n
go submit 1
go open $U/wiki/made_in_charon/
cat text
EOF
cat > "$W/run.sh" <<INFERNO
load std
bind -a '#I' /net
ndb/cs
mkdir -p $T/www /n/cw
mount {wercfs -w $T/werc $T/werc/sites/example.test >[2] $T/wercfs.err} $T/www
mount {wikifs -d $T/store} $T/www/wiki
bind -b $T/store/web $T/www/wiki
svc/httpd/httpd -v -T text/html -w /wiki -l $T/access.log -a tcp!127.0.0.1!$PORT $T/www >[2] $T/httpd.err &
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mount -A '#scharon/fs' /n/cw
/dis/tests/charonsite.dis /n/cw < $T/cmds > $T/out
touch $T/charon-done
while {! ftest -e $T/stop} {sleep 1}
INFERNO
SDL_VIDEODRIVER=dummy "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -r"$ROOT" sh "$T/run.sh" </dev/null >"$W/emu.log" 2>&1 &
emupid=$!

with_timeout 400 python3 -I "$ROOT/tests/host/werc/wiki_check.py" $PORT "$W"
fails=$?
touch "$W/stop"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
out="$W/out"
# the text of file f after go number n (BEGIN f ... END f)
block() { awk -v f="$1" -v n="$2" '/^GO /{g++} $0=="BEGIN " f && g==n {p=1; next} $0=="END " f {p=0} p' "$out"; }
gol() { grep '^GO ' "$out" | sed -n "$1p"; }

[ -s "$out" ] || { fail "Charon's driver gave nothing"; cat "$W/emu.log" | tail -20; echo "charon_werc_test: $fails failed"; exit 1; }
grep '^GO ' "$out" | awk '{print "TIME: Charon " $2 " ms " $3}'
if grep '^GO ' "$out" | grep -qv '(done '; then
	fail "a Charon load did not finish: $(grep '^GO ' "$out" | grep -v '(done ' | head -3)"
else
	pass "each of Charon's $(grep -c '^GO ' "$out") loads finished"
fi
grep '^ERR' "$out" | while read -r l; do echo "FAIL: driver: $l"; done
fails=$((fails + $(grep -c '^ERR' "$out")))

[ "$(block title 1)" = "Welcome Home" ] && pass "werc page: its title from the Markdown's === line" || fail "title: $(block title 1)"
block text 1 | grep -q "front page, see the guide" && pass "werc page: its body" || fail "text: $(block text 1 | head -5)"
block text 1 | grep -q "guide" && block text 1 | grep -q "docs/" && pass "werc page: its menu" || fail "menu: $(block text 1 | head -8)"
[ -z "$(block errors 1)" ] && pass "every resource the page names fetched (its style sheet)" || fail "errors: $(block errors 1)"
gol 2 | grep -q "$U/docs/ | Docs |" && pass "a menu link to a directory: its index" || fail "$(gol 2)"
gol 3 | grep -q "$U/docs/setup-guide | docs - setup guide |" && pass "a page in it, titled from its path" || fail "$(gol 3)"
gol 5 | grep -q "$U/wiki/1/ | infernode wiki" && pass "the top bar's /wiki/ goes on to the wiki's front page" || fail "$(gol 5)"
block links 5 | grep -q "$U/wiki/wiki_syntax wiki syntax" && pass "the front page links the syntax page" || fail "links: $(block links 5)"
gol 7 | grep -q "$U/wiki/made_in_charon/index.html | Made In Charon" && pass "a page created from create.html" || fail "$(gol 7)"
block text 7 | grep -qF 'Made in Charon, "quoted" <angle> & amp.' && pass "its text as typed, quotes, < and & too" || fail "text: $(block text 7)"
block links 7 | grep -q '^[0-9]* http://example.com/ the example$' && pass "an external link goes where it says" || fail "links: $(block links 7)"
block links 7 | grep -q "$U/wiki/wiki_syntax wiki syntax" && pass "a page link to its page" || fail "links: $(block links 7)"
block forms 8 | grep -qF 'textarea text Made in Charon, "quoted" <angle> & amp.\n\nSee [the example | http://example.com/] and [wiki syntax].' &&
	pass "the edit form's textarea holds the text as typed" || fail "forms: $(block forms 8 | grep textarea)"
gol 9 | grep -q "$U/wiki/made_in_charon/werror.html" && pass "an edit from an overtaken form goes to werror.html" || fail "$(gol 9)"
block text 10 | grep -q "The other writer's edit." && ! block text 10 | grep -q "must not win" &&
	pass "and the other writer's text is kept" || fail "text: $(block text 10)"

if ! kill -0 "$emupid" 2>/dev/null; then
	fail "emu exited"
fi
if grep -qiE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log"; then
	fail "emu reported a fault: $(grep -iE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log" | head -3)"
fi
[ "$fails" -eq 0 ] || { echo "--- driver"; cat "$out"; echo "--- emu (last 20 lines)"; tail -20 "$W/emu.log"; }
echo "charon_werc_test: $fails failed"
[ "$fails" -eq 0 ]
