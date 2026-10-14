implement Tbl;

#
# tbl - troff's preprocessor for tables
#
# A translation of Plan 9's tbl (as Neatroff uses it) into Limbo; for
# the same input it writes the same output, byte for byte.
#
# Its text is handled as bytes: each byte of the input is a character
# of the strings here (from 0 to 255), and each is written back as the
# byte it was.
#
# Copyright (C) 2003, Lucent Technologies Inc. and others. All Rights
# Reserved. Distributed under the MIT license:
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Tbl: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

MAXLIN:		con 250;
MAXHEAD:	con 44;
MAXCHS:		con 2000;
MAXLINLEN:	con 300;
NOLIMIT:	con 16r7fffffff;	# a line of any length
CLLEN:		con 10;
SHORTLINE:	con 4;
BACKMAX:	con 500;

ZEROW:		con 8r001;
HALFUP:		con 8r002;
CTOP:		con 8r004;
CDOWN:		con 8r010;

CRIGHT:		con 2;
CLEFT:		con 0;
CMID:		con 1;
S1:		con 31;
S2:		con 32;
TMP:		con 38;
S9:		con 39;
SF:		con 35;
SL:		con 34;
LSIZE:		con 33;
SIND:		con 37;
SVS:		con 36;

# lines' relative positions
LEFT:		con 1;
RIGHT:		con 2;
THRU:		con 3;
TOP:		con 1;
BOT:		con 2;

EOF:		con -1;

# an entry: C's char *, which is nil, a string, or the name of a text
# block (a number below 128 in place of a pointer)
VNIL, VSTR, VTXT: con iota;
Val: adt {
	k:	int;
	s:	string;
	n:	int;
};
Cell: adt {
	col:	Val;
	rcol:	Val;
};

NIL: con Val(VNIL, nil, 0);

MACROS: con "/sys/lib/tmac/tmac.s";
PYMACS: con "/sys/lib/tmac/tmac.m";

stdout: ref Iobuf;
tabin: ref Iobuf;
tabinfile := 0;		# tabin is a file opened here
sargs: list of string;

expflg := 0;
ctrflg := 0;
boxflg := 0;
dboxflg := 0;
tab := '\t';
linsize := 0;
pr1403 := 0;
delim1 := 0;
delim2 := 0;
evenflg := 0;
evenup: array of int;
F1 := 0;
F2 := 0;
allflg := 0;
leftover: string;
hasleftover := 0;
textflg := 0;
left1flg := 0;
rightl := 0;
last: string;
cpos := 0;		# C's cstore - cspace
# a line past MAXLIN for a line with no data before the last (C writes
# past its arrays, and fails)
table := array[MAXLIN + 2] of array of Cell;
stynum := array[MAXLIN + 2] of {* => 0};
fullbot := array[MAXLIN + 2] of {* => 0};
instead := array[MAXLIN + 2] of string;
linestop := array[MAXLIN + 2] of {* => 0};
style: array of array of int;
fonts: array of int;	# C's font[qcol][MAXHEAD][2], its bytes
csize: array of array of string;
vsize: array of array of string;
lefline: array of array of int;
cll: array of string;
flags: array of array of int;
qcol := 0;
doubled, acase, topat: array of int;
nslin := 0;
nclin := 0;
sepa: array of int;	# sep[-1] is sepa[0]
used, lused, rused: array of int;
nlin := 0;
ncol := 0;
iline := 1;
ifile := "Input";
texname := 'a';
texct := 0;
texstr := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWYXZ0123456789";
linstart := 0;
oncol := 0;
backup := array[BACKMAX] of int;
backp := 0;
watchout := 0;
once := 0;
useln := 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	{
		tbl(args);
	} exception e {
	"fail:*" =>
		stdout.flush();
		raise e;
	"*" =>
		# where C would crash: said, and failed
		stdout.flush();
		errout("tbl: " + e + "\n");
		raise "fail:" + e;
	}
	stdout.flush();
}

#
# output, a byte a character
#
out(s: string)
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	stdout.write(b, len b);
}

outc(c: int)
{
	stdout.putb(byte c);
}

errout(s: string)
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	sys->write(sys->fildes(2), b, len b);
}

# a Unicode string as its UTF-8 bytes, a character each
u8(s: string): string
{
	b := array of byte s;
	r := "";
	for(i := 0; i < len b; i++)
		r[i] = int b[i];
	return r;
}

ch(c: int): string
{
	s := "";
	s[0] = c & 16rff;
	return s;
}

# C's s[i]: NUL past the end
at(s: string, i: int): int
{
	if(i < 0 || i >= len s)
		return 0;
	return s[i];
}

# C's %2s
s2(s: string): string
{
	if(len s < 2)
		return " " + s;
	return s;
}

#
# t1.c: main control and input switching
#
tbl(args: list of string)
{
	setinp(args);
	line := "";
	for(;;){
		# a line outside a table is passed on whole: C's buffer of
		# 5120 bytes cut a longer one in two, and a word with it
		(l, ok) := gets1(NOLIMIT, line);
		if(!ok)
			break;
		line = l;
		out(line + "\n");
		if(prefix(".TS", line))
			tableput();
	}
}

setinp(args: list of string)
{
	if(args != nil)
		args = tl args;
	sargs = args;
	if(sargs == nil || swapin() == 0){
		tabin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
		tabinfile = 0;
	}
}

swapin(): int
{
	while(sargs != nil && at(hd sargs, 0) == '-'){
		a := hd sargs;
		if(a == "-ms"){
			sargs = MACROS :: tl sargs;
			break;
		}
		if(a == "-mm"){
			sargs = PYMACS :: tl sargs;
			break;
		}
		if(a == "-TX")
			pr1403 = 1;
		if(a == "-")
			break;
		sargs = tl sargs;
	}
	if(sargs == nil)
		return 0;
	if(tabin != nil && tabinfile)
		tabin.close();
	name := hd sargs;
	ifile = u8(name);
	if(name == "-"){
		tabin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
		tabinfile = 0;
	}else{
		tabin = bufio->open(name, Bufio->OREAD);
		tabinfile = 1;
	}
	iline = 1;
	out(".ds f. " + ifile + "\n");
	out(".lf " + string iline + " " + ifile + "\n");
	if(tabin == nil)
		error("Can't open file");
	sargs = tl sargs;
	return 1;
}

#
# t2.c: subroutine sequencing for one table
#
tableput()
{
	saveline();
	savefill();
	ifdivert();
	cleanfc();
	getcomm();
	getspec();
	gettbl();
	getstop();
	checkuse();
	choochar();
	maktab();
	runout();
	release();
	rstofill();
	endoff();
	restline();
}

#
# t3.c: interpret commands affecting whole table
#
optnames := array[] of {
	"expand", "EXPAND", "center", "CENTER", "box", "BOX",
	"allbox", "ALLBOX", "doublebox", "DOUBLEBOX", "frame", "FRAME",
	"doubleframe", "DOUBLEFRAME", "tab", "TAB", "linesize", "LINESIZE",
	"delim", "DELIM",
};

setopt(i: int, v: int)
{
	case i / 2 {
	0 =>	expflg = v;
	1 =>	ctrflg = v;
	2 =>	boxflg = v;
	3 =>	allflg = v;
	4 =>	dboxflg = v;
	5 =>	boxflg = v;
	6 =>	dboxflg = v;
	7 =>	tab = v;
	8 =>	linsize = v;
	9 =>	delim1 = v;
	}
}

getcomm()
{
	for(i := 0; i < len optnames; i++)
		setopt(i, 0);
	texct = 0;
	texname = texstr[0];
	tab = '\t';
	out(".nr " + string LSIZE + " \\n(.s\n");
	out(".af " + string LSIZE + " 01\n");
	(line, nil) := gets1(200, "");
	# see if this is a command line
	if(strchr(line, ';') < 0){
		backrest(line);
		return;
	}
	cp := 0;
	for(; cp < len line && (c := at(line, cp)) != ';'; cp++){
		if(!letter(c))
			continue;
		found := 0;
		for(i = 0; i < len optnames; i++){
			if(prefix(optnames[i], line[cp:])){
				setopt(i, 1);
				cp += len optnames[i];
				if(letter(at(line, cp)))
					error("Misspelled global option");
				while(at(line, cp) == ' ')
					cp++;
				nb := "";
				if(at(line, cp) == '('){
					while(cp + 1 < len line && (ci := at(line, ++cp)) != ')')
						nb[len nb] = ci;
				}else
					cp--;
				opt := i / 2;
				if(opt == 7 && at(nb, 0) != 0)
					tab = at(nb, 0);
				if(opt == 8)
					out(".nr " + string LSIZE + " " + cstr(nb) + "\n");
				if(opt == 9){
					delim1 = at(nb, 0);
					delim2 = at(nb, 1);
				}
				found = 1;
				break;
			}
		}
		if(!found)
			error("Illegal option");
	}
	cp++;
	backrest(line[cp:]);
}

backrest(s: string)
{
	s = cstr(s);
	un1getc('\n');
	for(i := len s; i > 0; )
		un1getc(s[--i]);
}

#
# t4.c: read table specification
#
getspec()
{
	qcol = findcol() + 1;	# must allow one extra for line at right
	garray(qcol);
	setsep(-1, -1);
	for(icol := 0; icol < qcol; icol++){
		setsep(icol, -1);
		evenup[icol] = 0;
		cll[icol] = "";
		for(i := 0; i < MAXHEAD; i++){
			csize[icol][i] = "";
			vsize[icol][i] = "";
			fontset(icol, i, 0, 0);
			lefline[icol][i] = 0;
			flags[icol][i] = 0;
			style[icol][i] = 'l';
		}
	}
	for(i := 0; i < MAXHEAD; i++)
		lefline[qcol][i] = 0;	# fixes sample55 looping
	nclin = ncol = 0;
	oncol = 0;
	left1flg = rightl = 0;
	readspec();
	out(".rm");
	for(i = 0; i < ncol; i++)
		out(" " + s2(reg(i, CRIGHT)));
	out("\n");
}

