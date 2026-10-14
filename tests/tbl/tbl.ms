.\" tbl(1)'s test: tables of most kinds; tbl.out is Plan 9 tbl's output
.PP
A boxed table, a heading spanning its columns:
.TS
center box;
c s s
l | c | n.
The Greek Alphabet
_
Name	Letter	Value
=
alpha	α	1
beta	β	2
gamma	γ	3
.TE
Every cell boxed, its own tab character, numbers aligned:
.TS
allbox tab(:);
l n n.
Item:Count:Share
Manuscripts:1,240:41.5
Papyri:87:2.9
Inscriptions:1665:55.6
Fragments:\&12a:.75
.TE
Expanded, doubled, fonts and sizes, vertical spans, text blocks:
.TS
expand doublebox;
cB cI cfCR
l ^ rp-1
lw(1.5i) l n.
Author	Work	Year
Homer	Iliad	\-750
Hesiod	T{
Works and Days, a poem of the farmer's year,
in a block of text that fills.
T}	\-700
Sappho	\_	\-600
_
.T&
c s s.
Later
.TE
Short and alphabetic columns, a centred span, and \\R's filler:
.TS
tab(:) center;
a a
c s
l r.
alpha:beta
gamma delta
\Rx:end
:
.TE
Equations' delimiters within numbers:
.TS
delim($$) center;
n n.
$x.5$	1.25
3.0	$y$
.TE
