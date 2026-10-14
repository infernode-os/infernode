.EQ
delim $$
define foo 'x sup 2'
define bar 'left ( $1 over $2 right )'
gsize 11
.EN
Inline $a sub i sup 2 + b$ and $sum from i=0 to n x sub i$ and $foo + bar(a, b+c)$.
.EQ
x = {-b +- sqrt {b sup 2 - 4ac}} over 2a
.EN
.EQ
lim from {n -> inf} sum from {k=1} to n 1 over {k sup 2} = pi sup 2 over 6
.EN
.EQ
int from 0 to inf e sup {-x sup 2} dx = sqrt pi over 2
.EN
.EQ
left [ matrix { ccol { a above c } ccol { b above d } } right ]
pile { x above y above z } ~~ lpile { 1 above 22 } ^ rpile {333 above 4}
.EN
.EQ
x bar + y under + z vec + w tilde + v hat + u dot + t dotdot + s dyad
.EN
.EQ
left { pile { 1 above 0 } right . ~ left floor x right floor ~ left ceiling x right ceiling
~ left < a right > ~ left | b right |
.EN
.EQ
bold x + italic y + roman z + size 14 {A over B} + size -2 c + font CR d
fwd 50 e back 20 f up 30 g down 30 h
.EN
.EQ
mark x = y
.EN
.EQ
lineup = z + 1
.EN
.EQ
set thin_space 20
chartype "op" "\\(ts"
breakcost bin 100
bracketsizes "(" 2 "(" "\\N'parenleftbig'"
alpha beta gamma DELTA SIGMA omega cdot times approx partial grad half prime
a <= b >= c != d == e -> f <- g +- h ... ,..., int prod sum union inter
.EN
.EQ
"quoted text" type "rel" { += } x sub 1 sub 2 sup 3 sup 4
.EN