readspec()
{
	sawchar := 0;
	icol := 0;
	while((c := get1char()) != 0){
		if(c == 'C' || c == 'S' || c == 'R' || c == 'N' || c == 'L' || c == 'A')
			c += 'a' - 'A';
		if(c == '_')
			c = '-';
		case c {
		'=' or '-' or '^' or 'c' or 's' or 'n' or 'r' or 'l' or 'a' =>
			spec(c, icol);
			icol++;
			if(c == '^' && nclin <= 0)
				error("first row can not contain vertical span");
			if(icol > qcol)
				error("too many columns in table");
			sawchar = 1;
		' ' =>
			;
		'\n' or ',' or '.' =>
			if(c == '\n' && sawchar == 0)
				continue;
			ncol = max(ncol, icol);
			if(lefline[ncol][nclin] > 0){
				ncol++;
				rightl++;
			}
			if(sawchar)
				nclin++;
			if(nclin >= MAXHEAD)
				error("too many lines in specification");
			icol = 0;
			if(ncol == 0 || nclin == 0)
				error("no specification");
			if(c == '.'){
				while((c = get1char()) != 0 && c != '\n')
					if(c != ' ' && c != '\t')
						error("dot not last character on format line");
				# fix up sep - default is 3 except at edge
				for(icol = 0; icol < ncol; icol++)
					if(sep(icol) < 0){
						if(icol + 1 < ncol)
							setsep(icol, 3);
						else
							setsep(icol, 2);
					}
				if(oncol == 0)
					oncol = ncol;
				else if(oncol + 2 < ncol)
					error("tried to widen table in T&, not allowed");
				return;
			}
			sawchar = 0;
		'b' or 'i' or 'B' or 'I' =>
			if(c == 'b' || c == 'i')
				c += 'A' - 'a';
			if(icol == 0)
				continue;
			if(c == 'I')
				fontset(icol - 1, nclin, '2', 0);
			else
				fontset(icol - 1, nclin, '3', 0);
		't' or 'T' =>
			if(icol > 0)
				flags[icol - 1][nclin] |= CTOP;
		'd' or 'D' =>
			if(icol > 0)
				flags[icol - 1][nclin] |= CDOWN;
		'f' or 'F' =>
			if(icol == 0)
				continue;
			f := array[2] of {* => 0};
			stopc := 0;
			for(i := 0; i < 2; i++){
				c = get1char();
				if(i == 0 && c == '('){
					stopc = ')';
					c = get1char();
				}
				if(c == 0)
					break;
				if(c == stopc){
					stopc = 0;
					break;
				}
				if(stopc == 0)
					if(c == ' ' || c == tab)
						break;
				if(c == '\n' || c == '|'){
					un1getc(c);
					break;
				}
				f[i] = c;
				if(c >= '0' && c <= '9')
					break;
			}
			fontset(icol - 1, nclin, f[0], f[1]);
			if(stopc)
				if(get1char() != stopc)
					error("Nonterminated font name");
		'P' or 'p' =>
			if(icol <= 0)
				continue;
			sn := "";
			while((c = get1char()) != 0){
				if(c == ' ' || c == tab || c == '\n')
					break;
				if(c == '-' || c == '+'){
					if(len sn > 0)
						break;
					else
						sn[len sn] = c;
				}else if(digit(c))
					sn[len sn] = c;
				else
					break;
				if(len sn > 4)
					error("point size too large");
			}
			csize[icol - 1][nclin] = sn;
			if(atoi(sn) > 36)
				error("point size unreasonable");
			un1getc(c);
		'V' or 'v' =>
			if(icol <= 0)
				continue;
			sn := "";
			while((c = get1char()) != 0){
				if(c == ' ' || c == tab || c == '\n')
					break;
				if(c == '-' || c == '+'){
					if(len sn > 0)
						break;
					else
						sn[len sn] = c;
				}else if(digit(c))
					sn[len sn] = c;
				else
					break;
				if(len sn > 4)
					error("vertical spacing value too large");
			}
			vsize[icol - 1][nclin] = sn;
			un1getc(c);
		'w' or 'W' =>
			sn := "";
			stopc := 0;
			while((c = get1char()) != 0){
				if(sn == "" && c == '('){
					stopc = ')';
					continue;
				}
				if(!stopc && (c > '9' || c < '0'))
					break;
				if(stopc && c == stopc)
					break;
				sn[len sn] = c;
			}
			if(icol - 1 >= 0)
				cll[icol - 1] = sn;
			if(len sn > CLLEN)
				error("column width too long");
			if(!stopc)
				un1getc(c);
		'e' or 'E' =>
			if(icol < 1)
				continue;
			evenup[icol - 1] = 1;
			evenflg = 1;
		'z' or 'Z' =>	# zero width-ignre width this item
			if(icol < 1)
				continue;
			flags[icol - 1][nclin] |= ZEROW;
		'u' or 'U' =>	# half line up
			if(icol < 1)
				continue;
			flags[icol - 1][nclin] |= HALFUP;
		'0' to '9' =>
			sn := ch(c);
			for(;;){
				c = get1char();
				sn[len sn] = c & 16rff;
				if(!digit(c))
					break;
			}
			un1getc(c);
			setsep(icol - 1, max(sep(icol - 1), numb(sn)));
		'|' =>
			lefline[icol][nclin]++;
			if(icol == 0)
				left1flg = 1;
		* =>
			if(c != tab)
				error("bad table specification character " + ch(c));
		}
	}
	error("EOF reading table specification");
}

# a column's style
spec(c: int, icol: int)
{
	if(icol >= len style)	# C writes past its array, then says so
		return;
	style[icol][nclin] = c;
	if(c == 's' && icol <= 0)
		error("first column can not be S-type");
	if(c == 's' && style[icol - 1][nclin] == 'a'){
		out(".tm warning: can't span a-type cols, changed to l\n");
		style[icol - 1][nclin] = 'l';
	}
	if(c == 's' && style[icol - 1][nclin] == 'n'){
		out(".tm warning: can't span n-type cols, changed to c\n");
		style[icol - 1][nclin] = 'c';
	}
}

findcol(): int
{
	FLNLIM: con 200;
	# this counts the number of columns and then puts the line back
	line := "";
	n := 0;
	inpar := 0;
	c: int;
	while((c = get1char()) != 0 && c == ' ')
		;
	if(c != '\n')
		un1getc(c);
	s := 0;
	for(;; s++){
		c = get1char();
		line[s] = c;	# EOF is 16rffff, put back as 16rff
		if(c == 0)
			break;
		if(c == ')')
			inpar = 0;
		if(inpar)
			continue;
		if(c == '\n' || c == 0 || c == '.' || c == ',')
			break;
		else if(c == '(')
			inpar = 1;
		else if(s >= FLNLIM)
			error("too long spec line");
	}
	p: int;
	for(p = 0; p < s; p++)
		case line[p] {
		'l' or 'r' or 'c' or 'n' or 'a' or 's' or
		'L' or 'R' or 'C' or 'N' or 'A' or 'S' or
		'-' or '=' or '_' =>
			n++;
		}
	while(p >= 0){
		c = line[p--];
		if(c == 16rffff)
			c = EOF;
		un1getc(c);
	}
	return n;
}

garray(qcol: int)
{
	style = array[qcol] of array of int;
	csize = array[qcol] of array of string;
	vsize = array[qcol] of array of string;
	flags = array[qcol] of array of int;
	for(i := 0; i < qcol; i++){
		style[i] = array[MAXHEAD] of {* => 0};
		csize[i] = array[MAXHEAD] of string;
		vsize[i] = array[MAXHEAD] of string;
		flags[i] = array[MAXHEAD] of {* => 0};
	}
	lefline = array[qcol + 1] of array of int;
	for(i = 0; i < qcol + 1; i++)
		lefline[i] = array[MAXHEAD] of {* => 0};
	evenup = array[qcol] of {* => 0};
	fonts = array[qcol * MAXHEAD * 2 + 1] of {* => 0};
	cll = array[qcol] of string;
	sepa = array[qcol + 1] of {* => 0};
	used = array[qcol + 1] of {* => 0};
	lused = array[qcol + 1] of {* => 0};
	rused = array[qcol + 1] of {* => 0};
	doubled = array[qcol + 1] of {* => 0};
	acase = array[qcol + 1] of {* => 0};
	topat = array[qcol + 1] of {* => 0};
}

sep(i: int): int
{
	return sepa[i + 1];
}

setsep(i: int, v: int)
{
	sepa[i + 1] = v;
}

fontset(c, i: int, a, b: int)
{
	o := (c * MAXHEAD + i) * 2;
	fonts[o] = a;
	fonts[o + 1] = b;
}

# a column's font: as C prints its two bytes with %s, to the NUL past
# them
font(c, i: int): string
{
	s := "";
	for(o := (c * MAXHEAD + i) * 2; o < len fonts && fonts[o] != 0; o++)
		s[len s] = fonts[o];
	return s;
}

#
# t5.c: read data for table
#
gettbl()
{
	cpos = 0;
	textflg = 0;
	line := "";
	ok: int;
	for(nlin = nslin = 0; ; nlin++){
		(line, ok) = gets1(MAXCHS - cpos, "");
		if(!ok)
			break;
		stynum[nlin] = nslin;
		if(prefix(".TE", line)){
			hasleftover = 0;
			break;
		}
		if(prefix(".TC", line) || prefix(".T&", line)){
			readspec();
			nslin++;
		}
		if(nlin >= MAXLIN){
			leftover = line;
			hasleftover = 1;
			break;
		}
		fullbot[nlin] = 0;
		if(at(line, 0) == '.' && !isdigit(at(line, 1))){
			instead[nlin] = line;
			cpos += len line + 1;
			continue;
		}else
			instead[nlin] = nil;
		if(nodata(nlin)){
			if((c := oneh(nlin)) != 0)
				fullbot[nlin] = c;
			table[nlin] = newrow();
			for(icol := 0; icol < ncol; icol++){
				table[nlin][icol].rcol = Val(VSTR, "", 0);
				table[nlin][icol].col = Val(VSTR, "", 0);
			}
			nlin++;
			nslin++;
			fullbot[nlin] = 0;
			instead[nlin] = nil;
		}
		table[nlin] = newrow();
		if(len line == 1)
			case line[0] {
			'_' =>
				fullbot[nlin] = '-';
				continue;
			'=' =>
				fullbot[nlin] = '=';
				continue;
			}
		stynum[nlin] = nslin;
		nslin = min(nslin + 1, nclin - 1);
		s := line;	# what is left of the line
		icol: int;
		for(icol = 0; icol < ncol; icol++){
			table[nlin][icol].col = Val(VSTR, s, 0);
			table[nlin][icol].rcol = NIL;
			c := 1;
			if(s == "T{"){	# text follows
				(n, rest) := gettext(nlin, icol, font(icol, stynum[nlin]),
					csize[icol][stynum[nlin]]);
				table[nlin][icol].col = Val(VTXT, nil, n);
				s = rest;
			}else{
				i := 0;
				for(; (c = at(s, i)) != 0 && c != tab; i++)
					;
				table[nlin][icol].col = Val(VSTR, s[0:i], 0);
				if(i < len s)
					s = s[i + 1:];
				else
					s = "";
				case ctype(nlin, icol) {	# numerical or alpha, subcol
				'n' =>
					(col, rcol) := maknew(table[nlin][icol].col.s);
					table[nlin][icol].col.s = col;
					table[nlin][icol].rcol = rcol;
				'a' =>
					table[nlin][icol].rcol = table[nlin][icol].col;
					table[nlin][icol].col = Val(VSTR, "", 0);
				}
			}
			while(ctype(nlin, icol + 1) == 's')	# spanning
				table[nlin][++icol].col = Val(VSTR, "", 0);
			if(c == 0)
				break;
		}
		while(++icol < ncol + 2){
			table[nlin][icol].col = Val(VSTR, "", 0);
			table[nlin][icol].rcol = NIL;
		}
		cpos += len line + 1;
		if(cpos + MAXLINLEN > MAXCHS)
			cpos = 0;
	}
	if(ok)
		last = line;
	else
		last = "";
	permute();
	if(textflg)
		untext();
}

