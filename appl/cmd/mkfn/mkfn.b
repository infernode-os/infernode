implement Mkfn;

#
# mkfn - make troff(1) font descriptions from OpenType, TrueType and
# AFM fonts
#
# A translation of Ali Gholami Rudi's Neatmkfn into Limbo; for the same
# font and options it writes the same description, byte for byte.
#
# Copyright (C) 2012-2026 Ali Gholami Rudi <ali at rudi dot ir>
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

include "math.m";
	math: Math;

Mkfn: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

include "tables.b";
include "otf.b";
include "afm.b";

stdout: ref Iobuf;

scripts: string;	# the scripts to include
langs: string;		# the languages to include
subfont: string;	# the font to take from a collection
trname: string;		# the font's troff name
psname: string;		# and PostScript name
fpath: string;		# its path
res := 720;		# device resolution
warn := 0;		# warn about unsupported features
kmin := 0;		# minimum kerning value
swid := 0;		# space width
special := 0;		# special font
bbox := 0;		# include bounding boxes
noligs := 0;		# suppress the ligatures line
pos := 1;		# include glyph positions
byname := 0;		# always reference glyphs by name
dry := 0;		# write nothing
compat := 0;		# aliases as Neatmkfn gives them

# OpenType's order of features, for scripts that have one
scriptorder := array[] of {
	"latn", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"cyrl", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"grek", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"armn", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"geor", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"runr", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"ogam", "ccmp,liga,clig,dist,kern,mark,mkmk",
	"arab", "ccmp,isol,fina,medi,init,rlig,calt,liga,dlig,cswh,mset,curs,kern,mark,mkmk",
	"bugi", "locl,ccmp,rlig,liga,clig,calt,kern,dist,mark,mkmk",
	"hang", "ccmp,ljmo,vjmo,tjmo",
	"hebr", "ccmp,dlig,kern,mark",
	"bng2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"dev2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"gjr2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"gur2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"knd2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"mlym", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"ory2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"tml2", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"telu", "locl,nukt,akhn,rphf,blwf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,calt,kern,dist,abvm,blwm",
	"java", "locl,pref,abvf,blwf,pstf,pres,abvs,blws,psts,ccmp,rlig,liga,clig,calt,kern,dist,mark,mkmk",
	"khmr", "pref,blwf,abvf,pstf,pres,blws,abvs,psts,clig,dist,blwm,abvm,mkmk",
	"lao ", "ccmp,kern,mark,mkmk",
	"mym2", "locl,rphf,pref,blwf,pstf,pres,abvs,blws,psts,kern,dist,mark,mkmk",
	"sinh", "locl,ccmp,akhn,rphf,vatu,pstf,pres,abvs,blws,psts,kern,dist,abvm,blwm",
	"syrc", "stch,ccmp,isol,fina,fin2,fin3,medi,med2,init,rlig,calt,liga,dlig,kern,mark,mkmk",
	"thaa", "kern,mark",
	"thai", "ccmp,kern,mark,mkmk",
	"tibt", "ccmp,abvs,blws,calt,liga,kern,abvm,blwm,mkmk",
};

