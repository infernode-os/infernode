#
# def.c: definitions and operators
#

NMLEN: con 32;
GNLEN: con 32;
BRLEN: con 64;

# the default macros, name and definition
def_macros := array[] of {
	"<-", "\\(<-",
	"<=", "\\(<=",
	">=", "\\(>=",
	"==", "\\(==",
	"->", "\\(->",
	"!=", "\\(!=",
	"+-", "\\(+-",
	"...", "vcenter roman \"\\ .\\ .\\ .\\ \"",
	",...,", "roman \",\\ .\\ .\\ .\\ ,\\|\"",
	"ALPHA", "\\(*A",
	"BETA", "\\(*B",
	"CHI", "\\(*X",
	"DELTA", "\\(*D",
	"EPSILON", "\\(*E",
	"ETA", "\\(*Y",
	"GAMMA", "\\(*G",
	"IOTA", "\\(*I",
	"KAPPA", "\\(*K",
	"LAMBDA", "\\(*L",
	"MU", "\\(*M",
	"NU", "\\(*N",
	"OMEGA", "\\(*W",
	"OMICRON", "\\(*O",
	"PHI", "\\(*F",
	"PI", "\\(*P",
	"PSI", "\\(*Q",
	"RHO", "\\(*R",
	"SIGMA", "\\(*S",
	"TAU", "\\(*T",
	"THETA", "\\(*H",
	"UPSILON", "\\(*U",
	"XI", "\\(*C",
	"ZETA", "\\(*Z",
	"alpha", "\\(*a",
	"beta", "\\(*b",
	"chi", "\\(*x",
	"delta", "\\(*d",
	"epsilon", "\\(*e",
	"eta", "\\(*y",
	"gamma", "\\(*g",
	"iota", "\\(*i",
	"kappa", "\\(*k",
	"lambda", "\\(*l",
	"mu", "\\(*m",
	"nu", "\\(*n",
	"omega", "\\(*w",
	"omicron", "\\(*o",
	"phi", "\\(*f",
	"pi", "\\(*p",
	"psi", "\\(*q",
	"rho", "\\(*r",
	"sigma", "\\(*s",
	"tau", "\\(*t",
	"theta", "\\(*h",
	"upsilon", "\\(*u",
	"xi", "\\(*c",
	"zeta", "\\(*z",
	"Im", "roman \"Im\"",
	"Re", "roman \"Re\"",
	"and", "roman \"and\"",
	"approx", "\"\\v'-.2m'\\z\\(ap\\v'.25m'\\(ap\\v'-.05m'\"",
	"arc", "roman \"arc\"",
	"cdot", "\\(c.",
	"cos", "roman \"cos\"",
	"cosh", "roman \"cosh\"",
	"coth", "roman \"coth\"",
	"del", "\\(gr",
	"det", "roman \"det\"",
	"dollar", "roman $",
	"exp", "roman \"exp\"",
	"for", "roman \"for\"",
	"grad", "\\(gr",
	"half", "roman \\(12",
	"if", "roman \"if\"",
	"inf", "\\(if",
	"infinity", "\\(if",
	"int", "{vcenter roman size +2 \\(is}",
	"inter", "roman size +2 \\(ca",
	"lim", "roman \"lim\"",
	"ln", "roman \"ln\"",
	"log", "roman \"log\"",
	"max", "roman \"max\"",
	"min", "roman \"min\"",
	"nothing", "",
	"partial", "\\(pd",
	"prime", "roman \\(fm",
	"prod", "{vcenter roman size +2 \\(pr}",
	"sin", "roman \"sin\"",
	"sinh", "roman \"sinh\"",
	"sum", "{vcenter roman size +2 \\(su}",
	"tan", "roman \"tan\"",
	"tanh", "roman \"tanh\"",
	"times", "\\(mu",
	"union", "roman size +2 \\(cu",
};

binops := array[] of {
	"+", "\\(pl", "−", "-", "\\(mi", "÷", "\\(-:", "\\(di", "×", "xx", "\\(mu", "±", "\\(+-", "⊗", "\\(Ox", "⊕", "\\(O+", "∧", "\\(l&", "∨", "\\(l|", "∩", "\\(ca", "∪", "\\(cu", "⋅", "\\(c.",
};

