#!/bin/bash
#
# tests/host/werc_test.sh
#
# A werc site through wercfs(4) and svc/httpd/httpd (httpd(8)), from
# outside: tests/host/werc/check.py over HTTP against one httpd
# (-T text/html) serving wercfs mounted on a werc tree made here:
#
#   werc/lib/          footer.inc, top_bar.inc (werc's own)
#   werc/pub/style/    style.css
#   werc/sites/master.test/_werc/lib/top_bar.inc   ($masterSite's)
#   werc/sites/example.test/                       the site
#
# What it checks: Markdown, HTML and text pages in the master template
# (doctype, title, the site's header, menu, article, footer); titles from
# a .md's === line, a .html's <title> and the path; _werc/config read
# root first and down the path (a directory's own siteSubTitle),
# assignments in braces and other rc not taken and said so on stderr;
# get_lib_file's order (the site's footer.inc, the master site's
# top_bar.inc, werc's lib); the menu nested to the page with thisPage
# on its path, _ . index and conf_hide_paths names left out, a hidden
# page still served; a directory with no index listed between its
# _header.md and _footer.md; a directory and a page of one name the
# directory; a page's source and the site's files as they are; pub/
# from the site and from werc, _werc/pub/ and nothing else of _werc;
# a page's Content-Length, ETag, 304, ranges and HEAD; an edit, a new
# page and a removed one seen at the next request, an unchanged page's
# ETag kept; host symbolic links out of the site not followed (a page,
# a file, a directory, an included file); 30 clients at once.  Then emu
# must not have faulted.
#
# Run from project root: ./tests/host/werc_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

EMU="${WERC_EMU:-$EMU}"
EMUFLAGS="${WERC_EMUFLAGS:--c1}"
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/httpd/httpd.dis dis/wercfs.dis dis/lib/mdhtml.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

NAME="werc_test.$$"
W="$ROOT/tmp/$NAME"		# emu sees it as /tmp/$NAME
mkdir -p "$W" || exit 1
emupid=
cleanup() {
	[ -n "$emupid" ] && { kill -9 "$emupid" 2>/dev/null; wait "$emupid" 2>/dev/null; }
	rm -rf "$W"
}
trap cleanup EXIT INT TERM

R="$W/werc"
S="$R/sites/example.test"
mkdir -p "$R/lib" "$R/pub/style" "$R/sites/master.test/_werc/lib" \
	"$S/_werc/pub" "$S/_werc/lib" "$S/docs/_werc" "$S/list" "$S/both" "$S/pub" "$S/deep/er"

printf '<div>werc footer</div>\n' > "$R/lib/footer.inc"
printf '<div>werc top bar</div>\n' > "$R/lib/top_bar.inc"
printf 'body { color: black }\n' > "$R/pub/style/style.css"
printf '<div class="master-top">master top bar</div>\n' > "$R/sites/master.test/_werc/lib/top_bar.inc"

cat > "$S/_werc/config" <<'EOF'
# the site's settings
masterSite=master.test
siteTitle='Test Site'
siteSubTitle='it''s a subtitle'	# a comment
meta_description='a site for the test'
sideBarNavTitle=Pages
conf_hide_paths secret
conf_enable_blog
if(~ $req_path /docs/*) {
	siteTitle='WRONG'
}
EOF
printf 'site { }\n' > "$S/_werc/pub/style.css"
printf '<div class="site-footer">site footer</div>\n' > "$S/_werc/lib/footer.inc"
printf 'siteSubTitle=(docs subtitle)\n' > "$S/docs/_werc/config"

cat > "$S/index.md" <<'EOF'
Home Page
=========

Welcome *in*, see [the guide](docs/setup-guide) and ![a cat](/img.png).

* one
* two
EOF
printf 'About us.\n\n    code < here\n' > "$S/about.md"
printf '<html><head><title>Hello Title</title></head>\n<body class="x"><p>hello body</p></body></html>\n' > "$S/hello.html"
printf 'a < b & c\n' > "$S/notes.txt"
printf 'Secret\n======\n\nhidden from the menu\n' > "$S/secret.md"
printf 'draft\n' > "$S/_draft.md"
printf 'dot\n' > "$S/.hidden.md"
head -c 3000 /dev/urandom > "$S/img.png"
printf 'Docs\n====\n\nthe docs\n' > "$S/docs/index.md"
printf 'Set up with `wercfs`.\n' > "$S/docs/setup-guide.md"
printf 'deep\n' > "$S/deep/er/most.md"
printf 'page a\n' > "$S/list/a.md"
printf 'text b\n' > "$S/list/b.txt"
printf 'the list *header*\n' > "$S/list/_header.md"
printf 'the list footer\n' > "$S/list/_footer.md"
printf 'raw\n' > "$S/list/raw.dat"
printf 'not shown\n' > "$S/both.md"
printf 'Both\n====\n\nthe directory\n' > "$S/both/index.md"
printf 'site pub\n' > "$S/pub/site.txt"
printf 'outside the site\n' > "$W/outside.md"
ln -s "$W/outside.md" "$S/escape.md"
ln -s "$W/outside.md" "$S/escape2.txt"
ln -s "$W" "$S/escapedir"
ln -s "$W/outside.md" "$S/_werc/lib/headers.inc"

PORT=$((20000 + $$ % 20000))
T=/tmp/$NAME
cat > "$W/run.sh" <<INFERNO
mkdir -p $T/www
mount {wercfs -w $T/werc $T/werc/sites/example.test >[2] $T/wercfs.err} $T/www
svc/httpd/httpd -v -s 40 -T text/html -l $T/access.log -a tcp!127.0.0.1!$PORT $T/www &
while {! ftest -e $T/stop} {sleep 1}
INFERNO
"$EMU" $EMUFLAGS -r"$ROOT" sh "$T/run.sh" </dev/null >"$W/emu.log" 2>&1 &
emupid=$!

up() { python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), timeout=1)" 2>/dev/null; }
for _ in $(seq 1 100); do
	up $PORT && break
	sleep 0.1
done
up $PORT || { echo "FAIL: httpd did not start"; cat "$W/emu.log"; exit 1; }

with_timeout 300 python3 -I "$ROOT/tests/host/werc/check.py" $PORT "$S" "$W/wercfs.err"
fails=$?

touch "$W/stop"
if ! kill -0 "$emupid" 2>/dev/null; then
	echo "FAIL: emu exited"; fails=$((fails+1))
fi
if grep -qiE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log" "$W/wercfs.err"; then
	echo "FAIL: emu reported a fault"; grep -iE 'panic|SYS: process|broken|sanitizer|fault' "$W/emu.log" "$W/wercfs.err" | head -5
	fails=$((fails+1))
fi
[ "$fails" -eq 0 ] || { echo "--- emu (last 30 lines)"; tail -30 "$W/emu.log"; echo "--- wercfs"; cat "$W/wercfs.err"; }
echo "werc_test: $fails failed"
[ "$fails" -eq 0 ]