newrow(): array of Cell
{
	r := array[ncol + 2] of Cell;
	for(i := 0; i < len r; i++)
		r[i] = Cell(NIL, NIL);
	return r;
}

nodata(il: int): int
{
	for(c := 0; c < ncol; c++){
		case ctype(il, c) {
		'c' or 'n' or 'r' or 'l' or 's' or 'a' =>
			return 0;
		}
	}
	return 1;
}

oneh(lin: int): int
{
	k := ctype(lin, 0);
	for(icol := 1; icol < ncol; icol++){
		if(k != ctype(lin, icol))
			return 0;
	}
	return k;
}

SPAN: con "\\^";

permute()
{
	for(jcol := 0; jcol < ncol; jcol++){
		for(irow := 1; irow < nlin; irow++){
			if(vspand(irow, jcol, 0)){
				is := prev(irow);
				if(is < 0)
					error("Vertical spanning in first row not allowed");
				start := table[is][jcol].col;
				strig := table[is][jcol].rcol;
				while(irow < nlin && vspand(irow, jcol, 0))
					irow++;
				table[--irow][jcol].col = start;
				table[irow][jcol].rcol = strig;
				while(is < irow){
					table[is][jcol].rcol = NIL;
					table[is][jcol].col = Val(VSTR, SPAN, 0);
					is = next(is);
				}
			}
		}
	}
}

vspand(ir: int, ij: int, ifform: int): int
{
	if(ir < 0)
		return 0;
	if(ir >= nlin)
		return 0;
	if(instead[ir] != nil)
		return 0;
	if(ifform == 0 && ctype(ir, ij) == '^')
		return 1;
	if(table[ir][ij].rcol.k != VNIL)
		return 0;
	if(fullbot[ir])
		return 0;
	return vspen(table[ir][ij].col);
}

vspen(s: Val): int
{
	if(s.k != VSTR)
		return 0;
	return s.s == SPAN;
}

#
# t6.c: compute tab stops
#
maktab()
{
	ss: Val;
	for(icol := 0; icol < ncol; icol++){
		doubled[icol] = acase[icol] = 0;
		out(".nr " + s2(reg(icol, CRIGHT)) + " 0\n");
		for(text := 0; text < 2; text++){
			if(text)
				out("." + s2(reg(icol, CRIGHT)) + "\n.rm " + s2(reg(icol, CRIGHT)) + "\n");
			for(ilin := 0; ilin < nlin; ilin++){
				if(instead[ilin] != nil || fullbot[ilin])
					continue;
				vforml := ilin;
				for(il := prev(ilin); il >= 0 && vspen(table[il][icol].col); il = prev(il))
					vforml = il;
				if(fspan(vforml, icol))
					continue;
				if(filler(table[ilin][icol].col))
					continue;
				if((flags[icol][stynum[ilin]] & ZEROW) != 0)
					continue;
				ct := ctype(vforml, icol);
				if(ct == 'a'){
					acase[icol] = 1;
					ss = table[ilin][icol].col;
					if(ss.k == VTXT && text){
						if(doubled[icol] == 0)
							out(".nr " + string S1 + " 0\n.nr " + string S2 + " 0\n");
						doubled[icol] = 1;
						out(sys->sprint(".if \\n(%c->\\n(%d .nr %d \\n(%c-\n",
							ss.n, S2, S2, ss.n));
					}
				}
				if((ct == 'a' || ct == 'n') && table[ilin][icol].rcol.k != VNIL){
					if(doubled[icol] == 0 && text == 0)
						out(".nr " + string S1 + " 0\n.nr " + string S2 + " 0\n");
					doubled[icol] = 1;
					if(isreal(ss = table[ilin][icol].col) && !vspen(ss)){
						if((ss.k == VTXT) != text)
							continue;
						out(".nr " + string TMP + " ");
						wide(ss, font(icol, stynum[vforml]), csize[icol][stynum[vforml]]);
						out("\n");
						out(sys->sprint(".if \\n(%d<\\n(%d .nr %d \\n(%d\n",
							S1, TMP, S1, TMP));
					}
					if(text == 0 && isreal(ss = table[ilin][icol].rcol) && !vspen(ss) && !barent(ss)){
						out(".nr " + string TMP + " \\w" + ch(F1) + ss.s + ch(F1) + "\n");
						out(sys->sprint(".if \\n(%d<\\n(%d .nr %d \\n(%d\n", S2, TMP, S2, TMP));
					}
					continue;
				}
				case ct {
				'a' or 'n' or 'r' or 'c' or 'l' =>
					if(isreal(ss = table[ilin][icol].col) && !vspen(ss)){
						if((ss.k == VTXT) != text)
							continue;
						out(".nr " + string TMP + " ");
						wide(ss, font(icol, stynum[vforml]), csize[icol][stynum[vforml]]);
						out("\n");
						out(".if \\n(" + s2(reg(icol, CRIGHT)) + "<\\n(" + string TMP +
							" .nr " + s2(reg(icol, CRIGHT)) + " \\n(" + string TMP + "\n");
					}
				}
			}
		}
		if(acase[icol]){
			out(sys->sprint(".if \\n(%d>=\\n(%s .nr %s \\n(%du+2n\n",
				S2, s2(reg(icol, CRIGHT)), s2(reg(icol, CRIGHT)), S2));
		}
		if(doubled[icol]){
			out(sys->sprint(".nr %s \\n(%d\n", s2(reg(icol, CMID)), S1));
			out(sys->sprint(".nr %d \\n(%s+\\n(%d\n", TMP, s2(reg(icol, CMID)), S2));
			out(sys->sprint(".if \\n(%d>\\n(%s .nr %s \\n(%d\n", TMP,
				s2(reg(icol, CRIGHT)), s2(reg(icol, CRIGHT)), TMP));
			out(sys->sprint(".if \\n(%d<\\n(%s .nr %s +(\\n(%s-\\n(%d)/2\n",
				TMP, s2(reg(icol, CRIGHT)), s2(reg(icol, CMID)), s2(reg(icol, CRIGHT)), TMP));
		}
		if(cll[icol] != ""){
			out(sys->sprint(".nr %d ", TMP) + cll[icol] + "n\n");
			out(sys->sprint(".if \\n(%s<\\n(%d .nr %s \\n(%d\n",
				s2(reg(icol, CRIGHT)), TMP, s2(reg(icol, CRIGHT)), TMP));
		}
		for(ilin := 0; ilin < nlin; ilin++)
			if((k := lspan(ilin, icol)) != 0){
				ss = table[ilin][icol - k].col;
				if(!isreal(ss) || barent(ss) || vspen(ss))
					continue;
				out(".nr " + string TMP + " ");
				wide(table[ilin][icol - k].col, font(icol - k, stynum[ilin]), csize[icol - k][stynum[ilin]]);
				for(ik := k; ik >= 0; ik--){
					out("-\\n(" + s2(reg(icol - ik, CRIGHT)));
					if(!expflg && ik > 0)
						out(sys->sprint("-%dn", sep(icol - ik)));
				}
				out("\n");
				out(sys->sprint(".if \\n(%d>0 .nr %d \\n(%d/%d\n", TMP, TMP, TMP, k));
				out(sys->sprint(".if \\n(%d<0 .nr %d 0\n", TMP, TMP));
				for(ik = 1; ik <= k; ik++){
					if(doubled[icol - k + ik])
						out(sys->sprint(".nr %s +\\n(%d/2\n", s2(reg(icol - k + ik, CMID)), TMP));
					out(sys->sprint(".nr %s +\\n(%d\n", s2(reg(icol - k + ik, CRIGHT)), TMP));
				}
			}
	}
	if(textflg)
		untext();
	# if even requested, make all columns widest width
	if(evenflg){
		out(sys->sprint(".nr %d 0\n", TMP));
		for(icol = 0; icol < ncol; icol++){
			if(evenup[icol] == 0)
				continue;
			out(sys->sprint(".if \\n(%s>\\n(%d .nr %d \\n(%s\n",
				s2(reg(icol, CRIGHT)), TMP, TMP, s2(reg(icol, CRIGHT))));
		}
		for(icol = 0; icol < ncol; icol++){
			if(evenup[icol] == 0)
				# if column not evened just retain old interval
				continue;
			if(doubled[icol])
				out(sys->sprint(".nr %s (100*\\n(%s/\\n(%s)*\\n(%d/100\n",
					s2(reg(icol, CMID)), s2(reg(icol, CMID)), s2(reg(icol, CRIGHT)), TMP));
			# that nonsense with the 100's and parens tries to avoid
			# overflow while proportionally shifting the middle of
			# the number
			out(sys->sprint(".nr %s \\n(%d\n", s2(reg(icol, CRIGHT)), TMP));
		}
	}
	# now adjust for total table width
	tsep := 0;
	for(icol = 0; icol < ncol; icol++)
		tsep += sep(icol);
	if(expflg){
		out(sys->sprint(".nr %d 0", TMP));
		for(icol = 0; icol < ncol; icol++)
			out("+\\n(" + s2(reg(icol, CRIGHT)));
		out("\n");
		out(sys->sprint(".nr %d \\n(.l-\\n(%d\n", TMP, TMP));
		if(boxflg || dboxflg || allflg)
			;
		else
			tsep -= sep(ncol - 1);
		out(sys->sprint(".nr %d \\n(%d/%d\n", TMP, TMP, tsep));
		out(sys->sprint(".if \\n(%d<0 .nr %d 0\n", TMP, TMP));
	}else
		out(sys->sprint(".nr %d 1n\n", TMP));
	out(".nr " + s2(reg(-1, CRIGHT)) + " 0\n");
	if(boxflg || allflg || dboxflg || left1flg)
		tsep = 2;
	else
		tsep = 0;
	if(sep(-1) >= 0)
		tsep = sep(-1);
	for(icol = 0; icol < ncol; icol++){
		out(sys->sprint(".nr %s \\n(%s+((%d*\\n(%d)/2)\n", s2(reg(icol, CLEFT)),
			s2(reg(icol - 1, CRIGHT)), tsep, TMP));
		out(sys->sprint(".nr %s +\\n(%s\n", s2(reg(icol, CRIGHT)), s2(reg(icol, CLEFT))));
		if(doubled[icol]){
			# the next line is last-ditch effort to avoid zero field width
			out(sys->sprint(".nr %s +\\n(%s\n", s2(reg(icol, CMID)), s2(reg(icol, CLEFT))));
		}
		tsep = sep(icol) * 2;
	}
	if(rightl)
		out(".nr " + reg(ncol - 1, CRIGHT) + " (\\n(" + reg(ncol - 1, CLEFT) +
			"+\\n(" + reg(ncol - 2, CRIGHT) + ")/2\n");
	out(".nr TW \\n(" + s2(reg(ncol - 1, CRIGHT)) + "\n");
	tsep = sep(ncol - 1);
	if(boxflg || allflg || dboxflg)
		out(sys->sprint(".nr TW +((%d*\\n(%d)/2)\n", tsep, TMP));
	out(".if t .if (\\n(TW+\\n(.o)>7.65i .tm Table at line " + string (iline - 1) +
		" file " + ifile + " is too wide - \\n(TW units\n");
}