relops := array[] of {
	"<", ">", ":=", "=", "\\(eq", "≅", "\\(cg", "≤", "\\(<=", "≥", "\\(>=", "≠", "\\(!=", "≡", "\\(==", "≈", "\\(~~", "⊃", "\\(sp", "⊇", "\\(ip", "⊄", "\\(!b", "⊂", "\\(sb", "⊆", "\\(ib", "∈", "\\(mo", "∉", "\\(!m", "↔", "\\(ab", "←", "\\(<-", "↑", "\\(ua", "→", "\\(->", "↓", "\\(da",
};

puncs := array[] of {
	".", ",", ";", ":", "!",
};

bracketleft := array[] of {
	"(", "[", "{", "\\(lc", "\\(lf", "\\(la",
};

bracketright := array[] of {
	")", "]", "}", "\\(rc", "\\(rf", "\\(ra",
};

# rows of 8; the empty after them are free
bracketsizes_init := array[] of {
	"(", "(", "\\N'parenleftbig'", "\\N'parenleftBig'", "\\N'parenleftbigg'", "\\N'parenleftBigg'", "", "",
	")", ")", "\\N'parenrightbig'", "\\N'parenrightBig'", "\\N'parenrightbigg'", "\\N'parenrightBigg'", "", "",
	"[", "[", "\\N'bracketleftbig'", "\\N'bracketleftBig'", "\\N'bracketleftbigg'", "\\N'bracketleftBigg'", "", "",
	"]", "]", "\\N'bracketrightbig'", "\\N'bracketrightBig'", "\\N'bracketrightbigg'", "\\N'bracketrightBigg'", "", "",
	"{", "{", "\\N'braceleftbig'", "\\N'braceleftBig'", "\\N'braceleftbigg'", "\\N'braceleftBigg'", "", "",
	"}", "}", "\\N'bracerightbig'", "\\N'bracerightBig'", "\\N'bracerightbigg'", "\\N'bracerightBigg'", "", "",
	"\\(lc", "\\N'ceilingleft'", "\\N'ceilingleftbig'", "\\N'ceilingleftBig'", "\\N'ceilingleftbigg'", "\\N'ceilingleftBigg'", "\\(lc", "",
	"\\(rc", "\\N'ceilingright'", "\\N'ceilingrightbig'", "\\N'ceilingrightBig'", "\\N'ceilingrightbigg'", "\\N'ceilingrightBigg'", "\\(rc", "",
	"\\(lf", "\\N'floorleft'", "\\N'floorleftbig'", "\\N'floorleftBig'", "\\N'floorleftbigg'", "\\N'floorleftBigg'", "\\(lf", "",
	"\\(rf", "\\N'floorright'", "\\N'floorrightbig'", "\\N'floorrightBig'", "\\N'floorrightbigg'", "\\N'floorrightBigg'", "\\(rf", "",
	"\\(la", "\\(la", "\\N'angbracketleft'", "\\N'angbracketleftbig'", "\\N'angbracketleftBig'", "\\N'angbracketleftbigg'", "\\N'angbracketleftBigg'", "",
	"\\(ra", "\\(ra", "\\N'angbracketright'", "\\N'angbracketrightbig'", "\\N'angbracketrightBig'", "\\N'angbracketrightbigg'", "\\N'angbracketrightBigg'", "",
	"|", "|", "|", "|", "|", "", "", "",
	"\\(sr", "\\(sr", "\\N'radical'", "\\N'radicalbig'", "\\N'radicalBig'", "\\N'radicalbigg'", "\\N'radicalBigg'", "",
};

# rows of 8; the empty after them are free
bracketpieces_init := array[] of {
	"(", "\\(LT", "\\(LX", "\\(LB", "", "", "", "",
	")", "\\(RT", "\\(RX", "\\(RB", "", "", "", "",
	"[", "\\(lc", "\\(lx", "\\(lf", "", "", "", "",
	"]", "\\(rc", "\\(rx", "\\(rf", "", "", "", "",
	"{", "\\(lt", "\\(bv", "\\(lb", "\\(lk", "", "", "",
	"}", "\\(rt", "\\(bv", "\\(rb", "\\(rk", "", "", "",
	"\\(lc", "\\(lc", "\\(lx", "\\(lx", "", "", "", "",
	"\\(rc", "\\(rc", "\\(rx", "\\(rx", "", "", "", "",
	"\\(lf", "\\(lx", "\\(lx", "\\(lf", "", "", "", "",
	"\\(rf", "\\(rx", "\\(rx", "\\(rf", "", "", "", "",
	"|", "|", "|", "|", "", "", "", "",
	"\\(sr", "\\N'radicaltp'", "\\N'radicalvertex'", "\\N'radicalbt'", "", "", "", "",
};

