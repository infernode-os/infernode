#!/bin/sh
#
# tests/host/dp9ik_live_test.sh
#
# InferNode's rimport(1) and rcpu(1) against 9front itself: 9front 11952's
# own image under QEMU (tests/host/dp9ik/nine.py), made a cpu and auth
# server, glenda's password glendapass9f, its rcpu and ticket services on
# the host's loopback.  From InferNode, with a dp9ik key in factotum:
# rimport mounts 9front's root (read; written and read back; a binary
# copied), rcpu runs a command with the remote's exit status coming back,
# input piped through, -d, an interactive rc fed on its input, and the far
# end's /mnt/term is the tree rcpu serves and nothing more, in which it
# can make nothing, and rcpu leaves nothing behind; a wrong password is
# refused.  Times are printed.
#
# Opt-in: it needs QEMU and 9front's image (258 MB).  Set NINEFRONT_IMAGE
# to a provisioned image (nine.py provision), or NINEFRONT=1 to fetch the
# release by its SHA-256 into $NINEFRONT_CACHE (default $ROOT/tmp/9front)
# and provision it there once (about fifteen minutes under TCG).
# Skips (exit 77) otherwise.
#
. "$(dirname "$0")/common.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
URL=https://9front.org/iso/9front-11952.amd64.qcow2.gz
SHA=3c1b57c4b609525e76cb0abac48bc657f71187fd3506674dba4e49b42141729c
RCPU=${NINEFRONT_RCPU_PORT:-17019}
AUTH=${NINEFRONT_AUTH_PORT:-15567}

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
[ -f "$ROOT/dis/rcpu.dis" ] || { echo "SKIP: dis/rcpu.dis not built"; exit 77; }

img=$NINEFRONT_IMAGE
if [ -z "$img" ]; then
	[ "$NINEFRONT" = 1 ] || { echo "SKIP: set NINEFRONT_IMAGE, or NINEFRONT=1 to fetch and provision 9front"; exit 77; }
	cache=${NINEFRONT_CACHE:-$ROOT/tmp/9front}
	mkdir -p "$cache"
	img=$cache/9front-dp9ik.qcow2
	if [ ! -f "$img" ]; then
		if [ ! -f "$cache/9front.qcow2" ]; then
			curl -fsSL -o "$cache/9front.qcow2.gz" "$URL" || { echo "FAIL: cannot fetch $URL"; exit 1; }
			echo "$SHA  $cache/9front.qcow2.gz" | sha256sum -c - >/dev/null || { echo "FAIL: $URL is not the image pinned"; exit 1; }
			gunzip -f "$cache/9front.qcow2.gz"
		fi
		echo "provisioning 9front (once)..."
		NINE_LOG=$cache/provision.log python3 "$HERE/dp9ik/nine.py" provision "$cache/9front.qcow2" "$img.new" ||
			{ echo "FAIL: provisioning; see $cache/provision.log"; exit 1; }
		mv "$img.new" "$img"
	fi
fi

work=$(mktemp -d)
trap 'exec 3>&-; kill $vmpid 2>/dev/null; wait $vmpid 2>/dev/null; rm -rf "$work"' EXIT
mkfifo "$work/in"
python3 "$HERE/dp9ik/nine.py" serve "$img" "$RCPU" "$AUTH" < "$work/in" > "$work/vm.out" 2>&1 &
vmpid=$!
exec 3> "$work/in"
t0=$(date +%s)
until grep -q READY "$work/vm.out"; do
	kill -0 $vmpid 2>/dev/null || { echo "FAIL: 9front did not boot:"; tail -20 "$work/vm.out"; exit 1; }
	sleep 2
done
echo "9front up in $(( $(date +%s) - t0 ))s"

