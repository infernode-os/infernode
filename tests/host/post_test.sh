#!/bin/bash
#
# tests/host/post_test.sh
#
# post(1): a directory of the name space posted in #s for any other to
# mount. Over a vid9p clip:
#
#   - #s<spec>/fs appears, and a mount of it reads what the directory has
#     (fmt; every frame byte for byte, against the direct mount)
#   - each open is a connection of its own: two mounts read at once
#   - a directory that is not one refused; a spec taken refused
#   - post's group killed (kill -g, by its pid): the posted file gone and
#     its connections with it (#s relays them through post)
#   - the time to read the clip direct and through post printed
#
# Run from project root: ./tests/host/post_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in post.dis vid9p.dis lib/post9p.dis cmp.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

W="$ROOT/tmp/post_test.$$"
rm -rf "$W"
mkdir -p "$W"
trap '[ -n "$KEEP" ] || rm -rf "$W"' EXIT
E=/tmp/post_test.$$
python3 - "$W/clip.y4m" <<'PY'
import sys
w, h = 160, 120
with open(sys.argv[1], "wb") as f:
    f.write(b"YUV4MPEG2 W%d H%d F30:1 Ip A1:1 C420jpeg\n" % (w, h))
    for i in range(60):
        f.write(b"FRAME\n" + bytes([(i*7 + j) & 255 for j in range(256)]) * (w*h*3//2 // 256) + bytes(w*h*3//2 % 256))
PY
S="post_test.$$"
cat > "$W/run.sh" <<RUN
load std
mkdir -p /mnt/a /mnt/b /mnt/c
mount {vid9p $E/clip.y4m} /mnt/a
post $S /mnt/a &
postpid=\$apid
sleep 1
ls '#s$S'
echo '-- fmt'; mount -A '#s$S/fs' /mnt/b; cat /mnt/b/0/fmt
cmp /mnt/a/0/frame /mnt/b/0/frame; echo CMP-\$status
echo '-- two'; mount -A '#s$S/fs' /mnt/c
{ cmp /mnt/b/0/frame /mnt/a/0/frame; echo TWO-B-\$status } & cmp /mnt/c/0/frame /mnt/a/0/frame; echo TWO-C-\$status
sleep 1
echo '-- refused'; post x /mnt/a/0/fmt; echo NOTDIR-\$status
post $S /mnt/a; echo TAKEN-\$status
echo '-- times'; time cat /mnt/a/0/frame > /dev/null; time cat /mnt/b/0/frame > /dev/null
echo '-- killed'; kill -g \$postpid; sleep 1
mkdir -p /mnt/d; mount -A '#s$S/fs' /mnt/d; echo NEWMOUNT-\$status
cmp /mnt/a/0/frame /mnt/b/0/frame; echo STILL-\$status
echo POST-DONE
echo halt > '#c/sysctl'
RUN
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" > "$W/log" 2>&1 < /dev/null
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
grep -q '^POST-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -15; exit 1; }
grep -q "#s$S/fs" "$W/log" && ok "#s<spec>/fs posted" || bad "not posted: $(grep -v fsqid "$W/log" | head -3)"
grep -q '^160 120 i420 30' "$W/log" && ok "a mount of it reads the directory (fmt)" || bad "fmt"
grep -q '^CMP-$' "$W/log" && ok "every frame byte for byte as the direct mount" || bad "$(grep CMP- "$W/log")"
grep -q '^TWO-B-$' "$W/log" && grep -q '^TWO-C-$' "$W/log" && ok "two connections read at once" || bad "two: $(grep TWO- "$W/log" | tr '\n' ' ')"
grep -q '^NOTDIR-..*' "$W/log" && ok "a directory that is not one refused" || bad "notdir: $(grep NOTDIR "$W/log")"
grep -q '^TAKEN-..*' "$W/log" && ok "a spec taken refused" || bad "taken: $(grep TAKEN "$W/log")"
grep -q '^NEWMOUNT-..*' "$W/log" && ok "killed: no new connection" || bad "killed: $(grep NEWMOUNT "$W/log")"
grep -q '^STILL-..*' "$W/log" && ok "killed: its connections end with it" || bad "still: $(grep STILL "$W/log")"
echo "times (direct, posted): $(sed -n '/^-- times/,/^-- killed/p' "$W/log" | grep -o '[0-9.]*r' | tr '\n' ' ')"
exit $fail