bracketsizes: array of array of string;
bracketpieces: array of array of string;

# the tables, their UTF-8 bytes a character each
def_init()
{
	for(i := 0; i < len def_macros; i++)
		def_macros[i] = u8(def_macros[i]);
	for(i = 0; i < len binops; i++)
		binops[i] = u8(binops[i]);
	for(i = 0; i < len relops; i++)
		relops[i] = u8(relops[i]);
	bracketsizes = rows(bracketsizes_init, 32, NSIZES);
	bracketpieces = rows(bracketpieces_init, 32, 8);
}

# n rows of m; a's are 8 long
rows(a: array of string, n: int, m: int): array of array of string
{
	r := array[n] of array of string;
	for(i := 0; i < n; i++){
		r[i] = array[m] of {* => ""};
		if(8 * i < len a)
			for(j := 0; j < 8; j++)
				r[i][j] = u8(a[8 * i + j]);
	}
	return r;
}

# glyphs' types, as chartype gives them
gtype_g := array[128] of {* => ""};
gtype_t := array[128] of {* => 0};

def_typeput(s: string, typ: int)
{
	i: int;
	for(i = 0; i < len gtype_g && gtype_g[i] != ""; i++)
		if(s == gtype_g[i])
			break;
	if(i < len gtype_g){
		gtype_g[i] = s;
		gtype_t[i] = typ;
	}
}

alookup(a: array of string, s: string): int
{
	for(i := 0; i < len a; i++)
		if(s == a[i])
			return 1;
	return 0;
}

def_type(s: string): int
{
	for(i := 0; i < len gtype_g && gtype_g[i] != ""; i++)
		if(s == gtype_g[i])
			return gtype_t[i];
	if(alookup(puncs, s))
		return T_PUNC;
	if(alookup(binops, s))
		return T_BINOP;
	if(alookup(relops, s))
		return T_RELOP;
	if(alookup(bracketleft, s))
		return T_LEFT;
	if(alookup(bracketright, s))
		return T_RIGHT;
	return -1;
}

pieces_find(sign: string): int
{
	for(i := 0; i < len bracketpieces; i++)
		if(bracketpieces[i][0] == sign)
			return i;
	return -1;
}

# the pieces a bracket is made of: top, mid, bot, cen
def_pieces(sign: string): (string, string, string, string)
{
	i := pieces_find(sign);
	if(i >= 0)
		return (bracketpieces[i][1], bracketpieces[i][2], bracketpieces[i][3], bracketpieces[i][4]);
	return (nil, nil, nil, nil);
}

def_piecesput(sign, top, mid, bot, cen: string)
{
	i := pieces_find(sign);
	if(i < 0 && (i = pieces_find("")) < 0)
		return;
	bracketpieces[i][0] = sign;
	bracketpieces[i][1] = top;
	bracketpieces[i][2] = mid;
	bracketpieces[i][3] = bot;
	bracketpieces[i][4] = cen;
}

sizes_find(sign: string): int
{
	for(i := 0; i < len bracketsizes; i++)
		if(bracketsizes[i][0] == sign)
			return i;
	return -1;
}

# a bracket's sizes, nil after the last
def_sizes(sign: string): array of string
{
	sizes := array[NSIZES] of string;
	idx := sizes_find(sign);
	sizes[0] = sign;
	for(i := 1; idx >= 0 && i < NSIZES; i++)
		sizes[i - 1] = bracketsizes[idx][i];
	return sizes;
}

def_sizesput(sign: string, sizes: array of string)
{
	idx := sizes_find(sign);
	if(idx < 0 && (idx = sizes_find("")) < 0)
		return;
	bracketsizes[idx][0] = sign;
	for(i := 1; i < NSIZES; i++)
		bracketsizes[idx][i] = sizes[i - 1];
}

