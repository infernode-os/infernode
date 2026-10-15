implement Tr2pdf;

#
# tr2pdf - troff's output as PDF
#
# A translation of Ali Gholami Rudi's Neatpost (its PDF backend) into
# Limbo. With -c it writes what Neatpost writes, byte for byte; else it
# also compresses its streams, embeds an OpenType font with CFF outlines
# as OpenType (FontFile3), describes each font from its tables, maps its
# glyphs to their characters (ToUnicode), so that a reader can search
# and copy the text, takes the page size from x X papersize, and embeds
# each OpenType (CFF) font subset to the glyphs used (-W: whole).
#
# Copyright (C) 2013-2025 Ali Gholami Rudi <ali at rudi dot ir>
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

include "filter.m";
	deflate: Filter;

Tr2pdf: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

include "font.b";
include "pdf.b";
include "pdfext.b";
include "cffsub.b";

TROFFFDIR: con "/lib/troff";

bin: ref Iobuf;		# troff's output
compat := 0;		# as Neatpost

ps_title: string;		# the document's title
ps_pagewidth := 2159;		# page width, in tenths of a millimetre
ps_pageheight := 2794;
ps_linewidth := 40;		# drawing line thickness in thousandths of an em
o_pages := 0;			# pages written

# bookmarks
mark_desc: array of string;
mark_page: array of int;
mark_offset: array of int;
mark_level: array of int;
mark_n := 0;

# named destinations
name_desc: array of string;
name_page: array of int;
name_offset: array of int;
name_n := 0;

postdir := TROFFFDIR;		# the device directory
postdev := "utf";		# and the device

usage := "usage: tr2pdf [options] [file] >output\n" +
	"options:\n" +
	"  -F dir  \tset font directory (" + TROFFFDIR + ")\n" +
	"  -p size \tset paper size (letter); e.g., a4, 2100x2970\n" +
	"  -t title\tspecify document title\n" +
	"  -w lwid \tdrawing line thickness in thousandths of an em (40)\n" +
	"  -l      \tlandscape mode\n" +
	"  -n      \talways draw glyphs by name (ps glyphshow)\n" +
	"  -d x=v  \tset device-specific variables\n" +
	"  -W      \tembed fonts whole, not subset to the glyphs used\n" +
	"  -c      \twrite what Neatpost writes\n";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "tr2pdf: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:load";
	}
	landscape := 0;
	if(args != nil)
		args = tl args;
	for(; args != nil && len hd args > 1 && (hd args)[0] == '-'; args = tl args){
		a := hd args;
		v: string;
		case a[1] {
		'F' or 'p' or 'w' or 't' or 'd' =>
			if(len a > 2)
				v = a[2:];
			else if(tl args != nil){
				args = tl args;
				v = hd args;
			}
		}
		case a[1] {
		'F' =>
			postdir = v;
		'p' =>
			setpagesize(v);
		'w' =>
			ps_linewidth = atoi(v);
		'n' =>
			;
		't' =>
			ps_title = v;
		'l' =>
			landscape = 1;
		'd' =>
			cmdset(v);
		'c' =>
			compat = 1;
		'W' =>
			wholefonts = 1;
		* =>
			sys->fprint(sys->fildes(2), "%s", usage);
			raise "fail:usage";
		}
	}
	if(args != nil){
		bin = bufio->open(hd args, Bufio->OREAD);
		if(bin == nil){
			sys->fprint(sys->fildes(2), "tr2pdf: cannot open %s: %r\n", hd args);
			raise "fail:open";
		}
	}else
		bin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	bout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	if(!compat){
		deflate = load Filter Filter->DEFLATEPATH;
		if(deflate == nil){
			sys->fprint(sys->fildes(2), "tr2pdf: cannot load %s: %r\n", Filter->DEFLATEPATH);
			raise "fail:load";
		}
		deflate->init();
	}
	if(landscape){
		t := ps_pagewidth;
		ps_pagewidth = ps_pageheight;
		ps_pageheight = t;
	}
	{
		post();
		doctrailer(o_pages);
	} exception e {
	"fail:*" =>
		bout.flush();
		raise e;
	"*" =>
		# where Neatpost would crash: said, and failed
		bout.flush();
		sys->fprint(sys->fildes(2), "tr2pdf: %s\n", e);
		raise "fail:" + e;
	}
	bout.flush();
}

