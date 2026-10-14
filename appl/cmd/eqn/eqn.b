implement Eqn;

#
# eqn - troff's preprocessor for mathematics
#
# A translation of Ali Gholami Rudi's Neateqn into Limbo; for the same
# input it writes the same output, byte for byte, but where Neateqn
# loops for ever (a "right" or "above" out of place: reported here, and
# passed). Beyond Neateqn: "ifdisplay A B" sets A in a display's style
# and B in text's (a display's larger sum, an inline one's smaller);
# "set text_limits 1" puts an operator's limits beside it in text, as
# TeX does; a bracket has up to 15 sizes (Neateqn's 7).
#
# Equations are boxes, made by asking troff (with registers and strings
# of its own) for the sizes of their parts, as TeX's rules for setting
# them (the numbers in box.b) say.
#
# Its text is handled as bytes: each byte of the input is a character
# of the strings here (from 0 to 255), and each is written back as the
# byte it was, so that UTF-8 is read as Neateqn reads it.
#
# Copyright (C) 2014-2017 Ali Gholami Rudi <ali at rudi dot ir>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Eqn: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};


LNLEN: con 1000;
NPILES: con 32;
NSIZES: con 16;

# registers neateqn uses
EQNSZ: con ".eqnsz";	# the point size around
EQNFN: con ".eqnfn";	# the font around
EQNS: con "10";		# the line an inline equation is collected in
EQNMK: con ".eqnmk";	# the horizontal mark

# tokens and atoms
T_EOF: con 16r0000;
T_SPACE: con 16r0001;
T_TAB: con 16r0002;
T_KEYWORD: con 16r0003;
T_ORD: con 16r0010;
T_LETTER: con 16r0011;
T_NUMBER: con 16r0012;
T_STRING: con 16r0013;
T_GAP: con 16r0014;
T_BIGOP: con 16r0020;
T_BINOP: con 16r0030;
T_RELOP: con 16r0040;
T_LEFT: con 16r0050;
T_RIGHT: con 16r0060;
T_PUNC: con 16r0070;
T_INNER: con 16r0080;
T_ITALIC: con 16r0100;

T_TOK(t: int): int	{ return t & 16r00ff; }
T_ATOM(t: int): int	{ return t & 16r00f0; }
T_FONT(t: int): int	{ return t & T_ITALIC; }
T_ATOMIDX(t: int): int	{ return ((t >> 4) & 15) - 1; }

# TeX's styles
TS_D: con 16r00;
TS_D0: con 16r01;
TS_T: con 16r02;
TS_T0: con 16r03;
TS_S: con 16r10;
TS_S0: con 16r11;
TS_SS: con 16r20;
TS_SS0: con 16r21;

TS_MK(s, p: int): int	{ return (s << 4) | p; }
TS_0(s: int): int	{ return s & 16r01; }
TS_MK0(s: int): int	{ return s | 16r01; }
TS_SZ(s: int): int	{ return s >> 4; }
TS_DX(s: int): int	{ return s == TS_D || s == TS_D0; }

# flags of eqn_box()
EQN_TSMASK: con 16r00ffff;
EQN_SUB: con 16r020000;
EQN_FROM: con 16r040000;

stdout: ref Iobuf;

gfont := "2";
grfont := "1";
gbfont := "3";
gsize := "\\n[" + EQNSZ + "]";
eqn_lineup := "";	# the lineup's horizontal motion
eqn_lineupreg := 0;	# the register of its width
eqn_mk := 0;		# MK's value