# TeX's parameters, in hundredths of an em
e_axisheight := 23;
e_minimumsize := 5;
e_overhang := 7;
e_nulldelim := 12;
e_scriptspace := 12;
e_thinspace := 17;
e_mediumspace := 22;
e_thickspace := 28;
e_num1 := 70;
e_num2 := 40;
e_denom1 := 70;
e_denom2 := 36;
e_sup1 := 42;
e_sup2 := 37;
e_sup3 := 28;
e_sub1 := 20;
e_sub2 := 23;
e_supdrop := 38;
e_subdrop := 5;
e_xheight := 45;
e_rulethickness := 4;
e_bigopspacing1 := 11;
e_bigopspacing2 := 17;
e_bigopspacing3 := 20;
e_bigopspacing4 := 60;
e_bigopspacing5 := 10;
e_columnsep := 100;
e_baselinesep := 140;
e_bodyheight := 70;
e_bodydepth := 25;
e_textlimits := 0;	# limits as scripts in text, as TeX sets them (not Neateqn's)

S_S1(): int	{ return e_thinspace; }
S_S2(): int	{ return e_mediumspace; }
S_S3(): int	{ return e_thickspace; }

def_set(name: string, val: int)
{
	case name {
	"axis_height" =>	e_axisheight = val;
	"minimum_size" =>	e_minimumsize = val;
	"over_hang" =>	e_overhang = val;
	"null_delimiter_space" =>	e_nulldelim = val;
	"script_space" =>	e_scriptspace = val;
	"thin_space" =>	e_thinspace = val;
	"medium_space" =>	e_mediumspace = val;
	"thick_space" =>	e_thickspace = val;
	"num1" =>	e_num1 = val;
	"num2" =>	e_num2 = val;
	"denom1" =>	e_denom1 = val;
	"denom2" =>	e_denom2 = val;
	"sup1" =>	e_sup1 = val;
	"sup2" =>	e_sup2 = val;
	"sup3" =>	e_sup3 = val;
	"sub1" =>	e_sub1 = val;
	"sub2" =>	e_sub2 = val;
	"sup_drop" =>	e_supdrop = val;
	"sub_drop" =>	e_subdrop = val;
	"x_height" =>	e_xheight = val;
	"default_rule_thickness" =>	e_rulethickness = val;
	"big_op_spacing1" =>	e_bigopspacing1 = val;
	"big_op_spacing2" =>	e_bigopspacing2 = val;
	"big_op_spacing3" =>	e_bigopspacing3 = val;
	"big_op_spacing4" =>	e_bigopspacing4 = val;
	"big_op_spacing5" =>	e_bigopspacing5 = val;
	"column_sep" =>	e_columnsep = val;
	"baseline_sep" =>	e_baselinesep = val;
	"body_height" =>	e_bodyheight = val;
	"body_depth" =>	e_bodydepth = val;
	"text_limits" =>	e_textlimits = val;
	}
}

# superscripts' style
ts_sup(style: int): int
{
	sz := min(2, TS_SZ(style) + 1);
	return TS_MK(sz, TS_0(style));
}

# subscripts'
ts_sub(style: int): int
{
	sz := min(2, TS_SZ(style) + 1);
	return TS_MK(sz, 1);
}

# numerators'
ts_num(style: int): int
{
	if(TS_DX(style)){
		if(TS_0(style))
			return TS_T0;
		return TS_T;
	}
	sz := min(2, TS_SZ(style) + 1);
	return TS_MK(sz, TS_0(style));
}

# denominators'
ts_denom(style: int): int
{
	if(TS_DX(style))
		return TS_T0;
	sz := min(2, TS_SZ(style) + 1);
	return TS_MK(sz, 1);
}

# the cost of breaking a line after an atom
brcost_type := array[32] of {* => 0};
brcost_cost := array[32] of {* => 0};
brcost_n := 0;

def_brcost(typ: int): int
{
	for(i := 0; i < brcost_n; i++)
		if(brcost_type[i] == typ && brcost_cost[i] > 0)
			return brcost_cost[i];
	return 100000;
}

def_brcostput(typ, cost: int)
{
	if(typ == 0)
		brcost_n = 0;
	i: int;
	for(i = 0; i < brcost_n; i++)
		if(brcost_type[i] == typ)
			break;
	more := 0;
	if(i >= brcost_n)
		more = 1;
	if(typ <= 0 || i + more >= len brcost_type)
		return;
	brcost_type[i] = typ;
	brcost_cost[i] = cost;
	if(i >= brcost_n)
		brcost_n = i + 1;
}

# the characters that chop equations
chopped := "^~\"\t";

def_chopped(c: int): int
{
	return strchr("\n {}", c) || strchr(chopped, c);
}

def_choppedset(c: string)
{
	chopped = c;
}