wide(s: Val, fnt: string, size: string)
{
	if(s.k == VSTR){
		out("\\w" + ch(F1));
		if(fpos(fnt))
			putfont(fnt);
		if(size != "")
			putsize(size);
		out(s.s);
		if(fpos(fnt))
			putfont("P");
		if(size != "")
			putsize("0");
		out(ch(F1));
	}else
		out("\\n(" + ch(s.n) + "-");
}

# C's *fnt > 0, its chars signed
fpos(fnt: string): int
{
	return fnt != "" && fnt[0] > 0 && fnt[0] < 128;
}

filler(s: Val): int
{
	return s.k == VSTR && at(s.s, 0) == '\\' && at(s.s, 1) == 'R';
}

#
# t7.c: control to write table entries
#
runout()
{
	if(boxflg || allflg || dboxflg)
		need();
	if(ctrflg){
		out(".nr #I \\n(.i\n");
		out(".in +(\\n(.lu-\\n(TWu-\\n(.iu)/2u\n");
	}
	out(".fc " + ch(F1) + " " + ch(F2) + "\n");
	out(".nr #T 0-1\n");
	deftail();
	for(i := 0; i < nlin; i++)
		putline(i, i);
	if(hasleftover)
		yetmore();
	out(".fc\n");
	out(".nr T. 1\n");
	out(".T# 1\n");
	if(ctrflg)
		out(".in \\n(#Iu\n");
}

runtabs(lform: int, ldata: int)
{
	out(".ta ");
	for(c := 0; c < ncol; c++){
		vforml := lform;
		for(lf := prev(lform); lf >= 0 && vspen(table[lf][c].col); lf = prev(lf))
			vforml = lf;
		if(fspan(vforml, c))
			continue;
		ct := ctype(vforml, c);
		case ct {
		'n' or 'a' or 'c' or 'l' or 'r' =>
			if(ct == 'n' || ct == 'a')
				if(table[ldata][c].rcol.k != VNIL)
					if(lused[c])	# Zero field width
						out("\\n(" + s2(reg(c, CMID)) + "u ");
			realsplit := (ct == 'a' || ct == 'n') && table[ldata][c].rcol.k != VNIL;
			v: int;
			if(realsplit)
				v = rused[c];
			else
				v = used[c] + lused[c];
			if(v)
				out("\\n(" + s2(reg(c, CRIGHT)) + "u ");
		's' =>
			if(lspan(lform, c))
				out("\\n(" + s2(reg(c, CRIGHT)) + "u ");
		}
	}
	out("\n");
}

ifline(v: Val): int
{
	if(v.k != VSTR)
		return 0;
	s := v.s;
	i := 0;
	if(at(s, 0) == '\\')
		i++;
	if(at(s, i + 1))
		return 0;
	if(at(s, i) == '_')
		return '-';
	if(at(s, i) == '=')
		return '=';
	return 0;
}

need()
{
	texlin := 0;
	horlin := 0;
	for(i := 0; i < nlin; i++){
		if(fullbot[i] != 0)
			horlin++;
		else if(instead[i] != nil)
			continue;
		else
			texlin++;
	}
	out(sys->sprint(".ne %dv+%dp\n", texlin, 2 * horlin));
}

deftail()
{
	lwid: int;
	for(i := 0; i < MAXHEAD; i++)
		if(linestop[i])
			out(".nr #" + ch(linestop[i] + 'a' - 1) + " 0-1\n");
	out(".nr #a 0-1\n");
	out(".eo\n");
	out(".de T#\n");
	out(".nr 35 1m\n");
	out(".ds #d .d\n");
	out(".if \\(ts\\n(.z\\(ts\\(ts .ds #d nl\n");
	out(".mk ##\n");
	out(".nr ## -1v\n");
	out(".ls 1\n");
	for(i = 0; i < MAXHEAD; i++)
		if(linestop[i])
			out(".if \\n(#T>=0 .nr #" + ch(linestop[i] + 'a' - 1) + " \\n(#T\n");
	if(boxflg || allflg || dboxflg)	# bottom of table line
		if(fullbot[nlin - 1] == 0){
			if(!pr1403)
				out(".if \\n(T. .vs \\n(.vu-\\n(.sp\n");
			out(".if \\n(T. ");
			if(dboxflg)
				drawline(nlin, 0, ncol, '=', 1, 0);
			else
				drawline(nlin, 0, ncol, '-', 1, 0);
			out("\n.if \\n(T. .vs\n");
			# T. is really an argument to a macro but because of
			# eqn we don't dare pass it as an argument and
			# reference by $1
		}
	for(c := 0; c < ncol; c++){
		lf: int;
		(lf, lwid) = left(nlin - 1, c);
		if(lf >= 0){
			out(".if \\n(#" + ch(linestop[lf] + 'a' - 1) + ">=0 .sp -1\n");
			out(".if \\n(#" + ch(linestop[lf] + 'a' - 1) + ">=0 ");
			tohcol(c);
			drawvert(lf, nlin - 1, c, lwid);
			out("\\h'|\\n(TWu'\n");
		}
	}
	if(boxflg || allflg || dboxflg){	# right hand line
		out(".if \\n(#a>=0 .sp -1\n");
		out(".if \\n(#a>=0 \\h'|\\n(TWu'");
		if(dboxflg)
			drawvert(0, nlin - 1, ncol, 2);
		else
			drawvert(0, nlin - 1, ncol, 1);
		out("\n");
	}
	out(".ls\n");
	out("..\n");
	out(".ec\n");
}