next(): int
{
	return bin.getb();
}

back(c: int)
{
	if(c >= 0)
		bin.ungetb();
}

utf8len(c: int): int
{
	if(~c & 16rc0)		# ASCII or invalid
		return c > 0;
	if(~c & 16r20)
		return 2;
	if(~c & 16r10)
		return 3;
	if(~c & 16r08)
		return 4;
	return 1;
}

# the next UTF-8 character, as troff wrote it
nextutf8(): string
{
	c := next();
	if(c < 0)
		return "";
	l := utf8len(c);
	if(l < 1)	# a NUL
		l = 1;
	b := array[l] of byte;
	b[0] = byte c;
	for(i := 1; i < l; i++)
		b[i] = byte next();
	return string b;
}

nextskip()
{
	c: int;
	do
		c = next();
	while(isspace(c));
	back(c);
}

nextnum(): int
{
	n := 0;
	neg := 0;
	nextskip();
	for(;;){
		c := next();
		if(!n && (c == '-' || c == '+')){
			neg = c == '-';
			continue;
		}
		if(!isdigit(c))
			back(c);
		if(c < 0 || !isdigit(c))
			break;
		n = n * 10 + c - '0';
	}
	if(neg)
		return -n;
	return n;
}

readnum(): (int, int)
{
	c: int;
	do
		c = next();
	while(c == ' ');
	back(c);
	if(c == '-' || c == '+' || (c >= '0' && c <= '9'))
		return (0, nextnum());
	return (1, 0);
}

iseol(): int
{
	c: int;
	do
		c = next();
	while(c == ' ');
	back(c);
	return c == '\n';
}

nexteol()
{
	c: int;
	do
		c = next();
	while(c >= 0 && c != '\n');
}

# the bytes of the next word
nextword(): string
{
	nextskip();
	b := array[64] of byte;
	n := 0;
	c := next();
	while(c >= 0 && !isspace(c)){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		b[n++] = byte c;
		c = next();
	}
	back(c);
	return string b[0:n];
}

# the rest of the line
readln(): string
{
	b := array[128] of byte;
	n := 0;
	c := next();
	while(c > 0 && c != '\n'){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		b[n++] = byte c;
		c = next();
	}
	if(c == '\n')
		back(c);
	return string b[0:n];
}

postline()
{
	for(;;){
		(e, h) := readnum();
		if(e)
			break;
		v: int;
		(e, v) = readnum();
		if(e)
			break;
		drawl(h, v);
	}
}

postarc()
{
	(e1, h1) := readnum();
	if(e1)
		return;
	(e2, v1) := readnum();
	if(e2)
		return;
	(e3, h2) := readnum();
	if(e3)
		return;
	(e4, v2) := readnum();
	if(e4)
		return;
	drawa(h1, v1, h2, v2);
}

postspline()
{
	h1 := nextnum();
	v1 := nextnum();
	if(iseol()){
		drawl(h1, v1);
		return;
	}
	for(;;){
		(e, h2) := readnum();
		if(e)
			break;
		v2: int;
		(e, v2) = readnum();
		if(e)
			break;
		draws(h1, v1, h2, v2);
		h1 = h2;
		v1 = v2;
	}
	draws(h1, v1, 0, 0);
}

postpoly()
{
	l := 'l';
	while(!iseol() && (l == 'l' || l == '~' || l == 'a')){
		c: int;
		do
			c = next();
		while(c == ' ');
		back(c);
		if(c != '-' && c != '+' && (c < '0' || c > '9')){
			l = c;
			while(c >= 0 && !isspace(c))
				c = next();
			continue;
		}
		if(l == 'l')
			postline();
		if(l == '~')
			postspline();
		if(l == 'a')
			postarc();
	}
}