usage := "usage: mkfn [options] [font] >output\n" +
	"options:\n" +
	"  -a      \tread an AFM file (default)\n" +
	"  -o      \tread a TTF or an OTF file\n" +
	"  -s      \tspecial font\n" +
	"  -p name \toverride font postscript name\n" +
	"  -t name \tset font troff name\n" +
	"  -f path \tset font path\n" +
	"  -r res  \tset device resolution (720)\n" +
	"  -k kmin \tspecify the minimum amount of kerning (0)\n" +
	"  -b      \tinclude glyph bounding boxes\n" +
	"  -l      \tsuppress the ligatures line\n" +
	"  -n      \tsuppress glyph positions\n" +
	"  -g      \talways reference glyphs by name in OTF rules\n" +
	"  -S scrs \tcomma-separated list of scripts to include (list to list)\n" +
	"  -L langs\tcomma-separated list of languages to include (list to list)\n" +
	"  -F font \tfont name or index in a font collection (list to list)\n" +
	"  -w      \twarn about unsupported font features\n" +
	"  -c      \tgive aliases as Neatmkfn does, even names of the font's own characters\n";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "mkfn: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:load";
	}
	afm := 1;
	if(args != nil)
		args = tl args;
	for(; args != nil && len hd args > 0 && (hd args)[0] == '-'; args = tl args){
		a := hd args;
		o := 0;
		if(len a > 1)
			o = a[1];
		v: string;
		case o {
		'f' or 'F' or 'k' or 'L' or 'p' or 'r' or 'S' or 't' =>
			if(len a > 2)
				v = a[2:];
			else if(tl args != nil){
				args = tl args;
				v = hd args;
			}
		}
		case o {
		'a' =>
			afm = 1;
		'b' =>
			bbox = 1;
		'c' =>
			compat = 1;
		'f' =>
			fpath = v;
		'F' =>
			subfont = v;
			dry = subfont == "list";
		'g' =>
			byname = 1;
		'k' =>
			kmin = atoi(v);
		'l' =>
			noligs = 1;
		'L' =>
			langs = v;
			dry = langs == "list";
		'n' =>
			pos = 0;
		'o' =>
			afm = 0;
		'p' =>
			psname = v;
		'r' =>
			res = atoi(v);
		's' =>
			special = 1;
		'S' =>
			scripts = v;
			dry = scripts == "list";
		't' =>
			trname = v;
		'w' =>
			warn = 1;
		* =>
			sys->fprint(sys->fildes(2), "%s", usage);
			raise "fail:usage";
		}
	}
	inb: ref Iobuf;
	if(args != nil){
		inb = bufio->open(hd args, Bufio->OREAD);
		if(inb == nil){
			sys->fprint(sys->fildes(2), "mkfn: cannot open %s: %r\n", hd args);
			raise "fail:open";
		}
	}else
		inb = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	trfn_init();
	err: int;
	if(afm)
		err = afm_read(inb);
	else
		err = otf_read(inb);
	stdout.flush();
	if(err){
		sys->fprint(sys->fildes(2), "mkfn: cannot parse the font\n");
		raise "fail:font";
	}
}

out(s: string)
{
	stdout.puts(s);
}

# whether the given script is to be included; and the script, its tag cut at a blank
mkfn_script(script: string, nscripts: int): (int, string)
{
	if(scripts == nil){
		if(nscripts == 1 || script == nil)
			return (1, script);
		if(script == "DFLT")
			scripts = "DFLT";
		else
			scripts = "latn";
	}
	if(scripts == "list")
		out(script + "\n");
	script = cutblank(script);
	return (strstr(scripts, script) >= 0, script);
}

# whether the given language is to be included; and the language, as mkfn_script
mkfn_lang(lang: string, nil: int): (int, string)
{
	if(langs == nil)
		return (1, lang);
	if(langs == "list")
		out(lang + "\n");
	lang = cutblank(lang);
	return (strstr(langs, lang) >= 0, lang);
}

fontidx := 0;

# whether the given font is to be included
mkfn_font(font: string): int
{
	fontidx++;
	if(subfont == nil)
		return fontidx == 1;
	if(subfont == "list")
		out(font + "\n");
	if(subfont[0] >= '0' && subfont[0] <= '9')
		if(atoi(subfont) == fontidx)
			return 1;
	return subfont == font;
}

# the rank of the given feature, for the given script
mkfn_featrank(scrp, feat: string): int
{
	order: string;
	for(i := 0; i < len scriptorder; i += 2)
		if(scriptorder[i] == scrp)
			order = scriptorder[i + 1];
	if(order != nil && (k := strstr(order, feat)) >= 0)
		return k;
	return 1000;
}

mkfn_header(fontname: string)
{
	if(dry)
		return;
	if(trname != nil)
		out("name " + trname + "\n");
	if(psname != nil)
		out("fontname " + psname + "\n");
	if(psname == nil && fontname != nil)
		out("fontname " + fontname + "\n");
	if(fpath != nil)
		out("fontpath " + fpath + "\n");
	trfn_header();
	if(special)
		out("special\n");
	trfn_cdefs();
}

