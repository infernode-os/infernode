implement Utils;

include "draw.m";

include "sys.m";
	sys: Sys;
include "libc.m";
	libc: Libc;
include "math.m";
	math: Math;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "utils.m";

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};



init(b: Bufio, bo: ref Iobuf)
{
	sys = load Sys Sys->PATH;
	libc = load Libc Libc->PATH;
	math = load Math Math->PATH;
	bufio = b;
	bout = bo;
	breaklen = 60;
}

Lig: adt{
	start: int;	#  accent rune 
	pairs: string;	#  <char,accented version> pairs 
};

ligtab := array[] of {
	Lig ('´',	"AÁaáCĆcćEÉeégģIÍiíıíLĹlĺNŃnńOÓoóRŔrŕSŚsśUÚuúYÝyýZŹzź"),
	Lig ('ˋ',	"AÀaàEÈeèIÌiìıìOÒoòUÙuù"),
	Lig ('¨',	"AÄaäEËeëIÏiïOÖoöUÜuüYŸyÿ"),
	Lig ('¸',	"CÇcçGĢKĶkķLĻlļNŅnņRŖrŗSŞsşTŢtţ"),
	Lig ('˜',	"AÃaãIĨiĩıĩNÑnñOÕoõUŨuũ"),
	Lig ('˘',	"AĂaăEĔeĕGĞgğIĬiĭıĭOŎoŏUŬuŭ"),
	Lig ('˚',	"AÅaåUŮuů"),
	Lig ('˙',	"CĊcċEĖeėGĠgġIİLĿlŀZŻzż"),
	Lig ('.',	""),
	Lig ('⌢',	"AÂaâCĈcĉEÊeêGĜgĝHĤhĥIÎiîıîJĴjĵOÔoôSŜsŝUÛuûWŴwŵYŶyŷ"),
	Lig ('̯',	""),
	Lig ('˛',	"AĄaąEĘeęIĮiįıįUŲuų"),
	Lig ('¯',	"AĀaāEĒeēIĪiīıīOŌoōUŪuū"),
	Lig ('ˇ',	"CČcčDĎdďEĚeěLĽlľNŇnňRŘrřSŠsšTŤtťZŽzž"),
	Lig ('ʽ',	""),
	Lig ('ʼ',	""),
	Lig ('̮',	""),
};

multitab := array[] of {
	"ʽα",
	"ʼα",
	"and",
	"a/q",
	"<|",
	"..",
	"...",
	"ʽε",
	"ʼε",
	"——",
	"ʽη",
	"ʼη",
	"ʽι",
	"ʼι",
	"ct",
	"ff",
	"ffi",
	"ffl",
	"fl",
	"fi",
	"ɫɫ",
	"st",
	"ʽο",
	"ʼο",
	"or",
	"ʽρ",
	"ʼρ",
	"~~",
	"ʽυ",
	"ʼυ",
	"ʽω",
	"ʼω",
	"oe",
	"  ",
};

latin_fold_tab := array[64] of {
# 	Table to fold latin 1 characters to ASCII equivalents
# 	based at Rune value 0xc0
#	 À    Á    Â    Ã    Ä    Å    Æ    Ç
#	 È    É    Ê    Ë    Ì    Í    Î    Ï
#	 Ð    Ñ    Ò    Ó    Ô    Õ    Ö    ×
#	 Ø    Ù    Ú    Û    Ü    Ý    Þ    ß
#	 à    á    â    ã    ä    å    æ    ç
#	 è    é    ê    ë    ì    í    î    ï
#	 ð    ñ    ò    ó    ô    õ    ö    ÷
#	 ø    ù    ú    û    ü    ý    þ    ÿ

	'a','a','a','a','a','a','a','c',
	'e','e','e','e','i','i','i','i',
	'd','n','o','o','o','o','o',0,
	'o','u','u','u','u','y',0,0,
	'a','a','a','a','a','a','a','c',
	'e','e','e','e','i','i','i','i',
	'd','n','o','o','o','o','o',0,
	'o','u','u','u','u','y',0,'y',
};

ttabstack := array[20] of array of int;
ntt: int;

bout: ref Iobuf;

#  tab is an array of n Assoc's, sorted by key.
#  Look for key in tab, and return corresponding val
#  or -1 if not there

lookassoc(tab: array of  Assoc, n: int, key: string): int
{
	q:  Assoc;
	i, low, high: int;

	for((low, high) = (-1, n); high > low+1;){
		i = (high+low)/2;
		q = tab[i];
		if(key < q.key)
			high = i;
		else if(key == q.key)
			return q.val;
		else
			low = i;
	}
	return -1;
}