postdraw()
{
	c := next();
	drawbeg();
	case tolower(c) {
	'l' =>
		h1 := nextnum();
		v1 := nextnum();
		drawl(h1, v1);
	'c' =>
		drawc(nextnum());
	'e' =>
		h1 := nextnum();
		v1 := nextnum();
		drawe(h1, v1);
	'a' =>
		postarc();
	'~' =>
		postspline();
	'p' =>
		postpoly();
	}
	drawend(c == 'p' || c == 'P', c == 'E' || c == 'C' || c == 'P');
	nexteol();
}

# the first word of src, quoted as troff quotes; and what follows
strcut(src: string): (string, string)
{
	i := 0;
	while(i < len src && (src[i] == ' ' || src[i] == '\n'))
		i++;
	d := "";
	if(i < len src && src[i] == '"'){
		i++;
		while(i < len src && (src[i] != '"' || (i + 1 < len src && src[i + 1] == '"'))){
			if(src[i] == '"')
				i++;
			d[len d] = src[i++];
		}
		if(i < len src && src[i] == '"')
			i++;
	}else{
		b := i;
		while(i < len src && src[i] != ' ' && src[i] != '\n')
			i++;
		d = src[b:i];
	}
	return (d, src[i:]);
}

# sscanf(s, "%d %d ..."): the numbers read
scanints(s: string, n: int): array of int
{
	r := array[n] of int;
	i := 0;
	for(k := 0; k < n; k++){
		while(i < len s && isspace(s[i]))
			i++;
		b := i;
		if(i < len s && (s[i] == '-' || s[i] == '+'))
			i++;
		if(i >= len s || !isdigit(s[i]))
			return r[0:k];
		while(i < len s && isdigit(s[i]))
			i++;
		r[k] = atoi(s[b:i]);
	}
	return r;
}

postps()
{
	cmd := nextword();
	arg := readln();
	case cmd {
	"rotate" =>
		;
	"eps" or "pdf" =>
		(path, spec) := strcut(arg);
		v := scanints(spec, 2);
		hwid := 0;
		vwid := 0;
		if(len v > 0)
			hwid = v[0];
		if(len v > 1)
			vwid = v[1];
		if(path != "" && cmd == "pdf")
			outpdf(path, hwid, vwid);
	"name" =>
		(desc, spec) := strcut(arg);
		v := scanints(spec, 2);
		if(desc != "" && len v > 0){
			if(name_n == len name_desc){
				sz := 2 * name_n + 128;
				name_desc = growstr(name_desc, sz);
				name_page = growint(name_page, sz);
				name_offset = growint(name_offset, sz);
			}
			name_desc[name_n] = desc;
			name_page[name_n] = v[0];
			if(len v > 1)
				name_offset[name_n] = v[1];
			name_n++;
		}
	"mark" =>
		(desc, spec) := strcut(arg);
		v := scanints(spec, 3);
		if(desc != "" && len v > 0){
			if(mark_n == len mark_desc){
				sz := 2 * mark_n + 128;
				mark_desc = growstr(mark_desc, sz);
				mark_page = growint(mark_page, sz);
				mark_offset = growint(mark_offset, sz);
				mark_level = growint(mark_level, sz);
			}
			mark_desc[mark_n] = desc;
			mark_page[mark_n] = v[0];
			if(len v > 1)
				mark_offset[mark_n] = v[1];
			if(len v > 2)
				mark_level[mark_n] = v[2];
			mark_n++;
		}
	"dest" =>
		# a named destination here (not Neatpost's: name gives the page)
		# (dest NAME page: the page's top)
		(d, rest) := word(arg);
		(w, nil) := word(rest);
		off := here();
		if(w == "page")
			off = 0;
		if(d != nil && o_pages > 0)
			addname(d, o_pages, off);
	"outline" =>
		# a bookmark here, its level and title (not Neatpost's: mark
		# gives the page)
		(lv, t) := word(arg);
		t = titletext(t);
		if(lv != nil && t != "" && o_pages > 0)
			addmark(t, o_pages, here(), int lv);
	"folio" =>
		# the page's number as printed: its label
		(f, nil) := word(arg);
		if(f != nil && o_pages > 0){
			if(o_pages > len pg_label)
				pg_label = growstr(pg_label, 2 * o_pages + 128);
			if(pg_label[o_pages - 1] == nil)
				pg_label[o_pages - 1] = f;
		}
	"link" =>
		(lnk, spec) := strcut(arg);
		v := scanints(spec, 2);
		if(lnk != "" && lnk != "#" && len v == 2)
			outlink(lnk, v[0], v[1]);
	"info" =>
		i := 0;
		while(i < len arg && arg[i] == ' ')
			i++;
		b := i;
		while(i < len arg && arg[i] != ' ')
			i++;
		kwd := arg[b:i];
		if(len kwd > 127)
			kwd = kwd[0:127];
		while(i < len arg && arg[i] == ' ')
			i++;
		if(compat)
			outinfo(kwd, arg[i:]);
		else
			outinfo(kwd, titletext(arg[i:]));
	"set" =>
		(var, rest) := word(arg);
		(val, nil) := word(rest);
		if(var != nil && val != nil)
			outset(var, val);
	"mtx" =>
		(v, nil) := word(arg);
		if(v != nil)
			outmtx(int v);
	"papersize" =>
		if(!compat){
			v := scanints(arg, 1);
			x := strchr(arg, 'x');
			if(len v == 1 && x >= 0 && len (h := scanints(arg[x + 1:], 1)) == 1)
				outpapersize(v[0], h[0]);
		}
	}
}

