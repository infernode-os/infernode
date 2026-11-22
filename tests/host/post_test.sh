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
#   - a directory that is not one refused; a spec taken refused; no spec
#     (a post nobody could reach) refused
#   - post's group killed (kill -g, by its pid): the posted file gone and
#     its connections with it (#s relays them through post)
#   - post -r (Sys->EXPREADONLY): a mount of it reads the directory and
#     is refused a write, a create, a mkdir and a remove, the directory
#     as it was; the same directory posted without -r is written to
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
post '' /mnt/a; echo NOSPEC-\$status
echo '-- times'; time cat /mnt/a/0/frame > /dev/null; time cat /mnt/b/0/frame > /dev/null
echo '-- killed'; kill -g \$postpid; sleep 1
mkdir -p /mnt/d; mount -A '#s$S/fs' /mnt/d; echo NEWMOUNT-\$status
cmp /mnt/a/0/frame /mnt/b/0/frame; echo STILL-\$status
echo '-- readonly'; mkdir -p $E/d /mnt/r /mnt/w; echo kept > $E/d/f
post -r ${S}r $E/d &
sleep 1
mount -Ac '#s${S}r/fs' /mnt/r
echo -n RO-READ-; cat /mnt/r/f
sh -c 'echo changed > /mnt/r/f'; echo RO-WRITE-\$status
sh -c 'echo new > /mnt/r/new'; echo RO-CREATE-\$status
mkdir /mnt/r/dir; echo RO-MKDIR-\$status
rm /mnt/r/f; echo RO-REMOVE-\$status
echo -n RO-AFTER-; cat $E/d/f; echo -n RO-LS-; ls $E/d
post -x ${S}x $E/d; echo BADOPT-\$status
post ${S}w $E/d &
sleep 1
mount -Ac '#s${S}w/fs' /mnt/w
sh -c 'echo changed > /mnt/w/f'; echo RW-WRITE-\$status
echo -n RW-AFTER-; cat $E/d/f
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
grep -q '^NOSPEC-..*' "$W/log" && ok "no spec refused" || bad "nospec: $(grep NOSPEC "$W/log")"
grep -q '^NEWMOUNT-..*' "$W/log" && ok "killed: no new connection" || bad "killed: $(grep NEWMOUNT "$W/log")"
grep -q '^STILL-..*' "$W/log" && ok "killed: its connections end with it" || bad "still: $(grep STILL "$W/log")"
grep -q '^RO-READ-kept$' "$W/log" && ok "post -r: a mount reads the directory" || bad "ro read: $(grep RO-READ "$W/log")"
for what in WRITE CREATE MKDIR REMOVE; do
	grep -q "^RO-$what-..*" "$W/log" && ok "post -r: $what refused" || bad "ro $what: $(grep "RO-$what" "$W/log")"
done
grep -q 'file system read only' "$W/log" && ok "post -r: the refusal says the file system is read only" || bad "ro: no reason given"
grep -q '^RO-AFTER-kept$' "$W/log" && grep -q "^RO-LS-$E/d/f\$" "$W/log" && ok "post -r: the directory is as it was" || bad "ro after: $(grep 'RO-AFTER\|RO-LS' "$W/log" | tr '\n' ' ')"
grep -q '^BADOPT-..*' "$W/log" && ok "an option that is none refused" || bad "badopt: $(grep BADOPT "$W/log")"
grep -q '^RW-WRITE-$' "$W/log" && grep -q '^RW-AFTER-changed$' "$W/log" && ok "the same directory posted without -r is written to" || bad "rw: $(grep '^RW-' "$W/log" | tr '\n' ' ')"
echo "times (direct, posted): $(sed -n '/^-- times/,/^-- killed/p' "$W/log" | grep -o '[0-9.]*r' | tr '\n' ' ')"
exit $fail