looknassoc(tab: array of  Nassoc, n: int, key: int): int
{
	q:  Nassoc;
	i, low, high: int;

	for((low, high) = (-1, n); high > low+1;){
		i = (high+low)/2;
		q = tab[i];
		if(key < q.key)
			high = i;
		else if(key == q.key)
			return q.val;
		else
			low = i;
	}
	return -1;
}


err(s: string)
{
	sys->fprint(sys->fildes(2), "dict: %s\n", s);
}


#  Write the rune r to bout, keeping track of line length
#  and breaking the lines (at blanks) when they get too long

outrune(r: int)
{
	if(outinhibit)
		return;
	if(++linelen > breaklen && r == ' '){
		bout.putc('\n');
		linelen = 0;
	}
	else
		bout.putc(r);
}

outrunes(rp: string)
{
	for(i:=0;i<len rp;i++)
		outrune(rp[i]);
}

#  Go to new line if not already there; indent if ind != 0.
#  If ind > 1, leave a blank line too.
#  Slight hack: assume if current line is only one or two
#  characters long, then they were spaces.

outnl(ind: int)
{
	if(outinhibit)
		return;
	if(ind){
		if(ind > 1){
			if(linelen > 2)
				bout.putc('\n');
			bout.puts("\n  ");
		}else if(linelen == 0)
			bout.puts("  ");
		else if(linelen == 1)
			bout.putc(' ');
		else if(linelen != 2)
			bout.puts("\n  ");
		linelen = 2;
	}else if(linelen){
		bout.putc('\n');
		linelen = 0;
	}
}

#  Fold the runes in null-terminated rp.
#  Use the sort(1) definition of folding (uppercase to lowercase,
#  latin1-accented characters to corresponding unaccented chars)

fold(rp: string): string
{
	r: int;

	for(i := 0; i < len rp; i++){
		r = rp[i];
		if(16rc0 <= r && r <= 16rff && latin_fold_tab[r-16rc0])
			r = latin_fold_tab[r-16rc0];
		if(16r41 <= r && r <= 16r5a)
			r = r-'A'+'a';
		rp[i] = r;
	}
	return rp;
}

#  See if there is a rune corresponding to the accented
#  version of r with accent acc (acc in [LIGS..LIGE-1]),
#  and return it if so, else return NONE.

#  Runes for special purposes (0xe800-0xfdff is Private Use Area),
#  as in Plan 9's dict.h; every dictionary module must agree.
NONE : con 16re800;
TAGS, TAGE, SPCS, PAR, LIGS : con NONE + 1 + iota;
LACU, LGRV, LUML, LCED, LTIL, LBRV, LRNG, LDOT, LDTB, LFRN, LFRB, LOGO, LMAC,
LHCK, LASP, LLEN, LBRB, LIGE: con iota + LIGS;
liglookup(acc: int, r: int): int
{
	p: string;

	if(acc < LIGS || acc >= LIGE)
		return NONE;
	for(p = ligtab[acc-LIGS].pairs; len p >= 2; p = p[2: ])
		if(p[0] == r)
			return p[1];
	return NONE;
}


#  Maintain a translation table stack (a translation table
#  is an array of Runes indexed by bytes or 7-bit bytes).
#  If starting is true, push the curtab onto the stack
#  and return newtab; else pop the top of the stack and
#  return it.
#  If curtab is 0, initialize the stack and return.

changett(curtab: array of int, newtab: array of int, starting: int): array of int
{
	if(curtab == nil){
		ntt = 0;
		return nil;
	}
	if(starting){
		if(ntt >= len ttabstack){
			if(debug)
				err("translation stack overflow");
			return curtab;
		}
		ttabstack[ntt++] = curtab;
		return newtab;
	}
	else{
		if(ntt == 0){
			if(debug)
				err("translation stack underflow");
			return curtab;
		}
		return ttabstack[--ntt];
	}
}


# No dictionary in /lib/dict: union onto it, in this name space, the
# server /lib/ndb/dict names (dict(7)).  The login profile mounts it
# too, in the background, but a program that took a name space of its
# own before that was done (Xenith, Acme) never sees it.
mountremote(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	fd := sys->open("/lib/ndb/dict", Sys->OREAD);
	if(fd == nil)
		return "no /lib/ndb/dict";
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "/lib/ndb/dict is empty";
	dial, key: string;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l > 5 && l[0:5] == "dial=")
			dial = l[5:];
		else if(len l > 8 && l[0:8] == "keyfile=")
			key = l[8:];
	}
	if(dial == nil)
		return "no dial= in /lib/ndb/dict";
	args := dial :: "/lib/dict" :: nil;
	if(key != nil)
		args = "-k" :: key :: args;
	else
		args = "-A" :: args;
	m := load Command "/dis/mount.dis";
	if(m == nil)
		return sys->sprint("can't load mount: %r");
	{
		m->init(nil, "mount" :: "-a" :: args);
	} exception e {
	"fail:*" =>
		return e[5:];
	}
	return nil;
}
