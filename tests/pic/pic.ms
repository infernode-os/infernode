.\" pic(1)'s test: pictures of most kinds; pic.out is Plan 9 pic's output
.PP
Boxes, an ellipse, arrows and text:
.PS
box "Reader"
arrow
ellipse "Text"
arrow
box "Meaning"
arrow from 2nd box.s down 0.4 then right 1.5 then up 0.4
"interpretation" at last arrow.c below
.PE
Circles, arcs, splines, dashes, dots and fills:
.PS 3
C: circle rad 0.3 fill 0.3
arc cw from C.e to C.s ->
spline right 1 then up 0.5 then right 0.5 dashed
line from C.n up 0.5 dotted
box wid 0.5 ht 0.25 with .sw at C.ne + (0.2, 0.1) invis "invisible" ljust
ellipse wid 0.4 ht 0.2 at last box.e fill
arrow <-> from 1st circle.w left 0.5 chop 0.05
.PE
Blocks, places, variables, loops, conditions, macros:
.PS
boxwid = 0.4; boxht = 0.3
define pair { box $1; box $2 }
B: [ pair("a", "b"); move; pair("c", "d") ]
x = B.wid / 2
for i = 1 to 3 do { circle rad 0.05 * i at B.s + (i/4, -0.3) }
if x > 0.5 then { "wide" at B.n above } else { "narrow" at B.n above }
box sprintf("%g by %.2f", B.wid, B.ht) at B.c + (0, -0.8)
line from 1/3 between B.sw and B.se to B.n
move to B.ne; "end" rjust
.PE
Scaled, and sized by its .PS line:
.PS 2 1
scale = 2
box wid 1 ht 1; arc; line up; circle
.PE
