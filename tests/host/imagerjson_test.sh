#!/bin/sh
#
# imagerjson_test.sh -- tools/mkimagerjson.py, which writes the Raspberry Pi
# Imager subitem file each release attaches, so that
# releases/latest/download/os_list_infernode.json is always the latest
# release's:
#
#	from a release's images it writes the reviewed entry's items with that
#	release's version, URLs, date, and the sizes and SHA-256s of the files
#	themselves (compressed and not); everything else in an item --
#	description, devices, init_format -- is the template's, unchanged;
#	an image for a board with no item, an item with no image, an image
#	named for another version, and a date that is not YYYY-MM-DD are
#	refused, not written stale.
#
# The images are small stand-ins: what is tested is the file, not the cards.

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "imagerjson_test: SKIP (no python3)"; exit 77; }
command -v xz >/dev/null 2>&1 || { echo "imagerjson_test: SKIP (no xz)"; exit 77; }

fail=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/imagerjson.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

V=9.9.9
for b in rpi3bplus rpi4b; do
	head -c 300000 /dev/urandom > "$tmp/infernode-$V-$b.img"
	xz -k -T1 "$tmp/infernode-$V-$b.img"
done
T=docs/store/rpi-imager/os_list_infernode.json

if python3 tools/mkimagerjson.py $V 2026-12-01 "$tmp/infernode-$V-rpi3bplus.img.xz" "$tmp/infernode-$V-rpi4b.img.xz" > "$tmp/out.json" 2> "$tmp/err"; then
	pass "it writes a file for a release's two images"
else
	failed "it refused a release's two images: $(cat "$tmp/err")"
fi

# every field checked against the files and the template, by a reader of its own
if python3 - "$tmp" "$V" "$T" <<'EOF'
import hashlib, json, lzma, sys
tmp, v, tpl = sys.argv[1:]
out = json.load(open(tmp + "/out.json"))["os_list"]
template = json.load(open(tpl))["os_list"]
ok = True
def bad(m):
    global ok; ok = False; print("    " + m)
if len(out) != len(template):
    bad("%d items, the template has %d" % (len(out), len(template)))
for got, want in zip(out, template):
    board = want["url"].rsplit("-", 1)[1].split(".")[0]
    f = "%s/infernode-%s-%s.img" % (tmp, v, board)
    xzb, raw = open(f + ".xz", "rb").read(), open(f, "rb").read()
    expect = {
        "url": "https://github.com/infernode-os/infernode/releases/download/v%s/infernode-%s-%s.img.xz" % (v, v, board),
        "release_date": "2026-12-01",
        "image_download_size": len(xzb), "image_download_sha256": hashlib.sha256(xzb).hexdigest(),
        "extract_size": len(raw), "extract_sha256": hashlib.sha256(raw).hexdigest(),
    }
    for k, e in expect.items():
        if got.get(k) != e:
            bad("%s %s: %r, want %r" % (board, k, got.get(k), e))
    if not got["name"].startswith("InferNode %s (" % v):
        bad("%s name: %r" % (board, got["name"]))
    for k in want:
        if k not in expect and k != "name" and got.get(k) != want[k]:
            bad("%s %s changed from the template: %r" % (board, k, got.get(k)))
sys.exit(0 if ok else 1)
EOF
then
	pass "each item's version, URL, date, sizes and SHA-256s are the release's files', and the rest is the template's"
else
	failed "the file does not match the images and the template"
fi

refused() {	# refused <what> <stderr pattern> <args...>
	what=$1 pat=$2; shift 2
	if python3 tools/mkimagerjson.py "$@" > /dev/null 2> "$tmp/err"; then
		failed "it wrote a file for $what"
	elif grep -q "$pat" "$tmp/err"; then
		pass "it refuses $what"
	else
		failed "it refuses $what, but says: $(cat "$tmp/err")"
	fi
}
refused "a board with no image" "no image for the rpi4b item" $V 2026-12-01 "$tmp/infernode-$V-rpi3bplus.img.xz"
cp "$tmp/infernode-$V-rpi4b.img.xz" "$tmp/infernode-$V-rpi5.img.xz"
refused "an image no item is for" "no template item for rpi5" $V 2026-12-01 \
	"$tmp/infernode-$V-rpi3bplus.img.xz" "$tmp/infernode-$V-rpi4b.img.xz" "$tmp/infernode-$V-rpi5.img.xz"
refused "an image named for another version" "is not infernode-9.9.8" 9.9.8 2026-12-01 \
	"$tmp/infernode-$V-rpi3bplus.img.xz" "$tmp/infernode-$V-rpi4b.img.xz"
refused "a date that is not YYYY-MM-DD" "is not YYYY-MM-DD" $V 01/12/2026 \
	"$tmp/infernode-$V-rpi3bplus.img.xz" "$tmp/infernode-$V-rpi4b.img.xz"

[ $fail = 0 ] || exit 1
exit 0