# where a destination here shows the page from: a line above
here(): int
{
	v := o_v - o_s * devres() / 72;
	if(v < 0)
		v = 0;
	return v;
}

addname(desc: string, page, off: int)
{
	if(name_n == len name_desc){
		sz := 2 * name_n + 128;
		name_desc = growstr(name_desc, sz);
		name_page = growint(name_page, sz);
		name_offset = growint(name_offset, sz);
	}
	name_desc[name_n] = desc;
	name_page[name_n] = page;
	name_offset[name_n] = off;
	name_n++;
}

addmark(desc: string, page, off, level: int)
{
	if(mark_n == len mark_desc){
		sz := 2 * mark_n + 128;
		mark_desc = growstr(mark_desc, sz);
		mark_page = growint(mark_page, sz);
		mark_offset = growint(mark_offset, sz);
		mark_level = growint(mark_level, sz);
	}
	mark_desc[mark_n] = desc;
	mark_page[mark_n] = page;
	mark_offset[mark_n] = off;
	mark_level[mark_n] = level;
	mark_n++;
}

# a title as text: troff's escapes of fonts and sizes left out, its
# characters by name the characters the fonts say they are
titletext(s: string): string
{
	r := "";
	i := 0;
	while(i < len s && s[i] == ' ')
		i++;
	while(i < len s){
		c := s[i++];
		if(c != '\\' || i >= len s){
			r[len r] = c;
			continue;
		}
		c = s[i++];
		case c {
		'f' or 's' or '*' or 'n' or 'F' or 'm' or 'M' or 'k' =>
			if(c == 's' && i < len s && (s[i] == '+' || s[i] == '-'))
				i++;
			if(i < len s && s[i] == '(')
				i += 3;
			else if(i < len s && s[i] == '['){
				while(i < len s && s[i] != ']')
					i++;
				i++;
			}else if(c == 's')
				while(i < len s && s[i] >= '0' && s[i] <= '9')
					i++;
			else
				i++;
		'(' or '[' =>
			n := "";
			if(c == '('){
				if(i + 2 <= len s)
					n = s[i:i + 2];
				i += 2;
			}else{
				while(i < len s && s[i] != ']')
					n[len n] = s[i++];
				i++;
			}
			r += charnamed(n);
		'e' or '\\' =>
			r += "\\";
		' ' or '~' or '0' =>
			r += " ";
		'-' =>
			r += "−";
		'h' or 'v' or 'w' or 'X' or 'o' or 'D' or 'l' or 'L' or 'Z' or 'b' or 'x' or 'R' =>
			if(i < len s){
				d := s[i++];
				while(i < len s && s[i] != d)
					i++;
				i++;
			}
		'&' or '|' or '^' or '%' or 'c' or 'u' or 'd' or 'a' or 'z' or ':' =>
			;
		* =>
			r[len r] = c;
		}
	}
	return r;
}