#
# t8.c: write out one line of output table
#
putline(i: int, nl: int)
	# i is line number for deciding format
	# nl is line number for finding data, usually identical
{
	ss: Val;
	lf, lwid, ip: int;
	cmidx := 0;
	watchout = 0;
	vspf := 0;
	exvspen := 0;
	if(i == 0)
		once = 0;
	if(i == 0 && (allflg || boxflg || dboxflg)){
		if(dboxflg)
			fullwide(0, '=');
		else
			fullwide(0, '-');
	}
	c: int;
	if(instead[nl] == nil && fullbot[nl] == 0)
		for(c = 0; c < ncol; c++){
			ss = table[nl][c].col;
			if(ss.k == VNIL)
				continue;
			if(vspen(ss)){
				for(ip = nl; ip < nlin; ip = next(ip)){
					ss = table[ip][c].col;
					if(!vspen(ss))
						break;
					if(next(ip) == ip)	# the last line: C loops for ever
						break;
				}
				if(ss.k == VTXT)
					out(".ne \\n(" + ch(ss.n) + "|u+\\n(.Vu\n");
				continue;
			}
			if(ss.k == VSTR)
				continue;
			out(".ne \\n(" + ch(ss.n) + "|u+\\n(.Vu\n");
			watchout = 1;
		}
	if(linestop[nl])
		out(".mk #" + ch(linestop[nl] + 'a' - 1) + "\n");
	lf = prev(nl);
	if(instead[nl] != nil){
		out(instead[nl] + "\n");
		return;
	}
	if(fullbot[nl]){
		ct := fullbot[nl];
		case ct {
		'=' or '-' =>
			fullwide(nl, ct);
		}
		return;
	}
	for(c = 0; c < ncol; c++){
		if(instead[nl] == nil && fullbot[nl] == 0)
			if(vspen(table[nl][c].col))
				vspf = 1;
		if(lf >= 0)
			if(vspen(table[lf][c].col))
				vspf = 1;
	}
	if(vspf){
		out(".nr #^ \\n(\\*(#du\n");
		out(".nr #- \\n(#^\n");	# current line position relative to bottom
	}
	vspf = 0;
	chfont := 0;
	for(c = 0; c < ncol; c++){
		ss = table[nl][c].col;
		if(ss.k == VNIL)
			continue;
		chfont = 1;
		if(ss.k == VSTR)
			continue;
		s := ch(ss.n);
		lf = prev(nl);
		if(lf >= 0 && vspen(table[lf][c].col))
			out(".if (\\n(" + s + "|+\\n(^" + ch('a' + c) + "-1v)>\\n(#- .nr #- +(\\n(" +
				s + "|+\\n(^" + ch('a' + c) + "-\\n(#--1v)\n");
		else
			out(".if (\\n(" + s + "|+\\n(#^-1v)>\\n(#- .nr #- +(\\n(" + s +
				"|+\\n(#^-\\n(#--1v)\n");
	}
	if(allflg && once > 0)
		fullwide(i, '-');
	once = 1;
	runtabs(i, nl);
	if(allh(i) && !pr1403){
		out(sys->sprint(".nr %d \\n(.v\n", SVS));
		out(".vs \\n(.vu-\\n(.sp\n");
		out(".nr 35 \\n(.vu\n");
	}else
		out(".nr 35 1m\n");
	if(chfont){
		out(sys->sprint(".nr %2d \\n(.f\n", S1));
		out(sys->sprint(".af %2d 01\n", S1));
	}
	out("\\&");
	vct := 0;
	for(c = 0; c < ncol; c++){
		uphalf := 0;
		if(watchout == 0 && i + 1 < nlin)
			(lf, lwid) = left(i, c);
		if(watchout == 0 && i + 1 < nlin && lf >= 0){
			tohcol(c);
			drawvert(lf, i, c, lwid);
			vct += 2;
		}
		if(rightl && c + 1 == ncol)
			continue;
		vforml := i;
		for(lf = prev(nl); lf >= 0 && vspen(table[lf][c].col); lf = prev(lf))
			vforml = lf;
		form := ctype(vforml, c);
		if(form != 's'){
			rct := reg(c, CLEFT);
			if(form == 'a')
				rct = reg(c, CMID);
			if(form == 'n' && table[nl][c].rcol.k != VNIL && lused[c] == 0)
				rct = reg(c, CMID);
			out("\\h'|\\n(" + s2(rct) + "u'");
		}
		ss = table[nl][c].col;
		fnt := font(c, stynum[vforml]);
		size := csize[c][stynum[vforml]];
		if((flags[c][stynum[nl]] & HALFUP) != 0 && pr1403 == 0)
			uphalf = 1;
		ct := ctype(vforml, c);
		dodata := 1;
		if((ct == 'n' || ct == 'a') && table[nl][c].rcol.k != VNIL){
			if(lused[c]){	# Zero field width
				ip = prev(nl);
				if(ip >= 0)
					if(vspen(table[ip][c].col)){
						if(exvspen == 0){
							out("\\v'-(\\n(\\*(#du-\\n(^" + ch(c + 'a') + "u");
							if(cmidx)
								out("-((\\n(#-u-\\n(^" + ch(c + 'a') + "u)/2u)");
							vct++;
							if(pr1403)	# must round to whole lines
								out("/1v*1v");
							out("'");
							exvspen = 1;
						}
					}
				out(ch(F1) + ch(F2));
				if(uphalf)
					out("\\u");
				puttext(ss, fnt, size);
				if(uphalf)
					out("\\d");
				out(ch(F1));
			}
			ss = table[nl][c].rcol;
			form = 1;
		}else case ct {
		'c' or 'n' or 'a' =>
			form = 3;
		'r' =>
			form = 2;
		'l' =>
			form = 1;
		'-' or '=' =>
			if(isreal(table[nl][c].col))
				errout(ifile + ": line " + string (iline - 1) + ": Data ignored on table line " +
					string (i + 1) + "\n");
			makeline(i, c, ct);
			continue;
		* =>
			continue;
		}
		if(dodata){
			realsplit := (ct == 'a' || ct == 'n') && table[nl][c].rcol.k != VNIL;
			v: int;
			if(realsplit)
				v = rused[c];
			else
				v = used[c];
			if(v){	# Zero field width
				# form: 1 left, 2 right, 3 center adjust
				if(ifline(ss)){
					makeline(i, c, ifline(ss));
					continue;
				}
				if(filler(ss)){
					out("\\l'|\\n(" + s2(reg(c, CRIGHT)) + "u\\&" + ss.s[2:] + "'");
					continue;
				}
				ip = prev(nl);
				cmidx = (flags[c][stynum[nl]] & (CTOP | CDOWN)) == 0;
				if(ip >= 0)
					if(vspen(table[ip][c].col)){
						if(exvspen == 0){
							out("\\v'-(\\n(\\*(#du-\\n(^" + ch(c + 'a') + "u");
							if(cmidx)
								out("-((\\n(#-u-\\n(^" + ch(c + 'a') + "u)/2u)");
							vct++;
							if(pr1403)	# round to whole lines
								out("/1v*1v");
							out("'");
						}
					}
				out(ch(F1));
				if(form != 1)
					out(ch(F2));
				if(vspen(ss))
					vspf = 1;
				else{
					if(uphalf)
						out("\\u");
					puttext(ss, fnt, size);
					if(uphalf)
						out("\\d");
				}
				if(form != 2)
					out(ch(F2));
				out(ch(F1));
			}
		}
		ip = prev(nl);
		if(ip >= 0){
			if(vspen(table[ip][c].col)){
				exvspen = (c + 1 < ncol) && vspen(table[ip][c + 1].col) &&
					(topat[c] == topat[c + 1]) &&
					(cmidx == ((flags[c + 1][stynum[nl]] & (CTOP | CDOWN)) == 0)) &&
					(left(i, c + 1).t0 < 0);
				if(exvspen == 0){
					out("\\v'(\\n(\\*(#du-\\n(^" + ch(c + 'a') + "u");
					if(cmidx)
						out("-((\\n(#-u-\\n(^" + ch(c + 'a') + "u)/2u)");
					vct++;
					if(pr1403)	# round to whole lines
						out("/1v*1v");
					out("'");
				}
			}else
				exvspen = 0;
		}
		# if lines need to be split for gcos here is the place for a backslash
		if(vct > 7 && c < ncol){
			out("\n.sp-1\n\\&");
			vct = 0;
		}
	}
	out("\n");
	if(allh(i) && !pr1403)
		out(sys->sprint(".vs \\n(%du\n", SVS));
	if(watchout)
		funnies(i, nl);
	if(vspf){
		for(c = 0; c < ncol; c++)
			if(vspen(table[nl][c].col) && (nl == 0 || (lf = prev(nl)) < 0 ||
			    !vspen(table[lf][c].col))){
				out(".nr ^" + ch('a' + c) + " \\n(#^u\n");
				topat[c] = nl;
			}
	}
}

puttext(s: Val, fnt: string, size: string)
{
	if(s.k == VSTR){
		putfont(fnt);
		putsize(size);
		out(s.s);
		if(fpos(fnt))
			out(sys->sprint("\\f(\\n(%2d", S1));
		if(size != "")
			putsize("0");
	}
}

funnies(stl: int, lin: int)
{
	# write out funny diverted things
	lwid, lf: int;
	out(".mk ##\n");	# rmember current vertical position
	out(sys->sprint(".nr %d \\n(##\n", S1));	# bottom position
	for(c := 0; c < ncol; c++){
		ss := table[lin][c].col;
		if(ss.k != VTXT)
			continue;
		s := ch(ss.n);
		out(".sp |\\n(##u-1v\n");
		out(sys->sprint(".nr %d ", SIND));
		ct := 0;
		pl: int;
		for(pl = stl; pl >= 0 && !isalpha(ct = ctype(pl, c)); pl = prev(pl))
			;
		case ct {
		'n' or 'c' =>
			out("(\\n(" + s2(reg(c, CLEFT)) + "u+\\n(" +
				s2(reg(c - 1 + ctspan(lin, c), CRIGHT)) + "u-\\n(" + s + "-u)/2u\n");
		'l' =>
			out("\\n(" + s2(reg(c, CLEFT)) + "u\n");
		'a' =>
			out("\\n(" + s2(reg(c, CMID)) + "u\n");
		'r' =>
			out("\\n(" + s2(reg(c, CRIGHT)) + "u-\\n(" + s + "-u\n");
		}
		out(sys->sprint(".in +\\n(%du\n", SIND));
		fnt := font(c, stynum[stl]);
		if(fnt != "")
			out(".ft " + fnt + "\n");
		pl = prev(stl);
		if(stl > 0 && pl >= 0 && vspen(table[pl][c].col)){
			out(".sp |\\n(^" + ch('a' + c) + "u\n");
			if((flags[c][stynum[stl]] & (CTOP | CDOWN)) == 0){
				out(sys->sprint(".nr %d \\n(#-u-\\n(^", TMP) + ch('a' + c) + "-\\n(" + s + "|+1v\n");
				out(sys->sprint(".if \\n(%d>0 .sp \\n(%du/2u", TMP, TMP));
				if(pr1403)	# round
					out("/1v*1v");
				out("\n");
			}
		}
		out("." + s + "+\n");
		out(sys->sprint(".in -\\n(%du\n", SIND));
		if(fnt != "")
			out(".ft P\n");
		out(sys->sprint(".mk %d\n", S2));
		out(sys->sprint(".if \\n(%d>\\n(%d .nr %d \\n(%d\n", S2, S1, S1, S2));
	}
	out(sys->sprint(".sp |\\n(%du\n", S1));
	dv := 0;
	for(c = 0; c < ncol; c++){
		if(stl + 1 < nlin)
			(lf, lwid) = left(stl, c);
		if(stl + 1 < nlin && lf >= 0){
			if(dv++ == 0)
				out(".sp -1\n");
			tohcol(c);
			dv++;
			drawvert(lf, stl, c, lwid);
		}
	}
	if(dv)
		out("\n");
}

putfont(fnt: string)
{
	if(fnt != ""){
		if(len fnt > 2)
			fnt = fnt[0:2];
		if(len fnt > 1)
			out("\\f(" + fnt);
		else
			out("\\f" + fnt);
	}
}

putsize(s: string)
{
	if(s != ""){
		if(len s > 1)
			out("\\s(" + s);
		else
			out("\\s" + s);
	}
}

