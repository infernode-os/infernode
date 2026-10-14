#
# pic.h: definitions
#

PI:	con 3.1415926535897932384626433832795028841971693993751;

MAXWID:	con 8.5;	# default limits max picture to 8.5 x 11;
MAXHT:	con 11.0;	# change to taste without peril

DEFAULT:	con 0;

HEAD1:	con 1;
HEAD2:	con 2;
HEAD12:	con HEAD1 + HEAD2;
INVIS:	con 4;
CW_ARC:	con 8;		# clockwise arc
DOTBIT:	con 16;		# line styles
DASHBIT:	con 32;
FILLBIT:	con 64;	# gray-fill on boxes, etc.
NOEDGEBIT:	con 128;	# no edge on filled object

CENTER:	con 8r01;	# text attributes
LJUST:	con 8r02;
RJUST:	con 8r04;
ABOVE:	con 8r10;
BELOW:	con 8r20;
SPREAD:	con 8r40;

SCALE:	con 1.0;	# default scale: units/inch
WID:	con 0.75;	# default width for boxes and ellipses
WID2:	con 0.375;
HT:	con 0.5;	# default height and line length
HT2:	con HT / 2.0;
HT5:	con HT / 5.0;
HT10:	con HT / 10.0;

# these have to be like so, so that we can write things like R & V, etc.
H:	con 0;
V:	con 1;
R_DIR:	con 0;
U_DIR:	con 1;
L_DIR:	con 2;
D_DIR:	con 3;

# input sources
String:	con 8r01;
Macro:	con 8r02;
File:	con 8r04;
Char:	con 8r10;
Thru:	con 8r20;
Free:	con 8r40;

MAXARGS:	con 20;

EOF:	con -1;

# C's NULL char *: no byte is this character
NULLP:	con "￿";

Obj: adt {	# stores various things in variable length
	typ:	int;
	count:	int;	# number of things
	nobj:	int;	# index in objlist
	mode:	int;	# hor or vert
	x:	real;	# coord of "center" (a float)
	y:	real;
	nt1:	int;	# 1st index in text[] for this object
	nt2:	int;	# 2nd; difference is #text strings
	attr:	int;	# HEAD, CW, INVIS, etc., go here
	size:	int;	# linesize
	nhead:	int;	# arrowhead style
	symtab:	ref Sym;	# symtab for [...]
	ddval:	real;	# value of dot/dash expression (a float)
	fillval:	real;	# gray scale value (a float)
	val:	array of real;	# floats
};

Sym: adt {
	name:	string;
	typ:	int;
	val:	YYSTYPE;
	next:	ref Sym;
};

Attr: adt {	# attribute of an object
	typ:	int;
	sub:	int;
	val:	YYSTYPE;
};

Txt: adt {
	typ:	int;	# CENTER, LJUST, etc.
	val:	string;
};

Src: adt {	# input source
	typ:	int;	# Macro, String, File
	s:	string;	# if String or Macro
	pos:	int;
};

Infile: adt {
	fin:	ref Iobuf;
	fname:	string;
	lineno:	int;
};

Arg: adt {	# argument stack
	argstk:	array of string;
};

Pushstack: adt {
	x:	real;
	y:	real;
	hvmode:	int;
	xmin:	real;
	ymin:	real;
	xmax:	real;
	ymax:	real;
	symtab:	ref Sym;
};

ishor(n: int): int
{
	return (n & V) == 0;
}

isright(n: int): int
{
	return n == R_DIR;
}

isleft(n: int): int
{
	return n == L_DIR;
}

isdown(n: int): int
{
	return n == D_DIR;
}

isup(n: int): int
{
	return n == U_DIR;
}

# C's float: a real rounded to single precision
f32(x: real): real
{
	return math->bits32real(math->realbits32(x));
}

# C's (long) of a double: towards zero
clong(x: real): big
{
	# a NaN, or past a long: what x86-64's conversion gives
	if(math->isnan(x) || x >= 9.223372036854775808e18 || x < -9.223372036854775808e18)
		return big 16r8000000000000000;
	if(x >= 0.0)
		return big math->floor(x);
	return big math->ceil(x);
}

cint(x: real): int
{
	return int clong(x);
}

# glibc's rand(), never seeded
randr: array of int;
randi := 0;

crand(): int
{
	if(randr == nil){
		r := array[344] of int;
		r[0] = 1;
		for(i := 1; i < 31; i++){
			h := big r[i - 1] * big 16807 % big 2147483647;
			if(h < big 0)
				h += big 2147483647;
			r[i] = int h;
		}
		for(i = 31; i < 34; i++)
			r[i] = r[i - 31];
		for(i = 34; i < 344; i++)
			r[i] = r[i - 31] + r[i - 3];
		randr = array[34] of int;
		randr[0:] = r[344 - 34:];
		randi = 0;
	}
	# the next: r[i-31] + r[i-3], kept in a ring of 34
	n := randr[(randi + 34 - 31) % 34] + randr[(randi + 34 - 3) % 34];
	randr[randi] = n;
	randi = (randi + 1) % 34;
	return (n >> 1) & 16r7fffffff;
}