include "src.b";
include "tok.b";
include "def.b";
include "box.b";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "eqn: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:load";
	}
	if(args != nil)
		args = tl args;
	for(; args != nil; args = tl args){
		a := hd args;
		if(len a < 2 || a[0] != '-')
			break;
		if(a[1] == 'c'){
			v: string;
			if(len a > 2)
				v = a[2:];
			else if(tl args != nil){
				args = tl args;
				v = hd args;
			}
			def_choppedset(u8(v));
		}else{
			sys->fprint(sys->fildes(2), "usage: eqn [options] <input >output\n\n" +
				"options:\n" +
				"  -c chars  \tcharacters that chop equations\n");
			raise "fail:usage";
		}
	}
	def_init();
	src_init(bufio->fopen(sys->fildes(0), Bufio->OREAD));
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	{
		for(i := 0; i < len def_macros; i += 2)
			src_define(def_macros[i], def_macros[i + 1]);
		while(!tok_eqn()){
			reg_reset();
			eqn_mk = 0;
			tok_pop();
			printf(".nr " + EQNSZ + " \\n(.s\n");
			printf(".nr " + EQNFN + " \\n(.f\n");
			eqn_lineupreg = nregmk();
			style := TS_D;
			if(tok_inline())
				style = TS_T;
			box := eqn_read(style);
			printf(".nr MK " + string eqn_mk + "\n");
			if(!box_empty(box)){
				tok_eqnout(eqn_lineup + box_toreg(box));
				printf(".ps \\n" + escarg(EQNSZ) + "\n");
				printf(".ft \\n" + escarg(EQNFN) + "\n");
			}
			printf(".lf " + string src_lineget() + "\n");
			eqn_lineup = "";
			nregrm(eqn_lineupreg);
			box_free(box);
		}
	} exception {
	"fail:eqn" =>
		stdout.flush();
		raise "fail:eqn";
	}
	stdout.flush();
}

# write s, its characters bytes
printf(s: string)
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	stdout.write(b, len b);
}