#
# t9.c: write lines for tables over 200 lines
#
yetmore()
{
	for(useln = 0; useln < MAXLIN && table[useln] == nil; useln++)
		;
	if(useln >= MAXLIN)
		error("Wierd.  No data in table.");
	table[0] = table[useln];
	for(useln = nlin - 1; useln >= 0 && (fullbot[useln] || instead[useln] != nil); useln--)
		;
	if(useln < 0)
		error("Wierd.  No real lines in table.");
	domore(leftover);
	line := "";
	for(;;){
		ok: int;
		(line, ok) = gets1(MAXCHS, "");
		if(!ok){
			line = "";
			break;
		}
		if(!domore(line))
			break;
	}
	last = line;
}

domore(dataln: string): int
{
	if(prefix(".TE", dataln))
		return 0;
	if(at(dataln, 0) == '.' && !isdigit(at(dataln, 1))){
		out(dataln + "\n");
		return 1;
	}
	fullbot[0] = 0;
	instead[0] = nil;
	if(len dataln == 1)
		case dataln[0] {
		'_' =>
			fullbot[0] = '-';
			putline(useln, 0);
			return 1;
		'=' =>
			fullbot[0] = '=';
			putline(useln, 0);
			return 1;
		}
	icol: int;
	for(icol = 0; icol < ncol; icol++){
		c := 0;
		i := 0;
		for(; (c = at(dataln, i)) != 0 && c != tab; i++)
			;
		table[0][icol].col = Val(VSTR, dataln[0:i], 0);
		table[0][icol].rcol = NIL;
		if(i < len dataln)
			dataln = dataln[i + 1:];
		else
			dataln = "";
		case ctype(useln, icol) {
		'n' =>
			(col, rcol) := maknew(table[0][icol].col.s);
			table[0][icol].col.s = col;
			table[0][icol].rcol = rcol;
		'a' =>
			table[0][icol].rcol = table[0][icol].col;
			table[0][icol].col = Val(VSTR, "", 0);
		}
		while(ctype(useln, icol + 1) == 's'){	# spanning
			table[0][++icol].col = Val(VSTR, "", 0);
			table[0][icol].rcol = NIL;
		}
		if(c == 0)
			break;
	}
	# C leaves the second part of a number from a line before, and
	# prints what its buffer holds there now
	while(++icol < ncol){
		table[0][icol].col = Val(VSTR, "", 0);
		table[0][icol].rcol = NIL;
	}
	putline(useln, 0);
	return 1;
}

#
# tb.c: check which entries exist
#
checkuse()
{
	for(c := 0; c < ncol; c++){
		used[c] = lused[c] = rused[c] = 0;
		for(i := 0; i < nlin; i++){
			if(instead[i] != nil || fullbot[i])
				continue;
			k := ctype(i, c);
			if(k == '-' || k == '=')
				continue;
			if(k == 'n' || k == 'a'){
				rused[c] |= isreal(table[i][c].rcol);
				if(!isreal(table[i][c].rcol))
					used[c] |= isreal(table[i][c].col);
				if(table[i][c].rcol.k != VNIL)
					lused[c] |= isreal(table[i][c].col);
			}else
				used[c] |= isreal(table[i][c].col);
		}
	}
}

isreal(s: Val): int
{
	if(s.k == VNIL)
		return 0;
	if(s.k == VTXT)
		return 1;
	if(s.s == "")
		return 0;
	return 1;
}

release()
{
}

#
# tc.c: find character not in table to delimit fields
#
COMMON: con "\u0002\u0003\u0005\u0006\u0007!%&#/?,:;<=>@`^~_{}+-*" +
	"ABCDEFGHIJKMNOPQRSTUVWXZabcdefgjkoqrstwxyz";

choochar()
{
	# choose funny characters to delimit fields
	had := array[128] of {* => 0};
	F1 = F2 = 0;
	for(ilin := 0; ilin < nlin; ilin++){
		if(instead[ilin] != nil || fullbot[ilin])
			continue;
		for(icol := 0; icol < ncol; icol++){
			k := ctype(ilin, icol);
			if(k == 0 || k == '-' || k == '=')
				continue;
			s := table[ilin][icol].col;
			if(s.k == VSTR)
				for(i := 0; i < len s.s && s.s[i] != 0; i++)
					if(s.s[i] < 128)
						had[s.s[i]] = 1;
			s = table[ilin][icol].rcol;
			if(s.k == VSTR)
				for(j := 0; j < len s.s && s.s[j] != 0; j++)
					if(s.s[j] < 128)
						had[s.s[j]] = 1;
		}
	}
	# choose first funny character
	f := COMMON + "Y";
	for(i := 0; i < len f; i++){
		if(had[f[i]] == 0){
			F1 = f[i];
			had[F1] = 1;
			break;
		}
	}
	# choose second funny character
	f = COMMON + "u";
	for(i = 0; i < len f; i++){
		if(had[f[i]] == 0){
			F2 = f[i];
			break;
		}
	}
	if(F1 == 0 || F2 == 0)
		error("couldn't find characters to use for delimiters");
}

#
# te.c: error message control, input line count
#
error(s: string)
{
	stdout.flush();
	errout("\n" + ifile + ":" + string iline + ": " + s + "\n");
	errout("tbl quits\n");
	raise "fail:tbl quits";
}

# a line, of up to size - 1 bytes; prev is what C's buffer held, which
# it reads again when one file ends and the next begins
gets1(size: int, prev: string): (string, int)
{
	iline++;
	(s, ok) := fgets(size);
	if(!ok){
		if(swapin() == 0)
			return (nil, 0);
		s = prev;
	}
	s = cstr(s);
	nbl := len s;
	if(nbl > 0 && s[nbl - 1] == '\n')
		s = s[0:nbl - 1];	# remove the newline
	k := nbl - 2;
	for(nbl = 0; k > 0 && at(s, k) == '\\'; k--)
		nbl++;
	if(linstart && nbl % 2){	# fold escaped nl if in table
		(r, rok) := gets1(size - k, nil);
		if(rok)
			s = s[0:k + 1] + r;
	}
	return (s, 1);
}

fgets(size: int): (string, int)
{
	s := "";
	while(len s < size - 1){
		c := tabin.getb();
		if(c == Bufio->EOF)
			break;
		s[len s] = c;
		if(c == '\n')
			break;
	}
	if(s == "")
		return (nil, 0);
	return (s, 1);
}

un1getc(c: int)
{
	if(c == '\n')
		iline--;
	backup[backp++] = c;
	if(backp >= BACKMAX)
		error("too much backup");
}

get1char(): int
{
	c: int;
	if(backp > 0){
		c = backup[--backp];
		if(c == 16rff)	# C's char, signed
			c = EOF;
	}else
		c = getc();
	if(c == EOF){
		if(swapin() == 0)
			error("unexpected EOF");
		c = getc();
	}
	if(c == '\n')
		iline++;
	return c;
}

getc(): int
{
	c := tabin.getb();
	if(c == Bufio->EOF)
		return EOF;
	return c;
}

#
# tf.c: save and restore fill mode around table
#
savefill()
{
	# remembers various things: fill mode, vs, ps in mac 35 (SF)
	out(".de " + string SF + "\n");
	out(".ps \\n(.s\n");
	out(".vs \\n(.vu\n");
	out(".in \\n(.iu\n");
	out(".if \\n(.u .fi\n");
	out(".if \\n(.j .ad\n");
	out(".if \\n(.j=0 .na\n");
	out("..\n");
	out(".nf\n");
	# set obx offset if useful
	out(".nr #~ 0\n");
	out(".if \\n(.T .if n .nr #~ 0.6n\n");
}

rstofill()
{
	out("." + string SF + "\n");
}

endoff()
{
	for(i := 0; i < MAXHEAD; i++)
		if(linestop[i])
			out(".nr #" + ch(linestop[i] + 'a' - 1) + " 0\n");
	for(i = 0; i < texct; i++)
		out(".rm " + ch(texstr[i]) + "+\n");
	out(last + "\n");
}

ifdivert()
{
	out(".ds #d .d\n");
	out(".if \\(ts\\n(.z\\(ts\\(ts .ds #d nl\n");
}

saveline()
{
	out(".if \\n+(b.=1 .nr d. \\n(.c-\\n(c.-1\n");
	linstart = iline;
}

restline()
{
	out(".if \\n-(b.=0 .nr c. \\n(.c-\\n(d.-" + string (iline - linstart) + "\n");
	linstart = 0;
}

cleanfc()
{
	out(".fc\n");
}

#
# tg.c: process included text blocks
#
# the block's name, and what follows its T} on the line
gettext(ilin: int, icol: int, fnt: string, sz: string): (int, string)
{
	startline := iline;
	if(texname == 0)
		error("Too many text block diversions");
	if(textflg == 0){
		out(sys->sprint(".nr %d \\n(.lu\n", SL));	# remember old line length
		textflg = 1;
	}
	out(".eo\n");
	out(".am " + reg(icol, CRIGHT) + "\n");
	out(".br\n");
	out(".di " + ch(texname) + "+\n");
	rstofill();
	if(fnt != "")
		out(sys->sprint(".nr %d \\n(.f\n.ft ", S1) + fnt + "\n");
	out(".ft \\n(.f\n");	# protect font
	vs := vsize[icol][stynum[ilin]];
	if(sz != "" || vs != ""){
		out(sys->sprint(".nr %d \\n(.v\n", S9));
		if(vs == "")
			vs = "\\n(.s+2";
		if(sz != "")
			out(".ps " + sz + "\n");
		out(".vs " + vs + "\n");
		out(sys->sprint(".if \\n(%du>\\n(.vu .sp \\n(%du-\\n(.vu\n", S9, S9));
	}
	if(cll[icol] != "")
		out(".ll " + cll[icol] + "n\n");
	else
		out(sys->sprint(".ll \\n(%du*%du/%du\n", SL, ctspan(ilin, icol), ncol + 1));
	out(".if \\n(.l<\\n(" + s2(reg(icol, CRIGHT)) + " .ll \\n(" + s2(reg(icol, CRIGHT)) + "u\n");
	if(ctype(ilin, icol) == 'a')
		out(".ll -2n\n");
	out(".in 0\n");
	line := "";
	for(;;){
		ok: int;
		(line, ok) = gets1(NOLIMIT, line);	# C's 4096 cut a text block's line
		if(!ok){
			iline = startline;
			error("missing closing T}");
		}
		if(at(line, 0) == 'T' && at(line, 1) == '}' && at(line, 2) == tab)
			break;
		if(line == "T}")
			break;
		out(line + "\n");
	}
	if(fnt != "")
		out(sys->sprint(".ft \\n(%d\n", S1));
	if(sz != "")
		out(".br\n.ps\n.vs\n");
	out(".br\n");
	out(".di\n");
	out(".nr " + ch(texname) + "| \\n(dn\n");
	out(".nr " + ch(texname) + "- \\n(dl\n");
	out("..\n");
	out(".ec \\\n");
	# copy remainder of line
	rest := "";
	if(at(line, 2))
		rest = line[3:];
	oname := texname;
	++texct;
	if(texct < len texstr)
		texname = texstr[texct];
	else
		texname = 0;
	return (oname, rest);
}

