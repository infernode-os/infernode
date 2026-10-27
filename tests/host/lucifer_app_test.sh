#!/bin/sh
#
# lucifer_app_test.sh — every program in dis/wm opened in Lucifer's
# presentation zone, one boot, one after another: it is still running a
# moment later (Lucifer did not reap it), it drew in the zone, below its
# tab (wm/deb, hung making its second window, showed only its tab), its
# content fills the zone or is centred in it (not in a corner: wm/lens
# drew a 300x300 image in the zone's top left), it follows a theme
# switch, and wm/editor and wm/shell take a click and typing through
# /dev/pointer and /dev/keyboard.  The zone is found from the
# screenshots: what the apps changed against the empty zone, together.
#
# The tab above the app is not checked: on some boots Lucifer draws no
# tab strip at all, for any app, a fault of its own to be fixed first.
#
# The programs are found in dis/wm (wmprogs.sh), as wm_size_test.sh
# finds them.  LUCIFER_APPS="lens tetris" opens those alone (with
# wm/editor among them, which fills the zone).
#
set -e
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/wmprogs.sh"
set -u
progs=${LUCIFER_APPS:-$(wmprogs)}

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/wm.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

# A home of its own: the profile binds $home/tmp over /tmp, where the
# driver and the screenshots are, and keeps the theme switched to under
# $home/.infernode, not in the tree.
H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/tmp"

# where a click and typing go: inside the zone at 1280x800 (checked
# below against the zone the screenshots show)
CX=670 CY=400

ui=/mnt/ui/activity/0/presentation/ctl
theme=brimstone
{
	echo 'load std'
	echo 'sleep 2'
	# the empty zone in each theme, what an app's screenshot is held to
	echo 'scap /tmp/empty_brimstone.img'
	echo "echo -n halo > /lib/lucifer/theme/current"
	echo 'sleep 5'
	echo 'scap /tmp/empty_halo.img'
	echo "echo -n brimstone > /lib/lucifer/theme/current"
	echo 'sleep 5'
	for p in $progs; do
		h=$(wmprog_how "$p")
		case $h in
		-*)	continue ;;
		esac
		set -- $h
		shift
		data=
		[ $# -gt 0 ] && data=" data=$*"
		echo "echo 'create id=$p type=app label=$p dis=/dis/wm/$p.dis$data' > $ui"
		echo "echo 'center id=$p' > $ui"
		echo 'sleep 6'
		echo "scap /tmp/a_$p.img"
		echo "echo R $p $theme \`{cat /mnt/ui/activity/0/presentation/$p/appstatus} > '#c/cons'"
		case $p in
		editor|shell)
			echo "echo m $CX $CY 1 > /dev/pointer; echo m $CX $CY 0 > /dev/pointer"
			echo 'sleep 1'
			echo "echo -n 'typed in Lucifer' > /dev/keyboard"
			echo 'sleep 2'
			echo "scap /tmp/i_$p.img" ;;
		esac
		if [ $theme = brimstone ]; then theme=halo; else theme=brimstone; fi
		echo "echo -n $theme > /lib/lucifer/theme/current"
		echo 'sleep 5'
		echo "scap /tmp/b_$p.img"
		echo "echo 'kill id=$p' > $ui"
		echo 'sleep 2'
	done
	echo "echo R done > '#c/cons'"
	echo 'echo halt > /dev/sysctl'
} > "$H/tmp/drv.sh"

for p in $progs; do
	case $(wmprog_how "$p") in
	-*)	echo "SKIP: wm/$p:$(wmprog_how "$p" | sed 's/^-//')" ;;
	esac
done

LOG=$H/log
cd "$ROOT"
SDL_VIDEODRIVER=dummy HOME=$H with_timeout 900 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; run /tmp/drv.sh" \
	</dev/null >"$LOG" 2>&1 || true

grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; tail -20 "$LOG"; exit 1; }

python3 -I - "$ROOT" "$H" "$CX" "$CY" <<'PY'
import sys, os, re
root, H, cx, cy = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P

def theme(n):
    d = {}
    for l in open(os.path.join(root, 'lib/lucifer/theme', n)):
        m = re.match(r'(\w+)\s+([0-9A-Fa-f]{6})', l)
        if m:
            d[m.group(1)] = m.group(2).upper()
    return d
TH = {'brimstone': theme('brimstone'), 'halo': theme('halo')}
OTHER = {'brimstone': 'halo', 'halo': 'brimstone'}

S = 2	# every other pixel, both ways
TABH = 32	# the tab strip's rows, at the top of the zone, and some
EMPTY = {t: P.load(os.path.join(H, 'tmp/empty_%s.img' % t)) for t in TH}
E = EMPTY['brimstone']
apps = []
for l in open(os.path.join(H, 'log'), errors='replace'):
    f = l.split()
    if len(f) >= 3 and f[0] == 'R' and f[1] != 'done':
        apps.append((f[1], f[2], ' '.join(f[3:])))

def changed(im, ref, r):
    x0, y0, x1, y1 = r; n = 0; b = None
    for y in range(y0, y1, S):
        for x in range(x0, x1, S):
            if im.px(x, y) != ref.px(x, y):
                n += 1
                b = [x, y, x, y] if b is None else [min(b[0], x), min(b[1], y), max(b[2], x), max(b[3], y)]
    return n, b