errdie(msg: string)
{
	stdout.flush();
	sys->fprint(sys->fildes(2), "%s", msg);
	raise "fail:eqn";
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

atoi(s: string): int
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	n := 0;
	for(; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		n = n * 10 + s[i] - '0';
	if(neg)
		return -n;
	return n;
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

ispunct(c: int): int
{
	return (c >= 16r21 && c <= 16r2f) || (c >= 16r3a && c <= 16r40) ||
		(c >= 16r5b && c <= 16r60) || (c >= 16r7b && c <= 16r7e);
}

# C's strchr(s, c) != NULL: the NUL ending s is found too
strchr(s: string, c: int): int
{
	if(c == 0)
		return 1;
	c &= 16rff;
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

#
# eqn.c
#

# read equations until delim
eqn_boxuntil(box: ref Box, sz0: int, fn0: string, delim: string): int
{
	sub: ref Box;
	while(tok_get() != nil && tok_jmp(delim)){
		if(tok_get() == "}")
			return 1;
		pre: ref Box;
		if(sub != nil)
			pre = box;
		n := tok_count;
		sub = eqn_box(box.style, pre, sz0, fn0);
		box_merge(box, sub, 0);
		box_free(sub);
		stray(n);
	}
	return 0;
}

# a subscript's size
sizesub(dst, src, style, src_style: int)
{
	if(TS_SZ(style) > TS_SZ(src_style)){
		printf(".nr " + nregname(dst) + " " + nreg(src) + "*7/10\n");
		printf(".if " + nreg(dst) + "<" + string e_minimumsize + " .nr " +
			nregname(dst) + " " + string e_minimumsize + "\n");
	}else
		printf(".nr " + nregname(dst) + " " + nreg(src) + "\n");
}

tok_quotes(s: string): string
{
	if(s != nil && s[0] == '"')
		return s[1:len s - 1];
	return s;
}

tok_improve(s: string): string
{
	if(s == "-")
		return "\\(mi";
	if(s == "+")
		return "\\(pl";
	if(s == "'")
		return "\\(fm";
	return tok_quotes(s);
}

cut(s: string, n: int): string
{
	if(len s >= n)
		return s[0:n - 1];
	return s;
}

eqn_bracketsizes()
{
	sizes := array[NSIZES] of string;
	sign := cut(tok_quotes(tok_poptext(1)), BRLEN);
	n := atoi(tok_poptext(1));
	for(i := 0; i < n; i++){
		size := tok_quotes(tok_poptext(1));
		if(i < NSIZES)
			sizes[i] = cut(size, BRLEN);
	}
	def_sizesput(sign, sizes);
}

eqn_bracketpieces()
{
	sign := cut(tok_quotes(tok_poptext(1)), BRLEN);
	top := cut(tok_quotes(tok_poptext(1)), BRLEN);
	mid := cut(tok_quotes(tok_poptext(1)), BRLEN);
	bot := cut(tok_quotes(tok_poptext(1)), BRLEN);
	cen := cut(tok_quotes(tok_poptext(1)), BRLEN);
	def_piecesput(sign, top, mid, bot, cen);
}

typenum(s: string): int
{
	case s {
	"ord" or "ordinary" =>
		return T_ORD;
	"op" or "operator" =>
		return T_BIGOP;
	"bin" or "binary" =>
		return T_BINOP;
	"rel" or "relation" =>
		return T_RELOP;
	"open" or "opening" =>
		return T_LEFT;
	"close" or "closing" =>
		return T_RIGHT;
	"punct" or "punctuation" =>
		return T_PUNC;
	"inner" =>
		return T_INNER;
	}
	return T_ORD;
}

eqn_chartype()
{
	typ := cut(tok_quotes(tok_poptext(1)), NMLEN);
	gl := cut(tok_quotes(tok_poptext(1)), GNLEN);
	if(typenum(typ) >= 0)
		def_typeput(gl, typenum(typ));
}

eqn_breakcost()
{
	t := cut(tok_quotes(tok_poptext(1)), NMLEN);
	cost := atoi(tok_poptext(1));
	typ := 0;
	if(t != "any")
		typ = typenum(t);
	if(typ >= 0)
		def_brcostput(typ, cost);
}

# eqn's commands; zero if one was read
eqn_commands(): int
{
	if(!tok_jmp("delim")){
		tok_delim();
		return 0;
	}
	if(!tok_jmp("define")){
		tok_macro();
		return 0;
	}
	if(!tok_jmp("gfont")){
		gfont = tok_quotes(tok_poptext(1));
		return 0;
	}
	if(!tok_jmp("grfont")){
		grfont = tok_quotes(tok_poptext(1));
		return 0;
	}
	if(!tok_jmp("gbfont")){
		gbfont = tok_quotes(tok_poptext(1));
		return 0;
	}
	if(!tok_jmp("gsize")){
		sz := tok_quotes(tok_poptext(1));
		if(sz != nil && (sz[0] == '-' || sz[0] == '+'))
			gsize = "\\n" + escarg(EQNSZ) + sz;
		else
			gsize = sz;
		return 0;
	}
	if(!tok_jmp("set")){
		v := tok_poptext(1);
		def_set(v, atoi(tok_poptext(1)));
		return 0;
	}
	if(!tok_jmp("bracketsizes")){
		eqn_bracketsizes();
		return 0;
	}
	if(!tok_jmp("bracketpieces")){
		eqn_bracketpieces();
		return 0;
	}
	if(!tok_jmp("chartype")){
		eqn_chartype();
		return 0;
	}
	if(!tok_jmp("breakcost")){
		eqn_breakcost();
		return 0;
	}
	return 1;
}

# spaces asked for
eqn_gaps(box: ref Box, szreg: int): int
{
	if(!tok_jmp("~")){
		box_puttext(box, T_GAP, "\\h'" + string S_S3() + "u*" + nreg(szreg) + "p/100u'");
		return 0;
	}
	if(!tok_jmp("^")){
		box_puttext(box, T_GAP, "\\h'" + string S_S1() + "u*" + nreg(szreg) + "p/100u'");
		return 0;
	}
	if(!tok_jmp("\t")){
		box_puttext(box, T_GAP, "\t");
		return 0;
	}
	return 1;
}

tok_font(t: int, fnt: string): string
{
	if(fnt != nil)
		return fnt;
	if(t == T_LETTER || t == T_STRING)
		return gfont;
	return grfont;
}

tok_expect(s: string)
{
	if(tok_jmp(s)){
		stdout.flush();
		t := tok_get();
		if(t == nil)
			t = "(null)";
		sys->fprint(sys->fildes(2), "neateqn: expected %s bot got %s\n", s, t);
		raise "fail:eqn";
	}
}

eqn_pile(box: ref Box, sz0: int, fn0: string, adj: int)
{
	pile := array[NPILES] of ref Box;
	n := 0;
	rowspace := 0;
	if(tok_jmp("{")){
		rowspace = atoi(tok_poptext(1));
		tok_expect("{");
	}
	do{
		if(tok_get() == nil)
			errdie("neateqn: unterminated pile\n");
		pile[n++] = box_alloc(sz0, 0, box.style);
	}while(!eqn_boxuntil(pile[n - 1], sz0, fn0, "above"));
	tok_expect("}");
	box_pile(box, pile, adj, rowspace);
	for(i := 0; i < n; i++)
		box_free(pile[i]);
}

eqn_matrix(box: ref Box, sz0: int, fn0: string)
{
	cols := array[NPILES] of array of ref Box;
	for(i := 0; i < NPILES; i++)
		cols[i] = array[NPILES] of ref Box;
	adj := array[NPILES] of {* => 0};
	ncols := 0;
	colspace := 0;
	rowspace := 0;
	if(tok_jmp("{")){
		colspace = atoi(tok_poptext(1));
		tok_expect("{");
	}
	for(;;){
		if(!tok_jmp("col") || !tok_jmp("ccol"))
			adj[ncols] = 'c';
		else if(!tok_jmp("lcol"))
			adj[ncols] = 'l';
		else if(!tok_jmp("rcol"))
			adj[ncols] = 'r';
		else
			break;
		nrows := 0;
		if(tok_jmp("{")){
			i = atoi(tok_poptext(1));
			if(i > rowspace)
				rowspace = i;
			tok_expect("{");
		}
		do{
			if(tok_get() == nil)
				errdie("neateqn: unterminated matrix col\n");
			cols[ncols][nrows++] = box_alloc(sz0, 0, box.style);
		}while(!eqn_boxuntil(cols[ncols][nrows - 1], sz0, fn0, "above"));
		tok_expect("}");
		ncols++;
	}
	tok_expect("}");
	box_matrix(box, ncols, cols, adj, colspace, rowspace);
	for(i = 0; i < ncols; i++)
		for(j := 0; j < NPILES; j++)
			if(cols[i][j] != nil)
				box_free(cols[i][j]);
}

italic(fnt: string): int
{
	if(fnt == "I" || fnt == "2" || fnt == gfont)
		return T_ITALIC;
	return 0;
}

# a box without fractions
# pass an operand, unset: a token, or a group in braces
eqn_skip()
{
	tok_blanks();
	if(tok_get() == nil)
		return;
	if(tok_jmp("{")){
		tok_pop();
		return;
	}
	for(depth := 1; depth > 0 && tok_get() != nil; tok_pop()){
		if(tok_get() == "{")
			depth++;
		else if(tok_get() == "}")
			depth--;
	}
}

eqn_left(flg: int, pre: ref Box, sz0: int, fn0: string): ref Box
{
	left := "";
	right := "";
	fnt := "";
	sz := sz0;
	dx := 0;
	dy := 0;
	style := EQN_TSMASK & flg;
	if(fn0 != nil)
		fnt = fn0;
	while(!eqn_commands())
		;
	ptcur := 0;
	if(pre != nil)
		ptcur = pre.tcur;
	box := box_alloc(sz, ptcur, style);
	if(!eqn_gaps(box, sz)){
		while(!eqn_gaps(box, sz))
			;
		return box;
	}
	for(;;){
		if(!tok_jmp("fat")){
		}else if(!tok_jmp("roman")){
			fnt = grfont;
		}else if(!tok_jmp("italic")){
			fnt = gfont;
		}else if(!tok_jmp("bold")){
			fnt = gbfont;
		}else if(!tok_jmp("font")){
			fnt = tok_poptext(1);
		}else if(!tok_jmp("size")){
			sz = box_size(box, tok_poptext(1));
		}else if(!tok_jmp("fwd")){
			dx += atoi(tok_poptext(1));
		}else if(!tok_jmp("back")){
			dx -= atoi(tok_poptext(1));
		}else if(!tok_jmp("down")){
			dy += atoi(tok_poptext(1));
		}else if(!tok_jmp("up")){
			dy -= atoi(tok_poptext(1));
		}else
			break;
	}
	if(!tok_jmp("sqrt")){
		sqrt := eqn_left(TS_MK0(style), nil, sz, fnt);
		printf(".ft " + grfont + "\n");
		box_sqrt(box, sqrt);
		box_free(sqrt);
	}else if(!tok_jmp("type")){
		typ := typenum(tok_poptext(1));
		inner := eqn_left(flg, pre, sz, fnt);
		inner.tbeg = inner.tcur = typ;
		box_merge(box, inner, 1);
		box_free(inner);
		box.tcur = typ;
	}else if(!tok_jmp("pile") || !tok_jmp("cpile")){
		eqn_pile(box, sz, fnt, 'c');
	}else if(!tok_jmp("lpile")){
		eqn_pile(box, sz, fnt, 'l');
	}else if(!tok_jmp("rpile")){
		eqn_pile(box, sz, fnt, 'r');
	}else if(!tok_jmp("matrix")){
		eqn_matrix(box, sz, fnt);
	}else if(!tok_jmp("vcenter")){
		inner := eqn_left(flg, pre, sz, fnt);
		box_vcenter(box, inner);
		box_free(inner);
	}else if(!tok_jmp("ifdisplay")){
		# ifdisplay A B: A in a display's style, else B (not Neateqn's)
		if(!TS_DX(style))
			eqn_skip();
		inner := eqn_left(flg, pre, sz, fnt);
		if(TS_DX(style))
			eqn_skip();
		box_merge(box, inner, 0);
		box_free(inner);
	}else if(!tok_jmp("{")){
		eqn_boxuntil(box, sz, fnt, "}");
	}else if(!tok_jmp("left")){
		inner := box_alloc(sz, 0, style);
		left = cut(tok_quotes(tok_poptext(0)), NMLEN);
		eqn_boxuntil(inner, sz, fnt, "right");
		right = cut(tok_quotes(tok_poptext(0)), NMLEN);
		printf(".ft " + grfont + "\n");
		l, r: string;
		if(left != "")
			l = left;
		if(right != "")
			r = right;
		box_wrap(box, inner, l, r);
		box_free(inner);
	}else if(tok_get() != nil && tok_type() != T_KEYWORD){
		if(dx || dy)
			box_move(box, dy, dx);
		box_putf(box, "\\s" + escarg(nreg(sz)));
		do{
			cfn := tok_font(tok_type(), fnt);
			box_puttext(box, tok_type() | italic(cfn), "\\f" + escarg(cfn) + tok_improve(tok_get()));
			chops := tok_chops(0);
			tok_pop();
			if(chops)	# what was read split it
				break;
		}while(!tok_chops(0));	# the next splits it
		if(dx || dy)
			box_move(box, -dy, -dx);
	}
	while(tok_get() != nil){
		if(!tok_jmp("dyad")){
			printf(".ft " + grfont + "\n");
			box_accent(box, "\\(ab");
		}else if(!tok_jmp("bar")){
			printf(".ft " + grfont + "\n");
			box_bar(box);
		}else if(!tok_jmp("under")){
			printf(".ft " + grfont + "\n");
			box_under(box);
		}else if(!tok_jmp("vec")){
			printf(".ft " + grfont + "\n");
			box_accent(box, "\\s[\\n(.s/2u]\\(->\\s0");
		}else if(!tok_jmp("tilde")){
			printf(".ft " + grfont + "\n");
			box_accent(box, "\\s[\\n(.s*3u/4u]\\(ap\\s0");
		}else if(!tok_jmp("hat")){
			printf(".ft " + grfont + "\n");
			box_accent(box, u8("ˆ"));
		}else if(!tok_jmp("dot")){
			printf(".ft " + grfont + "\n");
			box_accent(box, ".");
		}else if(!tok_jmp("dotdot")){
			printf(".ft " + grfont + "\n");
			box_accent(box, "..");
		}else
			break;
	}
	sub_sub, sub_sup, sub_from, sub_to: ref Box;
	subsz := nregmk();
	if(!tok_jmp("sub")){
		sizesub(subsz, sz0, ts_sup(style), style);
		sub_sub = eqn_left(ts_sup(style) | EQN_SUB, nil, subsz, fn0);
	}
	if((sub_sub != nil || !(flg & EQN_SUB)) && !tok_jmp("sup")){
		sizesub(subsz, sz0, ts_sub(style), style);
		sub_sup = eqn_left(ts_sub(style), nil, subsz, fn0);
	}
	if(sub_sub != nil || sub_sup != nil)
		box_sub(box, sub_sub, sub_sup);
	if(!tok_jmp("from")){
		sizesub(subsz, sz0, ts_sub(style), style);
		sub_from = eqn_left(ts_sub(style) | EQN_FROM, nil, subsz, fn0);
	}
	if((sub_from != nil || !(flg & EQN_FROM)) && !tok_jmp("to")){
		sizesub(subsz, sz0, ts_sup(style), style);
		sub_to = eqn_left(ts_sup(style), nil, subsz, fn0);
	}
	if((sub_from != nil || sub_to != nil) && e_textlimits && !TS_DX(style) && box.tcur == T_BIGOP){
		box_sub(box, sub_from, sub_to);
	}else if(sub_from != nil || sub_to != nil){
		inner := box_alloc(sz0, 0, style);
		box_from(inner, box, sub_from, sub_to);
		box_free(box);
		box = inner;
	}
	nregrm(subsz);
	if(sub_sub != nil)
		box_free(sub_sub);
	if(sub_sup != nil)
		box_free(sub_sup);
	if(sub_from != nil)
		box_free(sub_from);
	if(sub_to != nil)
		box_free(sub_to);
	return box;
}

# a box
eqn_box(flg: int, pre: ref Box, sz0: int, fn0: string): ref Box
{
	style := flg & EQN_TSMASK;
	box := eqn_left(flg, pre, sz0, fn0);
	while(!tok_jmp("over")){
		sub_num := box;
		sub_den := eqn_left(TS_MK0(style), nil, sz0, fn0);
		ptcur := 0;
		if(pre != nil)
			ptcur = pre.tcur;
		box = box_alloc(sz0, ptcur, style);
		printf(".ft " + grfont + "\n");
		box_over(box, sub_num, sub_den);
		box_free(sub_num);
		box_free(sub_den);
	}
	return box;
}

# a token no box begins with (right or above out of place), if one was
# not read since n: past it, said so; Neateqn reads it again, for ever
stray(n: int)
{
	if(tok_count == n && tok_get() != nil){
		stdout.flush();
		sys->fprint(sys->fildes(2), "eqn: %s out of place, line %d\n", tok_get(), src_lineget());
		tok_pop();
	}
}

# an equation, inline or a block
eqn_read(style: int): ref Box
{
	szreg := nregmk();
	printf(".nr " + nregname(szreg) + " " + gsize + "\n");
	box := box_alloc(szreg, 0, style);
	while(tok_get() != nil){
		if(!tok_jmp("mark")){
			if(!eqn_mk)
				eqn_mk = 1;
			box_markpos(box, EQNMK);
			continue;
		}
		if(!tok_jmp("lineup")){
			eqn_mk = 2;
			box_markpos(box, nregname(eqn_lineupreg));
			eqn_lineup = "\\h'\\n" + escarg(EQNMK) + "u-" + nreg(eqn_lineupreg) + "u'";
			continue;
		}
		n := tok_count;
		sub := eqn_box(style, box, szreg, nil);
		box_merge(box, sub, 1);
		box_free(sub);
		stray(n);
	}
	box_vertspace(box);
	nregrm(szreg);
	return box;
}

#
# reg.c: troff's registers
#

NREGS: con 2048;

sreg_max := 0;
sreg_free := array[NREGS] of {* => 0};
sreg_n := 0;
nreg_max := 0;
nreg_free := array[NREGS] of {* => 0};
nreg_n := 0;

regname(id: int): string
{
	if(id < 10)
		return "0" + string id;
	return string id;
}

sregmk(): int
{
	id: int;
	if(sreg_n)
		id = sreg_free[--sreg_n];
	else
		id = ++sreg_max;
	return id;
}

sregrm(id: int)
{
	sreg_free[sreg_n++] = id;
}

sregname(id: int): string
{
	return regname(id);
}

sreg(id: int): string
{
	return "\\*" + escarg(regname(id));
}

nregmk(): int
{
	id: int;
	if(nreg_n)
		id = nreg_free[--nreg_n];
	else
		id = ++nreg_max;
	return id;
}

nregrm(id: int)
{
	nreg_free[nreg_n++] = id;
}

nregname(id: int): string
{
	return regname(id);
}

nreg(id: int): string
{
	return "\\n" + escarg(regname(id));
}

reg_reset()
{
	nreg_max = 0;
	nreg_n = 0;
	sreg_max = 11;
	sreg_n = 0;
}

# the argument of an escape like \s or \f
escarg(arg: string): string
{
	if(len arg < 2)
		return arg;
	if(len arg == 2)
		return "(" + arg;
	return "[" + arg + "]";
}
