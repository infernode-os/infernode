#!/dis/sh.dis
#
# wm/page driven by keys and the pointer (/dev/keyboard, /dev/pointer).
# At each step it writes the page shown as an image (W) to
# /tmp/page-NAME.bit; tests/host/page_test.sh compares them (not a test:
# the runner runs every script in tests/inferno).  It also prints R and
# the windows wm/wm lists, after a page is quit.
#
load std expr

# a key: a character, or a key of its own as unicode(1) gives it (hex)
fn key { for c in $* { echo -n $c > /dev/keyboard; sleep 1 } }
fn special { unicode -t $1 > /dev/keyboard; sleep 1 }
fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn write { echo W/tmp/page-$1.bit > /dev/keyboard; sleep 2 }
# the middle of the topmost window (the page's)
fn middle {
	w = `{cat /chan/wmwindows}
	x = ${expr ${index 2 $w} ${index 4 $w} + 2 /}
	y = ${expr ${index 3 $w} ${index 5 $w} + 2 /}
}

Home=e010
End=e011

# one file
wm/page /tests/page/three.pdf &
sleep 6
write 1
key n;	write n		# n: the next page
key p;	write p		# p: the one before
special $End;	write end
special $Home;	write home
echo g2 > /dev/keyboard; sleep 1
write g2			# g 2: go to page 2
special $Home
key w;	write fw	# w: fit the width
key f;	write fp	# f: fit the page
key w
key +;	write zin		# +: zoom in
key -;	write zout		# -: zoom out
key r;	write r		# r: turned right
key R;	write rl		# R: and back
key R;	write l		# R: turned left
key r

# the pointer: the wheel scrolls, button 1 drags, from page 1
special $Home
middle
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 {
	ptr $x $y 16; ptr $x $y 0
}
sleep 1;	write wheel
special $Home
ptr $x ${expr $y 250 +} 1
ptr $x ${expr $y 250 -} 1
ptr $x ${expr $y 250 -} 0
ptr $x ${expr $y 250 +} 1
ptr $x ${expr $y 250 -} 1
ptr $x ${expr $y 250 -} 0
sleep 1;	write drag
special $Home
key ' ' ' ';	write space	# space: a screen on, twice

# button 2 held: the operations, released on the first, next page
special $Home
ptr $x $y 2
sleep 1
ptr ${expr $x 30 +} ${expr $y 10 +} 2
ptr ${expr $x 30 +} ${expr $y 10 +} 0
sleep 1;	write menu
# button 3 held: the pages, released on the third (items are 18 apart)
special $Home
ptr $x $y 4
sleep 1
ptr ${expr $x 30 +} ${expr $y 46 +} 4
ptr ${expr $x 30 +} ${expr $y 46 +} 0
sleep 1;	write pages

key q				# q: quit
sleep 2
echo R quit `{cat /chan/wmwindows}

# two files, one document: on from the first into the second, and back
wm/page /tests/page/three.pdf /tests/page/three.pdf &
sleep 6
key n n n;	write two-n3	# page 1 of the second
key p;	write two-p	# page 3 of the first
special $End;	write two-end
key q
sleep 2

# standard input
cat /tests/page/three.pdf | wm/page &
sleep 6
write stdin
key q
sleep 2

# links (tests/page/links.pdf, at 160% its link to example.com is at
# 200 300, to page 2 at 200 465, by name at 200 590 in the window):
# button 1 clicked on one to a page goes to it; one to a URI is plumbed,
# to a plumber whose one rule sends web addresses to the port web, read
# into /tmp/page-plumbed
bind -bc '#splumber' /chan
echo 'kind is text
data matches ''https?://.*''
plumb to web' > /tmp/page-plumbing
plumber /tmp/page-plumbing &
sleep 1
plumb -s web -d plumb start
{ cat /chan/plumb.web > /tmp/page-plumbed >[2] /dev/null } &
fn click { ptr $1 $2 1; ptr $1 $2 0 }
wm/page /tests/page/links.pdf &
sleep 6
write link-1
key n;	write link-2	# n: page 2
special $Home
click 200 465
sleep 1;	write link-dest
special $Home
click 200 590
sleep 1;	write link-named
special $Home
click 200 300
sleep 2;	write link-uri
key q
sleep 2

# Markdown and HTML: each shown, as a sheet of its own
wm/page /tests/render/doc.md &
sleep 6
write md
key q
sleep 2
wm/page /tests/charon/browser/form.html &
sleep 6
write html
key q
sleep 2

echo R done
echo halt > '#c/sysctl'