shots = {}
whole = (0, 0, E.w, E.h)
boxes = []
for name, th, st in apps:
    a = os.path.join(H, 'tmp/a_%s.img' % name)
    if not os.path.exists(a):
        continue
    im = P.load(a)
    n, b = changed(im, EMPTY[th], whole)
    shots[name] = (im, n, b)
    if b is not None:
        boxes.append(b)
# the zone: all the apps drew, together (an app that fills it, as
# wm/editor does, is enough)
if not boxes:
    print('FAIL: no app drew anything'); sys.exit(1)
zone = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes) + S, max(b[3] for b in boxes) + S)
zw = zone[2] - zone[0]; zcx = (zone[0] + zone[2]) / 2
print('zone %d %d %d %d' % zone)
failed = 0
def fail(m):
    global failed
    print('FAIL: ' + m); failed = 1
if not (zone[0] <= cx < zone[2] and zone[1] <= cy < zone[3]):
    fail('the click at %d %d is outside the zone; move CX CY' % (cx, cy))

# Content, not chrome, over most of the zone: a photograph, an image, a
# fractal, a document's page, a web page.  Its colours are its own, and a
# theme switch leaves them, though some match a theme's by chance (the
# white of a page is halo's).  about's picture changes with the theme,
# as it should, and is checked.
PICTURE = {'coffee', 'view', 'fractals', 'page', 'charon'}

for name, th, st in apps:
    what = 'wm/' + name
    if st != 'running':
        fail('%s: not running a moment after it was opened (status %r): Lucifer took it for ended' % (what, st)); continue
    if name not in shots:
        fail('%s: no screenshot' % what); continue
    im, n, b = shots[name]
    if n < 20 or b is None:
        fail('%s: drew nothing in the zone' % what); continue
    # Drawn below the tab strip, not just a tab over an empty zone:
    # wm/deb, hung before its window went on screen, passed as drawn
    # (its tab's label) and as following the theme (the empty zone's
    # colours).  More than one colour there, past a speck.
    cnt = {}
    for y in range(zone[1] + TABH, zone[3], 3):
        for x in range(zone[0], zone[2], 3):
            px = im.px(x, y)
            cnt[px] = cnt.get(px, 0) + 1
    tot = sum(cnt.values())
    if tot == 0 or (tot - max(cnt.values())) * 200 < tot:
        fail('%s: nothing drawn below its tab' % what); continue
    # Where it drew, below the tab strip (an app's tab label, when the
    # strip is drawn, spans more of it than the app might): what differs
    # from the empty zone, or changes with the theme.  A background the
    # colour of the empty zone (wm/editor's, in brimstone) differs from
    # nothing, but changes with the theme; what an app never drew keeps
    # the colour Lucifer filled its window with (wm/lens's, beside its
    # 300x300 image).
    below = (zone[0], zone[1] + TABH, zone[2], zone[3])
    boxes2 = [changed(im, EMPTY[th], below)[1]]
    bi = os.path.join(H, 'tmp/b_%s.img' % name)
    imb = P.load(bi) if os.path.exists(bi) else None
    if imb is not None:
        boxes2.append(changed(imb, im, below)[1])
    boxes2 = [x for x in boxes2 if x is not None] or [b]
    c = [min(x[0] for x in boxes2), min(x[1] for x in boxes2), max(x[2] for x in boxes2), max(x[3] for x in boxes2)]
    bw = c[2] - c[0]; bcx = (c[0] + c[2]) / 2
    if bw < 0.9 * zw and abs(bcx - zcx) > 0.1 * zw:
        fail('%s: its content is in a corner of the zone (x %d to %d of %d to %d)' % (what, c[0], c[2], zone[0], zone[2])); continue
    msg = []
    if name not in PICTURE and imb is not None:
        old = set(TH[th].values()) - set(TH[OTHER[th]].values())
        tot = stale = 0
        for y in range(zone[1], zone[3], 3):
            for x in range(zone[0], zone[2], 3):
                tot += 1
                stale += imb.px(x, y) in old
        if stale * 100 > 2 * tot:
            fail('%s: %d%% of the zone still in %s colours after the switch to %s' % (what, stale * 100 // tot, th, OTHER[th])); continue
        msg.append('follows the theme')
    if name == 'deb':
        # Its Stack window is a second toplevel: the tab is divided for
        # it, not covered, a line across the zone between the main
        # window above and the Stack below, in either theme.
        def divider(img, t):
            xs = range(zone[0] + 2, zone[2] - 2, 4)
            for y in range(zone[1] + (zone[3] - zone[1]) // 4, zone[3] - 20):
                if sum(img.px(x, y) == TH[t]['border'] for x in xs) * 100 >= 95 * len(xs):
                    return y
            return None
        if divider(im, th) is None or (imb is not None and divider(imb, OTHER[th]) is None):
            fail('%s: its tab is not divided for its Stack window' % what); continue
        msg.append('divided for its Stack window')
    ii = os.path.join(H, 'tmp/i_%s.img' % name)
    if os.path.exists(ii):
        n2, _ = changed(P.load(ii), im, zone)
        if n2 < 20:
            fail('%s: a click and typing changed nothing' % what); continue
        msg.append('takes typing')
    print('PASS: %s (%s)' % (what, ', '.join(['running', 'drawn'] + msg)))
if failed == 0:
    print('ALL PASS')
sys.exit(failed)
PY