# the character a name is, in the first font mounted that has it
charnamed(n: string): string
{
	for(f := 0; f < NFONTS; f++){
		g := dev_glyph(n, f);
		if(g != nil && g.name != nil && g.name != n)
			return g.name;
	}
	return "";
}

# a blank-separated word of s; and what follows
word(s: string): (string, string)
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	b := i;
	while(i < len s && !isspace(s[i]))
		i++;
	if(i == b)
		return (nil, s[i:]);
	return (s[b:i], s[i:]);
}

growstr(a: array of string, n: int): array of string
{
	r := array[n] of string;
	r[0:] = a;
	return r;
}

growint(a: array of int, n: int): array of int
{
	r := array[n] of {* => 0};
	r[0:] = a;
	return r;
}

postx()
{
	cmd := nextword();
	c := 0;
	if(cmd != nil)
		c = cmd[0];
	case c {
	'f' =>
		pos := nextnum();
		font := nextword();
		dev_mnt(pos, font, font);
		outmnt(pos);
	'i' =>
		if(dev_open(postdir, postdev)){
			sys->fprint(sys->fildes(2), "tr2pdf: cannot open device %s\n", postdev);
			raise "fail:device";
		}
		docheader(ps_title, ps_pagewidth, ps_pageheight, ps_linewidth);
	'T' =>
		postdev = nextword();
	's' =>
		;
	'X' =>
		postps();
	}
	nexteol();
}

postcmd(c: int)
{
	if(isdigit(c)){
		outrel((c - '0') * 10 + next() - '0', 0);
		outc(nextutf8());
		return;
	}
	case c {
	's' =>
		outsize(nextnum());
	'f' =>
		outfont(nextnum());
	'H' =>
		outh(nextnum());
	'V' =>
		outv(nextnum());
	'h' =>
		outrel(nextnum(), 0);
	'v' =>
		outrel(0, nextnum());
	'c' =>
		outc(nextutf8());
	'm' =>
		outcolor(clr_get(nextword()));
	'N' =>
		nextnum();
	'C' =>
		outc(nextword());
	'p' =>
		if(o_pages)
			docpageend(o_pages);
		o_pages = nextnum();
		docpagebeg(o_pages);
		outpage();
	'w' =>
		;
	'n' =>
		nextnum();
		nextnum();
	'D' =>
		postdraw();
	'x' =>
		postx();
	'#' =>
		nexteol();
	* =>
		sys->fprint(sys->fildes(2), "tr2pdf: unknown command %c\n", c);
		nexteol();
	}
}

post()
{
	while((c := next()) >= 0)
		if(!isspace(c))
			postcmd(c);
	if(o_pages)
		docpageend(o_pages);
	if(name_n)
		outname(name_n, name_desc, name_page, name_offset);
	if(mark_n)
		outmark(mark_n, mark_desc, mark_page, mark_offset, mark_level);
}

setpagesize(s: string)
{
	case s {
	"letter" =>
		(ps_pagewidth, ps_pageheight) = (2159, 2794);
		return;
	"legal" =>
		(ps_pagewidth, ps_pageheight) = (2159, 3556);
		return;
	"ledger" =>
		(ps_pagewidth, ps_pageheight) = (4318, 2794);
		return;
	"tabloid" =>
		(ps_pagewidth, ps_pageheight) = (2794, 4318);
		return;
	}
	# a size in tenths of a millimetre, as 2100x2970 for A4
	if(len s > 0 && isdigit(s[0]) && (x := strchr(s, 'x')) >= 0){
		ps_pagewidth = atoi(s);
		ps_pageheight = atoi(s[x + 1:]);
		return;
	}
	# ISO sizes
	if(len s < 2 || strchr("abcABC", s[0]) < 0 || !isdigit(s[1]))
		return;
	d1, d2: int;
	case tolower(s[0]) {
	'a' =>
		(d1, d2) = (8410, 11890);
	'b' =>
		(d1, d2) = (10000, 14140);
	* =>
		(d1, d2) = (9170, 12970);
	}
	n := s[1] - '0';
	if(n & 1)
		ps_pagewidth = d2 >> ((n + 1) >> 1);
	else
		ps_pagewidth = d1 >> ((n + 1) >> 1);
	if(n & 1)
		ps_pageheight = d1 >> (n >> 1);
	else
		ps_pageheight = d2 >> (n >> 1);
	ps_pagewidth -= ps_pagewidth % 10;
	ps_pageheight -= ps_pageheight % 10;
}

