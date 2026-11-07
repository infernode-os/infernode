#!/bin/sh
#
# wm/osk at the sizes of the screens it is for -- the Raspberry Pi's 7"
# panel (800x480), a laptop's (1280x800), a phone's and a tablet's held
# upright (720x1280, 1536x2048) -- on QWERTY, Dvorak and Colemak
# (tests/osk/sizes.sh): docked along the bottom across the screen's
# width, at most half its height; every key on the screen, in the
# keyboard, none overlapping another; every letter's key at least a
# twelfth of the screen wide and 30 pixels tall.  Needs the SDL
# emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/osk.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
cd "$ROOT"
for g in 800x480 1280x800 720x1280 1536x2048; do
	W=${g%x*}
	H=${g#*x}
	T=tmp/osk_sizes_test.$$.$g
	mkdir -p "$ROOT/$T"
	SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g$g -r"$ROOT" \
		/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/osk/sizes.sh" \
		</dev/null >"$ROOT/$T/log" 2>&1 || true
	if ! grep -q '^R done' "$ROOT/$T/log"; then
		fail "$g: did not finish"
		rm -rf "$ROOT/$T"
		continue
	fi
	h=$(sed -n 's/^height //p' "$ROOT/$T/status")
	if [ -n "$h" ] && [ "$h" -gt 0 ] && [ $((h * 2)) -le "$H" ]; then
		pass "$g: $h pixels high"
	else
		fail "$g: height '$h' of $H"
	fi
	set -- $(head -1 "$ROOT/$T/windows")
	[ "$2" = 0 ] && [ "$4" = "$W" ] && [ "$5" = "$H" ] && pass "$g: docked across the bottom" ||
		fail "$g: window $*"
	for l in qwerty dvorak colemak; do
		r=$(awk -v W="$W" -v H="$H" -v h="${h:-0}" '
			NF == 5 { n++; x0[n]=$2; y0[n]=$3; x1[n]=$4; y1[n]=$5; name[n]=$1 }
			END {
				if(n < 30){ print "only " n " keys"; exit }
				for(i = 1; i <= n; i++){
					if(x0[i] < 0 || x1[i] > W || y0[i] < H-h || y1[i] > H){ print name[i] " off the keyboard"; exit }
					if(length(name[i]) == 1 && name[i] ~ /[a-z]/ && (x1[i]-x0[i] < W/12 || y1[i]-y0[i] < 30)){ print name[i] " " x1[i]-x0[i] "x" y1[i]-y0[i]; exit }
					for(j = i+1; j <= n; j++)
						if(x0[i] < x1[j] && x0[j] < x1[i] && y0[i] < y1[j] && y0[j] < y1[i]){ print name[i] " over " name[j]; exit }
				}
				print "ok"
			}' "$ROOT/$T/keys.$l")
		[ "$r" = ok ] && pass "$g $l: keys on the screen, apart, big enough" || fail "$g $l: $r"
	done
	rm -rf "$ROOT/$T"
done
[ $failed -eq 0 ] && echo "ALL PASS"
exit $failed
