#!/dis/sh.dis
#
# wm/dir driven by the pointer (/dev/pointer) on the tree in $1 (made by
# tests/host/wm_dir_test.sh, which checks what this prints and the
# screenshots it takes; not a test: the runner runs every script in
# tests/inferno).  After each step it prints R, the step's name and the
# windows wm/wm lists (/chan/wmwindows: id minx miny maxx maxy, topmost
# first), and writes the screen to $1/NAME.img.
#
# The tree is .., README, notes.md and sub, so the icons are in five
# cells of 92 pixels (notes.md the widest name, in Inferno's own
# font), their glyphs' centres at x 50, 142, 234 and 326 and y 46 in
# the window, which wm/wm puts first at 0 0.
#
load std expr

d=$1
fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn dclick { ptr $1 $2 0; sleep 0; ptr $1 $2 1; ptr $1 $2 0; ptr $1 $2 1; ptr $1 $2 0; sleep 2 }
fn show { sleep 1; echo R $1 `{cat /chan/wmwindows}; scap $d/$1.img }

# no plumber
wm/dir $d/tree &
sleep 5
show start

# sub, opened: in this window
dclick 326 46
show walked

# .., back up
dclick 50 46
show back

# README with no plumber: wm/edit opens it
dclick 142 46
sleep 3
show edit

# with a plumber whose one rule sends any text to the port open, read
# into $d/plumbed: a second wm/dir plumbs notes.md
bind -bc '#splumber' /chan
echo 'kind is text
data matches ''.*''
plumb to open' > $d/plumbing
plumber $d/plumbing &
sleep 1
plumb -s open -d plumb start
{ cat /chan/plumb.open > $d/plumbed >[2] /dev/null } &
wm/dir $d/tree &
sleep 5
w = `{cat /chan/wmwindows}
x = ${expr ${index 2 $w} 234 +}
y = ${expr ${index 3 $w} 46 +}
dclick $x $y
sleep 2
show plumbed
echo R done