untext()
{
	rstofill();
	out(".nf\n");
	out(sys->sprint(".ll \\n(%du\n", SL));
}

#
# ti.c: classify line intersections
#
interv(i: int, c: int): int
{
	ku, kl: int;
	if(c >= ncol || c == 0){
		if(dboxflg){
			if(i == 0)
				return BOT;
			if(i >= nlin)
				return TOP;
			return THRU;
		}
		if(c >= ncol)
			return 0;
	}
	if(i > 0)
		ku = lefdata(i - 1, c);
	else
		ku = 0;
	if(i + 1 >= nlin && allh(i))
		kl = 0;
	else if(allh(i))
		kl = lefdata(i + 1, c);
	else
		kl = lefdata(i, c);
	if(ku == 2 && kl == 2)
		return THRU;
	if(ku == 2)
		return TOP;
	if(kl == BOT)
		return 2;
	return 0;
}

interh(i: int, c: int): int
{
	kl, kr: int;
	if(fb(i) == '=' || (dboxflg && (i == 0 || i >= nlin - 1))){
		if(c == ncol)
			return LEFT;
		if(c == 0)
			return RIGHT;
		return THRU;
	}
	if(i >= nlin)
		return 0;
	kl = 0;
	if(c > 0)
		kl = thish(i, c - 1);
	if(kl <= 1 && i > 0 && allh(up1(i))){
		kl = 0;
		if(c > 0)
			kl = thish(up1(i), c - 1);
	}
	kr = thish(i, c);
	if(kr <= 1 && i > 0 && allh(up1(i))){
		kr = 0;
		if(c > 0)
			kr = thish(up1(i), c);
	}
	if(kl == '=' && kr == '=')
		return THRU;
	if(kl == '=')
		return LEFT;
	if(kr == '=')
		return RIGHT;
	return 0;
}

up1(i: int): int
{
	i--;
	while(ins(i) && i > 0)
		i--;
	return i;
}

#
# tm.c: split numerical fields
#
# the field, and what goes in its second part (nil if it is not a number)
maknew(str: string): (string, Val)
{
	# make two numerical fields
	ba := -1;
	for(i := 0; i < len str; i++)
		if(str[i] == '\\' && at(str, i + 1) == '&')
			ba = i;
	p: int;
	if(ba < 0){
		dpoint := -1;
		for(i = 0; i < len str; i++){
			if(str[i] == '.' && !ineqn(i, str) &&
			    (i > 0 && digit(str[i - 1]) || digit(at(str, i + 1))))
				dpoint = i;
		}
		if(dpoint < 0)
			for(; i > 0; i--){
				if(digit(str[i - 1]) && !ineqn(i, str))
					break;
			}
		if(dpoint < 0 && i == 0)	# not numerical, don't split
			return (str, NIL);
		if(dpoint >= 0)
			i = dpoint;
		p = i;
	}else
		p = ba;
	return (str[0:p], Val(VSTR, str[p:], 0));
}

# whether position i of p is within an equation
ineqn(i: int, p: string): int
{
	ineq := 0;
	for(j := 0; j < len p; j++){
		if(i == j)
			return ineq;
		c := p[j];
		if(ineq == 0 && c == delim1)
			ineq = 1;
		else if(ineq == 1 && c == delim2)
			ineq = 0;
	}
	return 0;
}

#
# tr.c: number register allocation
#
nregs := array[] of {
	# this array must have at least 3*qcol entries or illegal
	# register names will result
	"40", "41", "42", "43", "44", "45", "46", "47", "48", "49",
	"50", "51", "52", "53", "54", "55", "56", "57", "58", "59",
	"60", "61", "62", "63", "64", "65", "66", "67", "68", "69",
	"70", "71", "72", "73", "74", "75", "76", "77", "78", "79",
	"80", "81", "82", "83", "84", "85", "86", "87", "88", "89",
	"90", "91", "92", "93", "94", "95", "96", "97", "4q", "4r",
	"4s", "4t", "4u", "4v", "4w", "4x", "4y", "4z", "4;", "4.",
	"4a", "4b", "4c", "4d", "4e", "4f", "4g", "4h", "4i", "4j",
	"4k", "4l", "4m", "4n", "4o", "4p", "5a", "5b", "5c", "5d",
	"5e", "5f", "5g", "5h", "5i", "5j", "5k", "5l", "5m", "5n",
	"5o", "5p", "5q", "5r", "5s", "5t", "5u", "5v", "5w", "5x",
};

reg(col: int, place: int): string
{
	if((len nregs + 1) * 8 < 2 * 3 * qcol)	# C's sizeof, in bytes
		error("Too many columns for registers");
	i := qcol * place + col;
	if(i < 0 || i >= len nregs)
		return "(null)";
	return nregs[i];
}

#
# ts.c: minor string processing subroutines
#
prefix(small: string, bigs: string): int
{
	small = cstr(small);
	if(len bigs < len small)
		return 0;
	return bigs[0:len small] == small;
}

letter(ch: int): int
{
	return ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z';
}

numb(str: string): int
{
	# convert to integer
	k := 0;
	for(i := 0; i < len str && str[i] >= '0' && str[i] <= '9'; i++)
		k = k * 10 + str[i] - '0';
	return k;
}

digit(x: int): int
{
	return x >= '0' && x <= '9';
}

isdigit(x: int): int
{
	return x >= '0' && x <= '9';
}

isalpha(x: int): int
{
	return letter(x);
}

max(a: int, b: int): int
{
	if(a > b)
		return a;
	return b;
}

min(a: int, b: int): int
{
	if(a < b)
		return a;
	return b;
}

atoi(s: string): int
{
	i := 0;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	n := 0;
	for(; i < len s && digit(s[i]); i++)
		n = n * 10 + s[i] - '0';
	if(neg)
		return -n;
	return n;
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

cstr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			return s[0:i];
	return s;
}

#
# tt.c: subroutines for drawing horizontal lines
#
# C's arrays past the table: what an earlier table left, or nothing
ins(i: int): int
{
	return i >= 0 && i < len instead && instead[i] != nil;
}

fb(i: int): int
{
	if(i < 0 || i >= len fullbot)
		return 0;
	return fullbot[i];
}

ctype(il: int, ic: int): int
{
	if(ins(il))
		return 0;
	if(fb(il))
		return 0;
	if(il < 0 || il >= len stynum)
		return 0;
	il = stynum[il];
	if(ic < 0 || ic >= len style || il < 0 || il >= MAXHEAD)
		return 0;
	return style[ic][il];
}

fspan(i: int, c: int): int
{
	c++;
	return c < ncol && ctype(i, c) == 's';
}

lspan(i: int, c: int): int
{
	if(ctype(i, c) != 's')
		return 0;
	c++;
	if(c < ncol && ctype(i, c) == 's')
		return 0;
	k := 0;
	for(; ctype(i, --c) == 's'; k++)
		;
	return k;
}

ctspan(i: int, c: int): int
{
	c++;
	k := 1;
	for(; c < ncol && ctype(i, c) == 's'; k++)
		c++;
	return k;
}

tohcol(ic: int)
{
	if(ic == 0)
		out("\\h'|0'");
	else
		out("\\h'(|\\n(" + s2(reg(ic, CLEFT)) + "u+|\\n(" + s2(reg(ic - 1, CRIGHT)) + "u)/2u'");
}

allh(i: int): int
{
	# return true if every element in line i is horizontal
	# also at least one must be horizontl
	if(fb(i))
		return 1;
	if(i >= nlin)
		return dboxflg || boxflg;
	one := 0;
	for(c := 0; c < ncol; c++){
		k := thish(i, c);
		if(k == 0)
			return 0;
		if(k == 1)
			continue;
		one = 1;
	}
	return one;
}

thish(i: int, c: int): int
{
	if(c < 0)
		return 0;
	if(i < 0)
		return 0;
	t := ctype(i, c);
	if(t == '_' || t == '-')
		return '-';
	if(t == '=')
		return '=';
	if(t == '^')
		return 1;
	if(fb(i))
		return fb(i);
	if(t == 's')
		return thish(i, c - 1);
	if(t == 0)
		return 1;
	s: Val;
	if(t == 'a')
		s = table[i][c].rcol;
	else
		s = table[i][c].col;
	if(s.k == VNIL || (s.k == VSTR && s.s == ""))
		return 1;
	if(vspen(s))
		return 1;
	if((t = barent(s)) != 0)
		return t;
	return 0;
}

#
# tu.c: draws horizontal lines
#
makeline(i: int, c: int, lintype: int)
{
	cr: int;
	typ := thish(i, c);
	if(typ == 0)
		return;
	shortl := at(table[i][c].col.s, 0) == '\\';
	if(c > 0 && !shortl && thish(i, c - 1) == typ)
		return;
	if(shortl == 0)
		for(cr = c; cr < ncol && (ctype(i, cr) == 's' || typ == thish(i, cr)); cr++)
			;
	else
		for(cr = c + 1; cr < ncol && ctype(i, cr) == 's'; cr++)
			;
	drawline(i, c, cr - 1, lintype, 0, shortl);
}

fullwide(i: int, lintype: int)
{
	cr, cl: int;
	if(!pr1403)
		out(sys->sprint(".nr %d \\n(.v\n.vs \\n(.vu-\\n(.sp\n", SVS));
	cr = 0;
	while(cr < ncol){
		cl = cr;
		while(i > 0 && vspand(prev(i), cl, 1))
			cl++;
		for(cr = cl; cr < ncol; cr++)
			if(i > 0 && vspand(prev(i), cr, 1))
				break;
		if(cl < ncol){
			if(cr < ncol)
				drawline(i, cl, cr - 1, lintype, 1, 0);
			else
				drawline(i, cl, cr, lintype, 1, 0);
		}
	}
	out("\n");
	if(!pr1403)
		out(sys->sprint(".vs \\n(%du\n", SVS));
}

