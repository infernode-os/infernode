.EQ
delim $$
.EN
.chapter "Mathematics" math
Inline $x sup 2 + y sub i sup 2$ and $alpha over beta$ and $sqrt {a+b}$.\c
.index "mathematics!inline"
Here.
.index "aretē@\fIἀρετή\fP|textbf"
.EQ (1.1)
sum from i=1 to n x sub i = int from 0 to inf e sup {-x sup 2} dx
.EN
.EQ
left ( matrix { ccol { a above b } rcol { c above d } } right ) ~~ lim from {x -> 0} {sin x} over x = 1
.EN
.EQ
x bar + y vec + {roman "max"} - bold X + left [ pile { 1 above 2 } right ] + a <= b != c
.EN
.section "Tables"
.TS
center box;
c s
l n.
Heading
_
Plato	347
Aristotle	322
.TE
.TS
allbox;
lb c.
One	T{
A text block of some length that should wrap inside its cell.
T}
Two	2
.TE
.section "Pictures"
.PS
box "start"; arrow; circle "end"
.PE
.nf
A poem's line
and another
.fi
.ce
Centred
Done: 50% & $5 #1 ~ ^ a_b {c} \e -- \(em \(lqquoted\(rq.
.ds name Plato
Hello \*[name].
.printindex