# the code point of the UTF-8 character at s[i:]
utf8code(s: array of byte, i: int): int
{
	c := int s[i];
	if(~c & 16rc0)
		return c;
	if(~c & 16r20)
		return ((c & 16r1f) << 6) | (int s[i + 1] & 16r3f);
	if(~c & 16r10)
		return ((c & 16r0f) << 12) | ((int s[i + 1] & 16r3f) << 6) | (int s[i + 2] & 16r3f);
	if(~c & 16r08)
		return ((c & 16r07) << 18) | ((int s[i + 1] & 16r3f) << 12) | ((int s[i + 2] & 16r3f) << 6) | (int s[i + 3] & 16r3f);
	return c;
}

pdftext_ascii(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 16r80 || s[i] == '(' || s[i] == ')')
			return 0;
	return 1;
}

# s as a PDF text string
pdftext(s: string): string
{
	if(pdftext_ascii(s))
		return "(" + s + ")";
	b := array of byte s;
	r := "<FEFF";
	for(i := 0; i < len b; ){
		c := utf8code(b, i);
		if((c >= 0 && c <= 16rd7ff) || (c >= 16re000 && c <= 16rffff))
			r += sys->sprint("%02X%02X", c >> 8, c & 16rff);
		if(c >= 16r10000 && c <= 16r10ffff){
			c1 := 16rd800 + ((c - 16r10000) >> 10);
			c2 := 16rdc00 + ((c - 16r10000) & 16r3ff);
			r += sys->sprint("%02X%02X%02X%02X", c1 >> 8, c1 & 16rff, c2 >> 8, c2 & 16rff);
		}
		l := utf8len(int b[i]);
		if(l == 0)
			l = 1;
		i += l;
	}
	return r + ">";
}

# pdftext, cut as Neatpost's static buffer cuts it
pdftext_static(s: string): string
{
	r := pdftext(s);
	if(len r > 1023)
		r = r[0:1023];
	return r;
}

cmdset(arg: string)
{
	if((eq := strchr(arg, '=')) >= 0)
		outset(arg[0:eq], arg[eq + 1:]);
}

#
# colours
#

clr_get(s: string): int
{
	if(len s == 7 && s[0] == '#')
		return (clrcomp(s[1:3]) << 16) | (clrcomp(s[3:5]) << 8) | clrcomp(s[5:7]);
	if(len s == 4 && s[0] == '#')
		return (clrcomp(s[1:2]) << 16) | (clrcomp(s[2:3]) << 8) | clrcomp(s[3:4]);
	colors := array[] of {
		("black", 16r000000), ("red", 16rff0000), ("green", 16r00ff00), ("yellow", 16rffff00),
		("blue", 16r0000ff), ("magenta", 16rff00ff), ("cyan", 16r00ffff), ("white", 16rffffff),
	};
	if(len s > 0 && isdigit(s[0]) && atoi(s) >= 0 && atoi(s) < len colors)
		return colors[atoi(s)].t1;
	for(i := 0; i < len colors; i++)
		if(colors[i].t0 == s)
			return colors[i].t1;
	return 0;
}

clrcomp(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++){
		c := tolower(s[i]);
		if(c >= '0' && c <= '9')
			n = n * 16 + c - '0';
		else if(c >= 'a' && c <= 'f')
			n = n * 16 + c - 'a' + 10;
	}
	if(len s == 1)
		return n * 255 / 15;
	return n;
}

#
# helpers
#

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

tolower(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c + 'a' - 'A';
	return c;
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
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
	for(; i < len s && isdigit(s[i]); i++)
		n = n * 10 + s[i] - '0';
	if(neg)
		return -n;
	return n;
}