mkdir -p "$ROOT/tmp"
s=$ROOT/tmp/dp9ik_live.sh
cat > "$s" <<EOF
load std
echo '=before' \`{ls /tmp | grep rcpu | wc -l}
auth/factotum
echo 'key proto=dp9ik dom=9front user=glenda !password=glendapass9f auth=tcp!127.0.0.1!$AUTH' > /mnt/factotum/ctl
mkdir -p /tmp/9f
echo '=rimport'; time rimport tcp!127.0.0.1!$RCPU / /tmp/9f; echo 'rimport status' \$status
echo '=sysname' \`{cat /tmp/9f/dev/sysname}
echo '=user' \`{cat /tmp/9f/dev/user}
echo hello from infernode > /tmp/9f/tmp/frominfernode
echo '=readback' \`{cat /tmp/9f/tmp/frominfernode}
echo '=copy'; time cp /tmp/9f/amd64/bin/rc /tmp/rc.9f; ls -l /tmp/rc.9f
echo '=rcpu'; time rcpu -h tcp!127.0.0.1!$RCPU -c 'echo remote \$sysname \$user; cat /tmp/frominfernode; ls /mnt/term /mnt/term/fd'
echo '=stdin'; echo piped through | rcpu -h tcp!127.0.0.1!$RCPU -c 'tr a-z A-Z'
echo '=dir'; rcpu -h tcp!127.0.0.1!$RCPU -d /sys/src -c pwd
echo '=interactive'; {echo 'echo interactive \$service'; echo exit} | rcpu -h tcp!127.0.0.1!$RCPU
echo '=exit'; rcpu -h tcp!127.0.0.1!$RCPU -c 'exit oops'; echo 'exit status' \$status
echo '=create'; rcpu -h tcp!127.0.0.1!$RCPU -c 'echo x > /mnt/term/evil'
rcpu -h tcp!127.0.0.1!$RCPU -c 'mkdir /mnt/term/mnt/d'
echo '=left' \`{ls /tmp | grep rcpu | wc -l}
echo 'delkey proto=dp9ik' > /mnt/factotum/ctl
echo 'key proto=dp9ik dom=9front user=glenda !password=wrong auth=tcp!127.0.0.1!$AUTH' > /mnt/factotum/ctl
mkdir -p /tmp/9g
echo '=wrong'; rimport tcp!127.0.0.1!$RCPU / /tmp/9g; echo 'wrong status' \$status
echo '=done'; echo halt > /dev/sysctl
EOF
out=$(SDL_VIDEODRIVER=dummy with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/dp9ik_live.sh 2>&1 < /dev/null)
rm -f "$s"

rc=0
check() {
	if echo "$out" | grep -q -- "$1"; then echo "PASS: $2"; else echo "FAIL: $2"; rc=1; fi
}
check '^rimport status $' "rimport mounts 9front's root"
check '^=sysname cirno$' "a 9front file read"
check '^=user glenda$' "as the key's user"
check '^=readback hello from infernode$' "a file written and read back"
check '160302 .*rc.9f' "a binary copied whole"
check '^remote cirno glenda$' "rcpu runs a command"
check '^hello from infernode$' "on the machine written to"
check '^/mnt/term/fd/10' "the far end's /mnt/term is rcpu's tree"
check '^PIPED THROUGH$' "rcpu's input piped through"
check '^/sys/src$' "rcpu -d"
check 'interactive cpu' "an interactive rc"
check '^exit status .*oops' "the remote's exit status"
check '^rimport: .*wrong password' "a wrong password refused"
check "can't create: /mnt/term/evil: permission denied" "the far end makes no file in rcpu's tree"
check "can't create /mnt/term/mnt/d: permission denied" "nor a directory"
before=$(echo "$out" | sed -n 's/^=before *//p')
check "^=left *${before:-0}\$" "and rcpu leaves no scratch tree behind"
if echo "$out" | grep -q "^/mnt/term/\(bin\|dis\|usr\|n\|net\)"; then echo "FAIL: more than rcpu's tree served"; rc=1; fi
echo "$out" | awk '/^=/{w=$1} /^[0-9.]+l [0-9.]+r [0-9.]+t$/{print "\ttime " w ": " $2}'
[ $rc = 0 ] || echo "$out" | grep -v '^fs: ' | head -60

# The graphical half (#1270): rcpu under wm/wm, 9front's programs in
# windows here (tests/rcpu/drive.sh), the pictures checked by pixel.
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: graphics: $EMU is a headless build and has no display"
	exit $rc
fi
G=tmp/dp9ik_live_gfx.$$
mkdir -p "$ROOT/$G"
trap 'exec 3>&-; kill $vmpid 2>/dev/null; wait $vmpid 2>/dev/null; rm -rf "$work" "$ROOT/$G"' EXIT
(cd "$ROOT"; SDL_VIDEODRIVER=dummy with_timeout 240 "$EMU" -c1 -pheap=512m -pimage=512m -g1024x768 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$G /tmp; wm/wm sh /tests/rcpu/drive.sh tcp!127.0.0.1!$RCPU tcp!127.0.0.1!$AUTH" \
	</dev/null >"$ROOT/$G/log" 2>&1) || true
step() { sed -n "s/^R $1 *//p" "$ROOT/$G/log" | head -1; }
gcheck() {
	if [ "$1" = 1 ]; then echo "PASS: $2"; else echo "FAIL: $2"; rc=1; fi
}
yes() { if "$@"; then echo 1; else echo 0; fi; }
has() { python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1])
from p9img2png import load
im = load(sys.argv[2])
want = set(sys.argv[3:])
seen = set(im.px(x, y) for x in range(0, im.w, 2) for y in range(0, im.h, 2))
sys.exit(0 if want <= seen else 1)' "$ROOT/tools" "$@"; }

gcheck $(yes grep -q '^R done' "$ROOT/$G/log") "the graphical driver finished"
gcheck $(yes [ "$(step text)" = "0 text only" ]) "a command that draws nothing gets no window"
view=$(step view)
gcheck $(yes [ "${view% * *}" = "cons consctl cursor draw kbd label mouse snarf winname" ]) \
	"the far end has rcpu's display files"
gcheck $(yes [ "${view#* * * * * * * * * }" = "1 1" ]) "and its draw lists no client of this machine's, nor screen"
gcheck $(yes [ "$(step keywin)" = 1 ]) "a window for a program that asks"
gcheck $(yes [ "$(step keys)" = "keys hello" ]) "keys typed in the window reach it (cons, raw)"
case "$(step mouse)" in
"mouse m "*)	gcheck 1 "and the pointer (mouse)" ;;
*)		gcheck 0 "and the pointer (mouse)" ;;
esac
gcheck $(yes [ "$(step keysdone)" = 0 ]) "its window gone when it is"
gcheck $(yes [ "$(step colors | cut -d' ' -f1)" = 1 ]) "colors has a window"
gcheck $(yes has "$ROOT/$G/colors.img" FFFF00 FF0000) "colors drawn in it (its yellow and red, by pixel)"
gcheck $(yes [ "$(step colorsgone)" = 0 ]) "the window gone with colors"
gcheck $(yes [ "$(step rio | cut -d' ' -f1)" = 1 ]) "rio has a window"
gcheck $(yes has "$ROOT/$G/rio.img" 55AAAA FFFF00) "rio drawn in it, colors in a rio window (by pixel)"
gcheck $(yes [ "$(step riogone)" = 0 ]) "the window gone with rio"
gcheck $(yes [ -z "$(ls "$ROOT/$G" | grep rcpu)" ]) "no scratch tree left by the graphical sessions"
[ $rc = 0 ] || sed -n '1,40p' "$ROOT/$G/log"
exit $rc