drawline(i: int, cl: int, cr: int, lintype: int, noheight: int, shortl: int)
{
	exhr := "";
	exhl := "";
	lcount := 0;
	case lintype {
	'-' =>
		lcount = 1;
	'=' =>
		if(pr1403)
			lcount = 1;
		else
			lcount = 2;
	SHORTLINE =>
		lcount = 1;
	}
	if(lcount <= 0)
		return;
	nodata := cr - cl >= ncol || noheight || allh(i);
	if(!nodata)
		out("\\v'-.5m'");
	oldpos := 0;
	for(ln := 0; ln < lcount; ln++){
		linpos := 2 * ln - lcount + 1;
		if(linpos != oldpos)
			out(sys->sprint("\\v'%dp'", linpos - oldpos));
		oldpos = linpos;
		if(shortl == 0){
			tohcol(cl);
			if(lcount > 1){
				case interv(i, cl) {
				TOP =>
					if(ln == 0)
						exhl = "1p";
					else
						exhl = "-1p";
				BOT =>
					if(ln == 1)
						exhl = "1p";
					else
						exhl = "-1p";
				THRU =>
					exhl = "1p";
				}
				if(exhl != "")
					out("\\h'" + exhl + "'");
			}else if(lcount == 1){
				case interv(i, cl) {
				TOP or BOT =>
					exhl = "-1p";
				THRU =>
					exhl = "1p";
				}
				if(exhl != "")
					out("\\h'" + exhl + "'");
			}
			if(lcount > 1){
				case interv(i, cr + 1) {
				TOP =>
					if(ln == 0)
						exhr = "-1p";
					else
						exhr = "+1p";
				BOT =>
					if(ln == 1)
						exhr = "-1p";
					else
						exhr = "+1p";
				THRU =>
					exhr = "-1p";
				}
			}else if(lcount == 1){
				case interv(i, cr + 1) {
				TOP or BOT =>
					exhr = "+1p";
				THRU =>
					exhr = "-1p";
				}
			}
		}else
			out("\\h'|\\n(" + s2(reg(cl, CLEFT)) + "u'");
		out(sys->sprint("\\s(\\n(%d", LSIZE));
		if(linsize)
			out(sys->sprint("\\v'-\\n(%dp/6u'", LSIZE));
		if(shortl)
			out("\\l'|\\n(" + s2(reg(cr, CRIGHT)) + "u'");
		else{
			lnch := "\\(ul";
			if(pr1403){
				if(lintype == 2)
					lnch = "=";
				else
					lnch = "\\(ru";
			}
			if(cr + 1 >= ncol)
				out("\\l'|\\n(TWu" + exhr + lnch + "'");
			else
				out("\\l'(|\\n(" + s2(reg(cr, CRIGHT)) + "u+|\\n(" + s2(reg(cr + 1, CLEFT)) +
					"u)/2u" + exhr + lnch + "'");
		}
		if(linsize)
			out(sys->sprint("\\v'\\n(%dp/6u'", LSIZE));
		out("\\s0");
	}
	if(oldpos != 0)
		out(sys->sprint("\\v'%dp'", -oldpos));
	if(!nodata)
		out("\\v'+.5m'");
}

getstop()
{
	stopp := 1;
	for(i := 0; i < MAXLIN; i++)
		linestop[i] = 0;
	for(i = 0; i < nlin; i++)
		for(c := 0; c < ncol; c++){
			k := left(i, c).t0;
			if(k >= 0 && linestop[k] == 0)
				linestop[k] = ++stopp;
		}
	if(boxflg || allflg || dboxflg)
		linestop[0] = 1;
}

# the line where a line to the left of (i, c) starts (-1 if there is
# none), and its kind
left(i: int, c: int): (int, int)
{
	if(i < 0)
		return (-1, 0);
	kind := lefdata(i, c);
	if(kind == 0)
		return (-1, 0);
	if(i + 1 < nlin)
		if(lefdata(next(i), c) == kind)
			return (-1, 0);
	li := i;
	while(i >= 0 && lefdata(i, c) == kind){
		li = i;
		i = prev(li);
	}
	if(prev(li) == -1)
		li = 0;
	for(lj := i + 1; lj < li; lj++)
		if(ins(lj) && cstr(instead[lj]) == ".TH")
			return (li, kind);
	for(i = i + 1; i < li; i++)
		if(fb(i))
			li = i;
	return (li, kind);
}

lefdata(i: int, c: int): int
{
	if(i >= nlin)
		i = nlin - 1;
	if(ctype(i, c) == 's'){
		ck: int;
		for(ck = c; ctype(i, ck) == 's'; ck--)
			;
		if(thish(i, ck) == 0)
			return 0;
	}
	if(i < 0)
		i = 0;
	i = stynum[i];
	if(c < 0 || c >= len lefline || i < 0 || i >= MAXHEAD)
		i = 0;
	else
		i = lefline[c][i];
	if(i > 0)
		return i;
	if(dboxflg && c == 0)
		return 2;
	if(allflg)
		return 1;
	if(boxflg && c == 0)
		return 1;
	return 0;
}

next(i: int): int
{
	while(i + 1 < nlin){
		i++;
		if(!fb(i) && !ins(i))
			break;
	}
	return i;
}

prev(i: int): int
{
	while(--i >= 0 && (fb(i) || ins(i)))
		;
	return i;
}

#
# tv.c: draw vertical lines
#
drawvert(start: int, end: int, c: int, lwid: int)
{
	exb := "";
	ext := "";
	tp := 0;
	end++;
	vm := 'v';
	# note: nr 35 has value of 1m outside of linesize
	while(ins(end))
		end++;
	for(ln := 0; ln < lwid; ln++){
		epb := 0;
		ept := 0;
		pos := -ln - lwid + 1;
		if(pos != tp)
			out(sys->sprint("\\h'%dp'", pos - tp));
		tp = pos;
		if(end < nlin){
			if(fb(end) || (!ins(end) && allh(end)))
				epb = 2;
			else
				case midbar(end, c) {
				'-' =>
					exb = "1v-.5m";
				'=' =>
					exb = "1v-.5m";
					epb = 1;
				}
		}
		if(lwid > 1)
			case interh(end, c) {
			THRU =>
				epb -= 1;
			RIGHT =>
				if(ln == 0)
					epb += 1;
				else
					epb += -1;
			LEFT =>
				if(ln == 1)
					epb += 1;
				else
					epb += -1;
			}
		if(lwid == 1)
			case interh(end, c) {
			THRU =>
				epb -= 1;
			RIGHT or LEFT =>
				epb += 1;
			}
		if(start > 0){
			sl := start - 1;
			while(sl >= 0 && ins(sl))
				sl--;
			if(sl >= 0 && (fb(sl) || allh(sl)))
				ept = 0;
			else if(sl >= 0)
				case midbar(sl, c) {
				'-' =>
					ext = ".5m";
				'=' =>
					ext = ".5m";
					ept = -1;
				* =>
					vm = 'm';
				}
			else
				ept = -4;
		}else if(start == 0 && allh(0)){
			ept = 0;
			vm = 'm';
		}
		if(lwid > 1)
			case interh(start, c) {
			THRU =>
				ept += 1;
			LEFT =>
				if(ln == 0)
					ept += 1;
				else
					ept += -1;
			RIGHT =>
				if(ln == 1)
					ept += 1;
				else
					ept += -1;
			}
		else if(lwid == 1)
			case interh(start, c) {
			THRU =>
				ept += 1;
			LEFT or RIGHT =>
				ept -= 1;
			}
		if(exb != "")
			out("\\v'" + exb + "'");
		if(epb)
			out(sys->sprint("\\v'%dp'", epb));
		out(sys->sprint("\\s(\\n(%d", LSIZE));
		if(linsize)
			out(sys->sprint("\\v'-\\n(%dp/6u'", LSIZE));
		out("\\h'-\\n(#~u'");	# adjustment for T450 nroff boxes
		# adjustment to make vertical and horizontal lines meet properly
		out(sys->sprint("\\h'-\\n(%dp*7u/100u'", LSIZE));
		out(sys->sprint("\\v'\\n(%dp*2u/100u'", LSIZE));
		vu := "\\n(35u";
		if(vm == 'v')
			vu = "1v";
		out("\\L'|\\n(#" + ch(linestop[start] + 'a' - 1) + "u-" + vu);
		if(ext != "")
			out("-(" + ext + ")");
		if(exb != "")
			out("-(" + exb + ")");
		pos = ept - epb;
		if(pos){
			if(pos >= 0)
				out("+");
			out(sys->sprint("%dp", pos));
		}
		# the string #d is either "nl" or ".d" depending on
		# diversions; on GCOS not the same
		out("'\\s0\\v'\\n(\\*(#du-\\n(#" + ch(linestop[start] + 'a' - 1) + "u+" + vu);
		if(ext != "")
			out("+" + ext);
		if(ept){
			if(-ept > 0)
				out("+");
			out(sys->sprint("%dp", -ept));
		}
		out("'");
		if(linsize)
			out(sys->sprint("\\v'\\n(%dp/6u'", LSIZE));
	}
}

midbar(i: int, c: int): int
{
	k := midbcol(i, c);
	if(k == 0 && c > 0)
		k = midbcol(i, c - 1);
	return k;
}

midbcol(i: int, c: int): int
{
	ct: int;
	while((ct = ctype(i, c)) == 's')
		c--;
	if(ct == '-' || ct == '=')
		return ct;
	if(i < 0 || i >= len table || table[i] == nil || c < 0 || c >= len table[i])
		return barent(NIL);
	if((ct = barent(table[i][c].col)) != 0)
		return ct;
	return 0;
}

barent(v: Val): int
{
	if(v.k == VNIL)
		return 1;
	if(v.k != VSTR)
		return 0;
	s := v.s;
	j := 0;
	if(at(s, 0) == '\\')
		j++;
	if(at(s, j + 1) != 0)
		return 0;
	case at(s, j) {
	'_' =>
		return '-';
	'=' =>
		return '=';
	}
	return 0;
}
