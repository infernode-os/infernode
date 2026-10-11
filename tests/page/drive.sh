#!/dis/sh.dis
#
# wm/page driven by keys and the pointer (/chan/uitest, under wm/wm).
# At each step it writes the page shown as an image (W) to
# /tmp/page-NAME.bit; tests/host/page_test.sh compares them (not a test:
# the runner runs every script in tests/inferno).  It also prints R and
# the windows wm/wm lists, after a page is quit.
#
load std expr

fn key { for c in $* { echo key $c > /chan/uitest; sleep 1 } }
fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
fn write { echo key 87 > /chan/uitest; echo text /tmp/page-$1.bit > /chan/uitest; key 10; sleep 1 }
# the middle of the topmost window (the page's)
fn middle {
	w = `{cat /chan/uitest}
	x = ${expr ${index 2 $w} ${index 4 $w} + 2 /}
	y = ${expr ${index 3 $w} ${index 5 $w} + 2 /}
}

Home=57360
End=57361

# one file
wm/page /tests/page/three.pdf &
sleep 6
write 1
key 110;	write n		# n: the next page
key 112;	write p		# p: the one before
key $End;	write end
key $Home;	write home
echo key 103 > /chan/uitest; echo text 2 > /chan/uitest; key 10
write g2			# g 2: go to page 2
key $Home
key 119;	write fw	# w: fit the width
key 102;	write fp	# f: fit the page
key 119
key 43;	write zin		# +: zoom in
key 45;	write zout		# -: zoom out
key 114;	write r		# r: turned right
key 82;	write rl		# R: and back
key 82;	write l		# R: turned left
key 114

# the pointer: the wheel scrolls, button 1 drags, from page 1
key $Home
middle
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 {
	ptr $x $y 16; ptr $x $y 0
}
sleep 1;	write wheel
key $Home
ptr $x ${expr $y 250 +} 1
ptr $x ${expr $y 250 -} 1
ptr $x ${expr $y 250 -} 0
ptr $x ${expr $y 250 +} 1
ptr $x ${expr $y 250 -} 1
ptr $x ${expr $y 250 -} 0
sleep 1;	write drag
key $Home
key 32 32;	write space	# space: a screen on, twice

# button 2 held: the operations, released on the first, next page
key $Home
ptr $x $y 2
sleep 1
ptr ${expr $x 30 +} ${expr $y 10 +} 2
ptr ${expr $x 30 +} ${expr $y 10 +} 0
sleep 1;	write menu
# button 3 held: the pages, released on the third (items are 18 apart)
key $Home
ptr $x $y 4
sleep 1
ptr ${expr $x 30 +} ${expr $y 46 +} 4
ptr ${expr $x 30 +} ${expr $y 46 +} 0
sleep 1;	write pages

key 113				# q: quit
sleep 2
echo R quit `{cat /chan/uitest}

# two files, one document: on from the first into the second, and back
wm/page /tests/page/three.pdf /tests/page/three.pdf &
sleep 6
key 110 110 110;	write two-n3	# page 1 of the second
key 112;	write two-p	# page 3 of the first
key $End;	write two-end
key 113
sleep 2

# standard input
cat /tests/page/three.pdf | wm/page &
sleep 6
write stdin
key 113
sleep 2

# Markdown and HTML: each shown, as a sheet of its own
wm/page /tests/render/doc.md &
sleep 6
write md
key 113
sleep 2
wm/page /tests/charon/browser/form.html &
sleep 6
write html
key 113
sleep 2

echo R done
echo halt > '#c/sysctl'