#
# trfn.c: the character set
#

# a character definition, and the aliases its character has
Cdef: adt {
	line:	string;
	name:	string;
	alts:	string;		# blank-separated, the more apt first
};

cdefs: array of ref Cdef;
ncdefs := 0;
ligs: string;			# the font's ligatures
ligs2: string;			# and those two bytes long
masc := 0;			# the least height of glyphs with an ascender
mdesc := 0;			# the least depth of glyphs with a descender
tab_agl: ref Tab;		# the Adobe glyph list
tab_alts: ref Tab;		# troff's aliases

# a dictionary; of the same keys, the last put is got
Tab: adt {
	b:	array of list of (string, string);

	put:	fn(t: self ref Tab, k, v: string);
	get:	fn(t: self ref Tab, k: string): string;
};

tab_alloc(n: int): ref Tab
{
	return ref Tab(array[n] of list of (string, string));
}

tab_hash(k: string, n: int): int
{
	h := 0;
	for(i := 0; i < len k; i++)
		h = (h * 31 + k[i]) & 16r7fffffff;
	return h % n;
}

Tab.put(t: self ref Tab, k, v: string)
{
	h := tab_hash(k, len t.b);
	t.b[h] = (k, v) :: t.b[h];
}

Tab.get(t: self ref Tab, k: string): string
{
	for(l := t.b[tab_hash(k, len t.b)]; l != nil; l = tl l){
		(key, v) := hd l;
		if(key == k)
			return v;
	}
	return nil;
}

# the value of len upper case hex digits at s[i:]; -1 if fewer than four
hexval(s: string, i: int, n: int): int
{
	v := 0;
	k: int;
	for(k = 0; k < n && i + k < len s; k++){
		c := s[i + k];
		if(c >= '0' && c <= '9')
			v = v * 16 + c - '0';
		else if(c >= 'A' && c <= 'F')
			v = v * 16 + c - 'A' + 10;
		else
			break;
	}
	if(k < 4)
		return -1;
	return v;
}

# a character beyond the 16 bits of a Limbo string's has been asked for
toowide := 0;

# a character, a blank for none
utf8put(c: int): string
{
	if(c > 16rFFFF)
		toowide = 1;
	if(c <= 0)
		return " ";
	s := "";
	s[0] = c;
	return s;
}

# the characters of an AGL glyph name
agl_map(name: string): (int, string)
{
	u := tab_agl.get(name);
	if(u == nil)
		return (1, nil);
	d := "";
	i := 0;
	while(i < len u){
		while(i < len u && u[i] == ' ')
			i++;
		d += utf8put(hexval(u, i, 6));
		while(i < len u && u[i] != ' ')
			i++;
		if(i >= len u)
			break;
	}
	return (0, d);
}

achar_map(name: string): int
{
	for(i := 0; i < len achar_name; i++){
		a := achar_name[i];
		if(len name >= len a && name[0:len a] == a){
			v := achar_val[5 * i:];
			case name[len a:] {
			"" =>
				return v[0];
			"isolated" =>
				return orelse(v[1], v[0]);
			"initial" =>
				return orelse(v[2], v[0]);
			"medial" =>
				return orelse(v[3], v[0]);
			"final" =>
				return orelse(v[4], v[0]);
			}
		}
	}
	return 0;
}

orelse(a, b: int): int
{
	if(a)
		return a;
	return b;
}

achar_shape(c, pjoin, njoin: int): int
{
	for(i := 0; i < len achar_name; i++){
		v := achar_val[5 * i:];
		if(v[0] == c){
			if(!pjoin && !njoin)
				return v[0];
			if(!pjoin && njoin)
				return orelse(v[2], v[0]);
			if(pjoin && njoin)
				return orelse(v[3], v[0]);
			return orelse(v[4], v[0]);
		}
	}
	return c;
}

NCHAR: con 8;	# characters to a glyph

# the arabic shapes of str's (at most NCHAR) characters, given ext
ashape(str: string, ext: string): string
{
	bjoin := ext == ".medi" || ext == ".fina";
	ejoin := ext == ".medi" || ext == ".init";
	l := len str;
	if(l > NCHAR)
		l = NCHAR;
	d := "";
	for(i := 0; i < l; i++)
		d[i] = achar_shape(str[i], i > 0 || bjoin, i < l - 1 || ejoin);
	return d;
}

# the characters glyph src (whose code point is codepoint) stands for; and whether it stands for none
trfn_name(src: string, codepoint: int): (int, string)
{
	toowide = 0;
	(e, d) := trfn_name0(src, codepoint);
	if(toowide)
		return (1, nil);	# no name, rather than another character's
	return (e, d);
}

trfn_name0(src: string, codepoint: int): (int, string)
{
	if(codepoint)
		return (0, utf8put(codepoint));
	if(src == nil || src[0] == '.')
		return (1, nil);
	d := "";
	i := 0;
	while(i < len src && src[i] != '.'){
		if(src[i] == '_')
			i++;
		b := i;
		while(i < len src && src[i] != '_' && src[i] != '.')
			i++;
		ch := src[b:i];
		(e, m) := agl_map(ch);
		if(!e)
			d += m;
		else if(len ch >= 3 && ch[0:3] == "uni" && hexval(ch, 3, 4) > 0){
			for(k := 0; len ch - (3 + 4 * k) >= 4; k++)
				d += utf8put(hexval(ch, 3 + 4 * k, 4));
		}else if(len ch > 0 && ch[0] == 'u' && hexval(ch, 1, 4) > 0)
			d += utf8put(hexval(ch, 1, 6));
		else if((c := achar_map(ch)) != 0)
			d += utf8put(c);
		else
			return (1, d);
	}
	ext := src[i:];
	d = ashape(d, ext);
	return (ext != "" && ext != ".medi" && ext != ".fina" && ext != ".init" && ext != ".isol", d);
}

trfn_aglexceptions(d: string): string
{
	for(i := 0; i < len agl_exceptions; i += 2)
		if(agl_exceptions[i] == d)
			d = agl_exceptions[i + 1];
	return d;
}

trfn_ligput(c: string)
{
	if(len array of byte c == 2)
		ligs2 += c + " ";
	else
		ligs += c + " ";
}

trfn_lig(c: string)
{
	for(i := 0; i < len agl_exceptions; i += 2)
		if(agl_exceptions[i + 1] == c)
			return;
	if(len c > 1)
		trfn_ligput(c);
	else{
		for(i = 0; i < len ligs_utf8; i += 2)
			if(ligs_utf8[i] == c)
				trfn_ligput(ligs_utf8[i + 1]);
	}
}

trfn_type(s: string, lly, ury: int): int
{
	typ := 0;
	c := 0;
	if(len s == 1 && s[0] < 128)
		c = s[0];
	if(c == 't' && !masc)
		masc = ury;
	if((c == 'g' || c == 'j' || c == 'p' || c == 'q' || c == 'y') && (!mdesc || mdesc < lly))
		mdesc = lly;
	if(!mdesc || !masc){
		if(c > 0 && c < 128)
			return ctype_ascii[c];
		return 3;
	}
	if(!mdesc || lly <= mdesc)
		typ |= 1;
	if(!masc || ury >= masc)
		typ |= 2;
	return typ;
}

# glyph psname, at position n, for code point u
mkfn_char(psname: string, n, u, wid, llx, lly, urx, ury: int)
{
	(e, uc) := trfn_name(psname, u);
	if(e)
		uc = "---";
	uc = trfn_aglexceptions(uc);
	p := "";
	if(pos && n >= 0 && n < 256)
		p = string n;
	if(pos && n < 0 && len uc == 1 && uc[0] >= 32 && uc[0] <= 125)
		if(strchr(psname, '.') < 0)
			p = string uc[0];
	ts := "";
	if(strchr(psname, '.') < 0)
		ts = uc;
	typ := trfn_type(ts, lly, ury);
	if(!swid && (uc == " " || uc == " "))
		swid = wid;
	if(uc != nil && isspace(uc[0]) || strchr(uc, ' ') >= 0)
		uc = "---";	# blanks are not allowed in names
	if(uc != "---")
		trfn_lig(uc);
	line := "char " + uc + "\t" + string wid;
	if(bbox && (llx || lly || urx || ury))
		line += sys->sprint(",%d,%d,%d,%d", llx, lly, urx, ury);
	line += "\t" + string typ + "\t" + psname + "\t" + p + "\n";
	if(ncdefs == len cdefs){
		nc := array[2 * len cdefs + 256] of ref Cdef;
		nc[0:] = cdefs[0:ncdefs];
		cdefs = nc;
	}
	cdefs[ncdefs++] = ref Cdef(line, uc, tab_alts.get(uc));
}

# the blank-separated words of s
fields(s: string): list of string
{
	r: list of string;
	for(i := len s; i > 0; ){
		e := i;
		while(i > 0 && s[i - 1] != ' ')
			i--;
		if(i < e)
			r = s[i:e] :: r;
		i--;
	}
	return r;
}

mkfn_kern(c1, c2: string, x: int)
{
	if(x && abs(x) >= kmin)
		if(!dry)
			out("kern " + c1 + "\t" + c2 + "\t" + string x + "\n");
}

trfn_header()
{
	out("spacewidth " + string swid + "\n");
	if(!noligs)
		out("ligatures " + ligs + ligs2 + "0\n");
}

#
# Unless compat, an alias is not given for a character the font has a
# glyph of its own for: troff looks for aliases first, and the micro
# sign's alias μ would hide the font's Greek mu.  An alias two glyphs
# have (*m: μ and µ) goes to one: troff's names for Greek letters (*m)
# to the Greek letter, others to the glyph whose aliases list it first,
# else to the first.  (A ligature's glyph, ct, does not keep the cent
# sign from its alias ct.)
#
trfn_cdefs()
{
	own, best: ref Tab;
	if(!compat){
		own = tab_alloc(2 * ncdefs + 1);
		for(i := 0; i < ncdefs; i++)
			if(len cdefs[i].name == 1)
				own.put(cdefs[i].name, "y");
		best = tab_alloc(2 * ncdefs + 1);
		for(i = ncdefs - 1; i >= 0; i--){
			c := cdefs[i].name;
			greek := len c == 1 && c[0] >= 16r370 && c[0] <= 16r3ff;
			k := 1;
			for(l := fields(cdefs[i].alts); l != nil; l = tl l){
				a := hd l;
				r := k++;
				if(greek && a[0] == '*')
					r = 0;
				b := best.get(a);
				if(own.get(a) == nil && (b == nil || int b[0:strchr(b, ' ')] >= r))
					best.put(a, string r + " " + string i);
			}
		}
	}
	for(i := 0; i < ncdefs; i++){
		c := cdefs[i];
		out(c.line);
		for(l := fields(c.alts); l != nil; l = tl l){
			a := hd l;
			if(!compat){
				b := best.get(a);
				if(b == nil || int b[strchr(b, ' ') + 1:] != i)
					continue;
			}
			out("char " + a + "\t\"\n");
		}
	}
}

trfn_init()
{
	tab_agl = tab_alloc(len agl);
	for(i := 0; i < len agl; i += 2)
		tab_agl.put(agl[i], agl[i + 1]);
	tab_alts = tab_alloc(len alts);
	for(i = 0; i < len alts; i++){
		r := alts[i];
		k := strchr(r, ' ');
		tab_alts.put(r[0:k], r[k + 1:]);
	}
}

#
# helpers
#

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

strstr(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i + len t] == t)
			return i;
	return -1;
}

cutblank(s: string): string
{
	if((i := strchr(s, ' ')) >= 0)
		return s[0:i];
	return s;
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

# C's atoi
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

# a signed number, as printf's %+d
sgn(n: int): string
{
	if(n < 0)
		return string n;
	return "+" + string n;
}
