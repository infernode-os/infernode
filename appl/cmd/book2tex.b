implement Book2tex;

#
# book2tex - a book written with troff's macros -mbook, as LaTeX
#
#	book2tex [-p works.bib] [-o book.tex] [book.ms]
#
# Each of -mbook's macros is one of LaTeX's (docs/TROFF.md has the
# table), and is written as that: chapters, sections, quotations,
# epigraphs, footnotes and endnotes, labels and references, the
# contents, citations (biblatex-chicago's \autocite, its notes style
# the Chicago Manual's, as refer's -S chicago), the bibliography and the
# index (makeindex's entries, as .index has them).  Troff's escapes
# become LaTeX's: fonts, characters by name, strings.  An equation
# (eqn's .EQ, or between the delimiters delim sets) is written as
# LaTeX's mathematics, a table (tbl's .TS) as a tabular.  A picture
# (pic's .PS) is drawn by pic, troff and tr2pdf as a PDF of its own,
# book-pic1.pdf and so on beside the output (-o), and included; written
# to standard output, it is left as a comment.
#
# The LaTeX is for LuaLaTeX: Libertinus, as troff sets the book, by
# fontspec and unicode-math; microtype; biblatex-chicago with biber,
# from the BibTeX database -p names (the book's stem.bib by default).
#	lualatex book; biber book; makeindex book; lualatex book; lualatex book
#
# A request or macro with no LaTeX of its own is written as a comment
# (% troff: ...), and said once on standard error.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "sh.m";

Book2tex: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;
ctxt: ref Draw->Context;

# fonts
R, I, B, BI, SC, TT: con iota;

# what is being written: the book, or a note's or epigraph's text
Out: adt {
	l:	list of string;	# its lines, the last first
	want:	int;	# the font the text is in
	prev:	int;	# the font before (\fP)
	open:	int;	# the font open in what is written
	cont:	int;	# the last line ended in \c: the next joins it
	intext:	int;	# text since the paragraph began
	noindent:	int;	# the next text continues a paragraph (after .sp)
	fnmarked:	int;	# \*[fnmark] placed the note's mark
	enmarked:	int;
	nf:	int;	# no filling (.nf): a line a line
	nfline:	int;	# the last line was one of .nf's text
};

cur: ref Out;

# the input: files, .so's on top
Inp: adt {
	f:	ref Iobuf;
	name:	string;
	line:	int;
};
inputs: list of ref Inp;
pushed: list of string;	# lines to be read again

# the book's settings, for the preamble
bib := "";
srcname := "";
outname := "";
papersize := array[2] of {"6in", "9in"};
margins := array[4] of {"0.75in", "0.875in", "0.875in", "0.75in"};
ptsize := "11pt";
title := "";
subtitle := "";
author := "";
date := "";
haveepigraph := 0;
haveendnotes := 0;
havecites := 0;
haveindex := 0;
havepics := 0;
havetables := 0;
numbered := 1;	# chapters numbered (\mainmatter's)
chapnum := 0;
enhead := "";	# the heading of the chapter's endnotes, until its first
npics := 0;

# strings (.ds), and the characters troff names
strs: list of (string, string);
chars: list of (string, string);
said: list of string;	# what has been said on standard error

# eqn's inline delimiters
dl1 := 0;
dl2 := 0;

init(c: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	stderr = sys->fildes(2);
	ctxt = c;
	args = tl args;
	while(args != nil && len hd args > 1 && (hd args)[0] == '-'){
		o := hd args;
		args = tl args;
		if(o == "-p" && args != nil){
			bib = hd args;
			args = tl args;
		}else if(o == "-o" && args != nil){
			outname = hd args;
			args = tl args;
		}else
			usage();
	}
	f: ref Iobuf;
	if(args == nil){
		f = bufio->fopen(sys->fildes(0), Bufio->OREAD);
		srcname = "book.ms";
	}else{
		if(tl args != nil)
			usage();
		srcname = hd args;
		f = bufio->open(srcname, Bufio->OREAD);
		if(f == nil){
			sys->fprint(stderr, "book2tex: %s: %r\n", srcname);
			raise "fail:open";
		}
	}
	inputs = ref Inp(f, srcname, 0) :: nil;
	loadchars();
	cur = newout();
	{
		book();
	}exception e{
	"fail:*" =>
		raise e;
	"*" =>
		sys->fprint(stderr, "book2tex: %s, %s line %d\n", e, inname(), inline());
		raise "fail:" + e;
	}
	closefont(cur);
	o: ref Iobuf;
	if(outname != nil){
		o = bufio->create(outname, Bufio->OWRITE, 8r666);
		if(o == nil){
			sys->fprint(stderr, "book2tex: %s: %r\n", outname);
			raise "fail:create";
		}
	}else
		o = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	o.puts(preamble());
	for(l := rev(cur.l); l != nil; l = tl l){
		o.puts(hd l);
		o.putc('\n');
	}
	o.puts("\\end{document}\n");
	o.close();
}

usage()
{
	sys->fprint(stderr, "usage: book2tex [-p works.bib] [-o book.tex] [book.ms]\n");
	raise "fail:usage";
}

warn(s: string)
{
	for(l := said; l != nil; l = tl l)
		if(hd l == s)
			return;
	said = s :: said;
	sys->fprint(stderr, "book2tex: %s (%s line %d)\n", s, inname(), inline());
}

inname(): string
{
	if(inputs == nil)
		return srcname;
	return (hd inputs).name;
}

inline(): int
{
	if(inputs == nil)
		return 0;
	return (hd inputs).line;
}

newout(): ref Out
{
	return ref Out(nil, R, R, R, 0, 0, 0, 0, 0, 0, 0);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

ch(c: int): string
{
	s := "x";
	s[0] = c;
	return s;
}

isalpha(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

suffix(p, s: string): int
{
	return len s >= len p && s[len s - len p:] == p;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j - 1] == ' ' || s[j - 1] == '\t'))
		j--;
	return s[i:j];
}

join(l: list of string, sep: string): string
{
	s := "";
	for(; l != nil; l = tl l){
		s += hd l;
		if(tl l != nil)
			s += sep;
	}
	return s;
}

# the input, a line at a time; a line ending in \ goes on on the next;
# a blank line is " "
readline(): string
{
	if(pushed != nil){
		s := hd pushed;
		pushed = tl pushed;
		return s;
	}
	s := "";
	for(;;){
		if(inputs == nil)
			return nil;
		in := hd inputs;
		t := in.f.gets('\n');
		if(t == nil){
			inputs = tl inputs;
			if(s != "")
				return s;
			continue;
		}
		in.line++;
		if(t[len t - 1] == '\n')
			t = t[0:len t - 1];
		n := 0;
		for(i := len t - 1; i >= 0 && t[i] == '\\'; i--)
			n++;
		if(n % 2){
			s += t[0:len t - 1];
			continue;
		}
		s += t;
		if(s == "")
			return " ";	# a blank line: "" is nil, the end
		return s;
	}
}

unread(s: string)
{
	pushed = s :: pushed;
}

#
# what is written
#

# a line of its own
emit(o: ref Out, s: string)
{
	o.l = s :: o.l;
	o.cont = 0;
}

# added to the last line
joinlast(o: ref Out, s: string)
{
	if(o.l == nil)
		o.l = s :: nil;
	else
		o.l = (hd o.l + s) :: tl o.l;
}

opener(f: int): string
{
	case f {
	I =>	return "\\emph{";
	B =>	return "\\textbf{";
	BI =>	return "\\textbf{\\emph{";
	SC =>	return "\\textsc{";
	TT =>	return "\\texttt{";
	}
	return "";
}

closer(f: int): string
{
	case f {
	R =>	return "";
	BI =>	return "}}";
	}
	return "}";
}

# added to the last line, unless that ends a paragraph
attach(o: ref Out, s: string)
{
	if(o.l == nil || hd o.l == "")
		emit(o, s);
	else
		joinlast(o, s);
}

# what puts the text in its font
fontsync(o: ref Out): string
{
	if(o.want == o.open)
		return "";
	s := closer(o.open) + opener(o.want);
	o.open = o.want;
	return s;
}

closefont(o: ref Out)
{
	if(o.open != R){
		joinlast(o, closer(o.open));
		o.open = R;
	}
}

setfont(o: ref Out, f: int)
{
	if(f < 0)
		f = o.prev;
	o.prev = o.want;
	o.want = f;
}

fontnamed(s: string): int
{
	case s {
	"R" or "1" =>	return R;
	"I" or "2" =>		return I;
	"B" or "3" =>		return B;
	"BI" or "4" =>		return BI;
	"SC" =>		return SC;
	"CW" or "CR" or "C" or "TT" =>	return TT;
	"P" or "" =>	return -1;
	}
	warn("font " + s + " set as roman");
	return R;
}

# a line of text
textline(o: ref Out, s: string)
{
	j := o.cont;
	o.cont = 0;
	t := text(o, s);
	if(o.noindent && !j){
		t = "\\noindent " + t;
		o.noindent = 0;
	}
	if(o.nf){
		if(o.nfline && !j)
			joinlast(o, "\\newline");
		o.nfline = 1;
	}
	c := o.cont;
	if(j && o.l != nil)
		joinlast(o, t);
	else
		emit(o, t);
	o.cont = c;
	o.intext = 1;
}

# text, with what it has open closed: a heading's, an argument's
textarg(s: string): string
{
	o := newout();
	t := text(o, s);
	return t + closer(o.open);
}

# troff's text as LaTeX's
text(o: ref Out, s: string): string
{
	r := "";
	i := 0;
	while(i < len s){
		c := s[i];
		if(c == '\\' && i + 1 < len s){
			(t, n) := escape(o, s, i);
			if(t != "")
				r += fontsync(o) + t;
			i = n;
			continue;
		}
		if(c == '\\'){	# alone at the end
			i++;
			continue;
		}
		if(dl1 && c == dl1){
			j := i + 1;
			while(j < len s && s[j] != dl2)
				j++;
			if(j < len s){
				r += fontsync(o) + "$" + eqn(s[i + 1:j], 0) + "$";
				i = j + 1;
				continue;
			}
		}
		t: string;
		case c {
		'#' or '$' or '%' or '&' or '_' or '{' or '}' =>
			t = "\\" + ch(c);
		'~' =>
			t = "\\textasciitilde{}";
		'^' =>
			t = "\\textasciicircum{}";
		'-' =>
			# troff's two hyphens are two, not LaTeX's dash
			if(i + 1 < len s && s[i + 1] == '-')
				t = "-{}";
			else
				t = "-";
		* =>
			t = ch(c);
		}
		# a space ends a font, but does not begin one
		if(c != ' ' && c != '\t' || o.want == R)
			r += fontsync(o);
		r += t;
		i++;
	}
	return r;
}

# an escape's argument, between the character after the escape and that
# character again (\h'1m'); its end
delimarg(s: string, i: int): (string, int)
{
	if(i >= len s)
		return ("", i);
	d := s[i];
	j := i + 1;
	while(j < len s && s[j] != d)
		j++;
	if(j >= len s)
		return (s[i + 1:], j);
	return (s[i + 1:j], j + 1);
}

# a name after an escape: x, (xx or [name]; its end
escname(s: string, i: int): (string, int)
{
	if(i >= len s)
		return ("", i);
	if(s[i] == '('){
		if(i + 3 > len s)
			return (s[i + 1:], len s);
		return (s[i + 1:i + 3], i + 3);
	}
	if(s[i] == '['){
		j := i + 1;
		while(j < len s && s[j] != ']')
			j++;
		if(j >= len s)
			return (s[i + 1:], j);
		return (s[i + 1:j], j + 1);
	}
	return (ch(s[i]), i + 1);
}

# an escape at s[i] (a backslash): its LaTeX, and the end
escape(o: ref Out, s: string, i: int): (string, int)
{
	c := s[i + 1];
	i += 2;
	case c {
	'\\' or 'e' or 'E' =>
		return ("\\textbackslash{}", i);
	'-' =>
		return ("−", i);
	'%' =>
		if(i - 3 >= 0 && i < len s && isalpha(s[i - 3]) && isalpha(s[i]))
			return ("\\-", i);
		return ("", i);
	'&' or ')' or 'z' or 'p' or 'r' or 'u' or 'd' or 'a' or '{' or '}' =>
		return ("", i);
	':' =>
		return ("\\allowbreak{}", i);
	' ' or '~' =>
		return ("~", i);
	'0' =>
		return ("\\hphantom{0}", i);
	'|' =>
		return ("\\,", i);
	'^' =>
		return ("\\hspace{0.0833em}", i);
	't' =>
		return (" ", i);
	'.' =>
		return (".", i);
	'\'' =>
		return ("´", i);
	'`' =>
		return ("`", i);
	'_' =>
		return ("\\_", i);
	'"' or '#' =>
		return ("", len s);
	'c' =>
		if(i >= len s)
			o.cont = 1;
		return ("", i);
	'f' =>
		(n, e) := escname(s, i);
		setfont(o, fontnamed(n));
		return ("", e);
	's' =>
		if(i < len s && (s[i] == '+' || s[i] == '-'))
			i++;
		if(i < len s && (s[i] == '(' || s[i] == '['))
			return ("", escname(s, i).t1);
		if(i < len s && s[i] == '\'')
			return ("", delimarg(s, i).t1);
		while(i < len s && isdigit(s[i]) && i < len s)
			i++;
		return ("", i);
	'(' or '[' =>
		(n, e) := escname(s, i - 1);
		return (tchar(n), e);
	'C' =>
		(n, e) := delimarg(s, i);
		return (tchar(n), e);
	'*' =>
		(n, e) := escname(s, i);
		return (strval(o, n), e);
	'n' =>
		if(i < len s && (s[i] == '+' || s[i] == '-'))
			i++;
		(n, e) := escname(s, i);
		if(n == "%")
			return ("\\thepage{}", e);
		return ("", e);
	'h' or 'v' or 'X' or 'w' or 'o' or 'D' or 'l' or 'L' or 'b' or 'x' or 'R' or 'Z' or 'N' or 'A' or 'B' or 'S' or 'H' =>
		(nil, e) := delimarg(s, i);
		return ("", e);
	'k' or 'g' or '$' or 'm' or 'M' or 'F' or 'Y' or 'V' =>
		(nil, e) := escname(s, i);
		return ("", e);
	}
	return (ch(c), i);
}

# a character troff names, as LaTeX writes it
tchar(n: string): string
{
	case n {
	"lq" =>	return "``";
	"rq" =>	return "''";
	"oq" =>	return "`";
	"cq" or "aq" =>	return "'";
	"em" =>	return "---";
	"en" =>	return "--";
	"hy" =>	return "-";
	"dq" =>	return "\"";
	"rs" or "\\" =>	return "\\textbackslash{}";
	"ti" =>	return "\\textasciitilde{}";
	"ha" =>	return "\\textasciicircum{}";
	"ul" or "_" =>	return "\\_";
	"sl" =>	return "/";
	"sh" =>	return "\\#";
	"Do" =>	return "\\$";
	"%" =>	return "\\%";
	"&" =>	return "\\&";
	"lC" =>	return "\\{";
	"rC" =>	return "\\}";
	"fi" or "fl" or "ff" or "Fi" or "Fl" =>	return n;
	}
	for(l := chars; l != nil; l = tl l)
		if((hd l).t0 == n)
			return (hd l).t1;
	warn("no character \\(" + n);
	return "";
}

# troff's names of characters, from the device's descriptions of its
# fonts: char name, then its width (or " for the character before) and
# its code
loadchars()
{
	for(fl := "R" :: "S" :: "DF" :: nil; fl != nil; fl = tl fl){
		f := bufio->open("/lib/troff/devutf/" + hd fl, Bufio->OREAD);
		if(f == nil)
			continue;
		last := "";
		while((s := f.gets('\n')) != nil){
			if(!prefix("char ", s))
				continue;
			(nil, fl2) := sys->tokenize(s[5:], "\t\n");
			if(fl2 == nil || tl fl2 == nil)
				continue;
			name := hd fl2;
			if(hd tl fl2 == "\""){
				if(last != "")
					chars = (name, last) :: chars;
				continue;
			}
			last = "";
			# width, type, glyph, code
			l := tl fl2;
			for(k := 0; k < 3 && l != nil; k++)
				l = tl l;
			# a character beyond ASCII is its own name, its code left out
			if(l != nil && int hd l > 32)
				last = ch(int hd l);
			else if(len name == 1 && name[0] > 16r7f)
				last = name;
			else
				continue;
			if(len name > 1)
				chars = (name, last) :: chars;
		}
	}
}

# a string's value: \*[ref name], \*[cite key loc] and the like, or the
# book's own (.ds)
strval(o: ref Out, n: string): string
{
	(nil, w) := sys->tokenize(n, " ");
	if(w == nil)
		return "";
	name := hd w;
	arg := "";
	if(len n > len name)
		arg = trim(n[len name:]);
	case name {
	"ref" =>
		return "\\ref{" + arg + "}";
	"pageref" =>
		return "\\pageref{" + arg + "}";
	"fnmark" =>
		o.fnmarked = 1;
		return "\\footnotemark{}";
	"enmark" =>
		o.enmarked = 1;
		haveendnotes = 1;
		return "\\endnotemark{}";
	"cite" =>
		havecites = 1;
		return cites("\\cite", arg);
	}
	for(l := strs; l != nil; l = tl l)
		if((hd l).t0 == name)
			return text(o, (hd l).t1);
	warn("no string " + name);
	return "";
}

# a citation: \autocite[loc]{key}, or \autocites[loc]{key}[loc]{key}
cites(cmd: string, s: string): string
{
	r := "";
	n := 0;
	(nil, l) := sys->tokenize(s, ";");
	for(; l != nil; l = tl l){
		c := trim(hd l);
		if(c == "")
			continue;
		key := c;
		loc := "";
		for(i := 0; i < len c; i++)
			if(c[i] == ' ' || c[i] == '\t'){
				key = c[0:i];
				loc = trim(c[i:]);
				break;
			}
		if(loc != "")
			r += "[" + range(textarg(loc)) + "]";
		r += "{" + key + "}";
		n++;
	}
	if(n > 1)
		return cmd + "s" + r;
	return cmd + r;
}

# 315-16 as 315--16
range(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		if(s[i] == '-' && i > 0 && i + 1 < len s && isdigit(s[i - 1]) && isdigit(s[i + 1]))
			r += "--";
		else
			r[len r] = s[i];
	}
	return r;
}

# a request's arguments, as troff reads them
reqargs(s: string): list of string
{
	r: list of string;
	i := 0;
	for(;;){
		while(i < len s && (s[i] == ' ' || s[i] == '\t'))
			i++;
		if(i >= len s)
			break;
		a := "";
		if(s[i] == '"'){
			i++;
			while(i < len s){
				if(s[i] == '"'){
					if(i + 1 < len s && s[i + 1] == '"'){
						a[len a] = '"';
						i += 2;
						continue;
					}
					i++;
					break;
				}
				a[len a] = s[i++];
			}
		}else{
			while(i < len s && s[i] != ' ' && s[i] != '\t')
				a[len a] = s[i++];
		}
		r = a :: r;
	}
	return rev(r);
}

arg(l: list of string, n: int): string
{
	for(; l != nil && n > 0; l = tl l)
		n--;
	if(l == nil)
		return "";
	return hd l;
}

# a length, troff's units as LaTeX's
dimen(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++)
		if(s[i] != '(' && s[i] != ')')
			t[len t] = s[i];
	if(t == "")
		return "0pt";
	case t[len t - 1] {
	'i' =>	return t[0:len t - 1] + "in";
	'c' =>	return t[0:len t - 1] + "cm";
	'p' =>	return t[0:len t - 1] + "pt";
	'P' =>	return t[0:len t - 1] + "pc";
	'm' =>	return t[0:len t - 1] + "em";
	'n' =>	return t[0:len t - 1] + "en";
	'v' =>	return t[0:len t - 1] + "\\baselineskip";
	'u' =>	return t[0:len t - 1] + "sp";
	}
	return t + "\\baselineskip";
}

#
# the book
#

book()
{
	blank := 0;
	while((s := readline()) != nil){
		if(s == "" || trim(s) == ""){
			if(!blank)
				paragraph();
			blank = 1;
			continue;
		}
		blank = 0;
		if(s[0] == '.' || s[0] == '\''){
			request(s);
			continue;
		}
		textline(cur, s);
	}
}

paragraph()
{
	o := cur;
	closefont(o);
	if(o.nf){
		emit(o, "");
		o.nfline = 0;
		return;
	}
	if(o.l != nil && hd o.l != "")
		emit(o, "");
	o.intext = 0;
	o.noindent = 0;
}

# a line of LaTeX of its own, what is open closed
block(s: string)
{
	closefont(cur);
	emit(cur, s);
	cur.intext = 0;
	cur.noindent = 0;
}

request(s: string)
{
	i := 1;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	if(i + 1 < len s && s[i] == '\\' && (s[i + 1] == '"' || s[i + 1] == '#')){
		closefont(cur);
		emit(cur, "%" + s[i + 2:]);
		cur.cont = 0;
		return;
	}
	j := i;
	while(j < len s && s[j] != ' ' && s[j] != '\t')
		j++;
	name := s[i:j];
	rest := s[j:];
	a := reqargs(rest);
	case name {
	"" =>
		;
	"title" =>
		title = textarg(join(a, " "));
	"subtitle" =>
		subtitle = textarg(join(a, " "));
	"author" =>
		author = textarg(join(a, " "));
	"date" =>
		date = textarg(join(a, " "));
	"maketitle" =>
		t := title;
		if(subtitle != "")
			t += "\\\\[1ex]\\large " + subtitle;
		block("\\title{" + t + "}");
		emit(cur, "\\author{" + author + "}");
		emit(cur, "\\date{" + date + "}");
		emit(cur, "\\maketitle");
	"frontmatter" =>
		numbered = 0;
		block("\\frontmatter");
	"mainmatter" =>
		numbered = 1;
		block("\\mainmatter");
	"backmatter" =>
		numbered = 0;
		block("\\backmatter");
	"part" =>
		blankline();
		block("\\part{" + textarg(arg(a, 0)) + "}");
	"chapter" or "chapter*" =>
		blankline();
		t := textarg(arg(a, 0));
		if(name == "chapter*"){
			block("\\chapter*{" + t + "}");
			if(arg(a, 0) != "Contents")
				emit(cur, "\\addcontentsline{toc}{chapter}{" + t + "}");
			emit(cur, "\\markboth{" + t + "}{" + t + "}");
			enhead = t;
		}else{
			block("\\chapter{" + t + "}");
			if(numbered){
				chapnum++;
				enhead = "Chapter " + string chapnum + ": " + t;
			}else
				enhead = t;
		}
		if(arg(a, 1) != "")
			emit(cur, "\\label{" + arg(a, 1) + "}");
	"section" or "subsection" =>
		blankline();
		block("\\" + name + "{" + textarg(arg(a, 0)) + "}");
		if(arg(a, 1) != "")
			emit(cur, "\\label{" + arg(a, 1) + "}");
	"p" or "PP" or "LP" =>
		paragraph();
	"quote" =>
		block("\\begin{quotation}");
	"endquote" =>
		block("\\end{quotation}");
		cur.noindent = 1;
	"epigraph" =>
		epigraph();
	"fn" =>
		note("fe", "\\footnote", "\\footnotetext");
	"en" =>
		haveendnotes = 1;
		if(enhead != ""){
			closefont(cur);
			attach(cur, "\\addtoendnotes{\\protect\\par\\protect\\medskip\\protect\\noindent\\protect\\textit{" + enhead + "}\\protect\\par\\protect\\smallskip}");
			enhead = "";
		}
		note("ee", "\\endnote", "\\endnotetext");
	"notes" =>
		blankline();
		block("\\chapter*{Notes}");
		emit(cur, "\\addcontentsline{toc}{chapter}{Notes}");
		emit(cur, "\\markboth{Notes}{Notes}");
		emit(cur, "\\theendnotes");
		haveendnotes = 1;
	"label" =>
		closefont(cur);
		attach(cur, "\\label{" + arg(a, 0) + "}");
	"contents" =>
		block("\\tableofcontents");
	"cite" =>
		havecites = 1;
		closefont(cur);
		attach(cur, cites("\\autocite", trim(rest)));
	"bibliography" =>
		blankline();
		havecites = 1;
		block("\\printbibliography[heading=bibintoc]");
	"index" =>
		haveindex = 1;
		closefont(cur);
		attach(cur, "\\index{" + indexentry(join(a, " ")) + "}");
	"printindex" =>
		haveindex = 1;
		blankline();
		block("\\printindex");
	"EQ" =>
		display(a);
	"TS" =>
		havetables = 1;
		table();
	"PS" =>
		havepics = 1;
		picture(s);
	"br" =>
		if(cur.intext && !cur.nf){
			closefont(cur);
			joinlast(cur, "\\newline");
		}
	"sp" =>
		d := "1\\baselineskip";
		if(arg(a, 0) != "")
			d = dimen(arg(a, 0));
		if(cur.nf){
			block("\\vspace{" + d + "}");
			cur.nfline = 0;
		}else{
			block("\\par\\vspace{" + d + "}");
			cur.noindent = 1;
		}
	"bp" =>
		block("\\clearpage");
	"ce" =>
		n := 1;
		if(arg(a, 0) != "")
			n = int arg(a, 0);
		if(n > 0)
			centre(n);
	"nf" =>
		if(!cur.nf){
			block("\\begin{flushleft}");
			cur.nf = 1;
			cur.nfline = 0;
		}
	"fi" =>
		if(cur.nf){
			cur.nf = 0;
			block("\\end{flushleft}");
			cur.noindent = 1;
		}
	"ft" =>
		setfont(cur, fontnamed(arg(a, 0)));
	"ds" or "as" =>
		dsreq(name, rest);
	"so" =>
		f := bufio->open(arg(a, 0), Bufio->OREAD);
		if(f == nil)
			warn(sys->sprint(".so %s: %r", arg(a, 0)));
		else
			inputs = ref Inp(f, arg(a, 0), 0) :: inputs;
	"de" or "am" or "ig" =>
		if(name != "ig")
			warn("macro " + arg(a, 0) + " not written as LaTeX");
		end := "..";
		if(name == "ig" && arg(a, 0) != "")
			end = "." + arg(a, 0);
		closefont(cur);
		emit(cur, "% troff: " + s);
		while((t := readline()) != nil && trim(t) != end)
			emit(cur, "% " + t);
	"hw" =>
		block("\\hyphenation{" + join(a, " ") + "}");
	"pn" =>
		block("\\setcounter{page}{" + arg(a, 0) + "}");
	"papersize" =>
		papersize[0] = dimen(arg(a, 0));
		papersize[1] = dimen(arg(a, 1));
	"margins" =>
		for(k := 0; k < 4; k++)
			if(arg(a, k) != "")
				margins[k] = dimen(arg(a, k));
	"nr" =>
		if(arg(a, 0) == "book-ps")
			ptsize = arg(a, 1) + "pt";
	"ne" or "ti" or "in" or "ll" or "ad" or "na" or "nh" or "hy" or "ps" or "vs" or
	"ls" or "ns" or "rs" or "pl" or "po" or "ta" or "lg" or "tm" or "ev" or "ss" or
	"cs" or "fp" or "ff" or "mtp" or "mte" or "mtpc" or "wo" or "mg" or "rules" or "kn" =>
		;
	* =>
		warn("." + name + " not written as LaTeX");
		closefont(cur);
		emit(cur, "% troff: " + s);
	}
}

# a blank line before a heading
blankline()
{
	closefont(cur);
	if(cur.l != nil && hd cur.l != "")
		emit(cur, "");
}

dsreq(name, rest: string)
{
	i := 0;
	while(i < len rest && (rest[i] == ' ' || rest[i] == '\t'))
		i++;
	j := i;
	while(j < len rest && rest[j] != ' ' && rest[j] != '\t')
		j++;
	n := rest[i:j];
	while(j < len rest && (rest[j] == ' ' || rest[j] == '\t'))
		j++;
	v := rest[j:];
	if(v != "" && v[0] == '"')
		v = v[1:];
	if(name == "as"){
		for(l := strs; l != nil; l = tl l)
			if((hd l).t0 == n){
				v = (hd l).t1 + v;
				break;
			}
	}
	strs = (n, v) :: strs;
}

# .ce n: n lines centred
centre(n: int)
{
	block("\\begin{center}");
	first := 1;
	while(n > 0 && (s := readline()) != nil){
		if(s != "" && (s[0] == '.' || s[0] == '\'')){
			unread(s);
			break;
		}
		if(!first)
			joinlast(cur, "\\\\");
		t := textarg(s);
		emit(cur, t);
		first = 0;
		n--;
	}
	block("\\end{center}");
	cur.noindent = 1;
}

# a footnote or endnote: its text, until .fe or .ee
note(end, cmd, textcmd: string)
{
	o := cur;
	closefont(o);
	marked := 0;
	if(cmd == "\\footnote"){
		marked = o.fnmarked;
		o.fnmarked = 0;
	}else{
		marked = o.enmarked;
		o.enmarked = 0;
	}
	n := newout();
	cur = n;
	while((s := readline()) != nil){
		if(len s > 1 && s[0] == '.' && trim(s[1:]) == end)
			break;
		if(trim(s) == "")
			paragraph();
		else if(s[0] == '.' || s[0] == '\'')
			request(s);
		else
			textline(n, s);
	}
	closefont(n);
	cur = o;
	body := join(rev(n.l), "\n");
	if(marked)
		cmd = textcmd;
	t := cmd + "{" + body + "}";
	if(o.cont && o.l != nil && hd o.l != "")
		joinlast(o, t);
	else
		emit(o, t);
	o.cont = 0;
	o.intext = 1;
}

# .epigraph text .attrib "source" .endepigraph
epigraph()
{
	haveepigraph = 1;
	o := cur;
	closefont(o);
	n := newout();
	cur = n;
	attrib := "";
	while((s := readline()) != nil){
		if(prefix(".endepigraph", s))
			break;
		if(prefix(".attrib", s)){
			attrib = "---~" + textarg(join(reqargs(s[7:]), " "));
			continue;
		}
		if(trim(s) == "")
			paragraph();
		else if(s[0] == '.' || s[0] == '\'')
			request(s);
		else
			textline(n, s);
	}
	closefont(n);
	cur = o;
	emit(o, "\\epigraph{" + join(rev(n.l), "\n") + "}{" + attrib + "}");
	o.noindent = 1;
}

# .index's entry: makeindex's, the text before its | (see{...} and the
# like) as LaTeX
indexentry(s: string): string
{
	for(i := 0; i < len s; i++){
		if(s[i] == '"'){
			i++;
			continue;
		}
		if(s[i] == '|')
			return textarg(s[0:i]) + s[i:];
	}
	return textarg(s);
}

#
# eqn's equations, as LaTeX's mathematics
#

# a display: .EQ [I|L|C] [label] ... .EN
display(a: list of string)
{
	if(a != nil && (hd a == "I" || hd a == "L" || hd a == "C"))
		a = tl a;
	label := join(a, " ");
	src := "";
	while((s := readline()) != nil && !prefix(".EN", s))
		src += s + "\n";
	m := trim(eqn(src, 1));
	if(m == "")
		return;
	closefont(cur);
	if(label != ""){
		if(len label > 2 && label[0] == '(' && label[len label - 1] == ')')
			label = "\\tag{" + label[1:len label - 1] + "}";
		else
			label = "\\tag*{" + label + "}";
		emit(cur, "\\begin{equation}");
		emit(cur, m + " " + label);
		emit(cur, "\\end{equation}");
	}else{
		emit(cur, "\\[");
		emit(cur, m);
		emit(cur, "\\]");
	}
	cur.noindent = 1;
}

# what eqn reads: the equation, and a define's body before the rest
Src: adt {
	s:	string;
	p:	int;
};
esrc: list of ref Src;
epeek: string;
epeeked := 0;
ecount := 0;
edisplay := 0;
eexpand := 0;
edefs: list of (string, string);

FROM, SUB: con 1 << iota;

eqn(s: string, disp: int): string
{
	esrc = ref Src(s, 0) :: nil;
	epeeked = 0;
	edisplay = disp;
	eexpand = 0;
	(r, nil) := elist(nil);
	return trim(r);
}

# a character of what is read, or -1
egetc(): int
{
	while(esrc != nil){
		t := hd esrc;
		if(t.p < len t.s)
			return t.s[t.p++];
		esrc = tl esrc;
	}
	return -1;
}

eungetc()
{
	if(esrc != nil)
		(hd esrc).p--;
}

eseparates(c: int): int
{
	return c == ' ' || c == '\n' || c == '\t' || c == '{' || c == '}' ||
		c == '~' || c == '^' || c == '"' || c == -1;
}

# a token: a word, { } ~ ^ a tab, or a quoted string ("text, its quote
# kept); a word defined, its definition read instead
elex(expand: int): string
{
	for(;;){
		c := egetc();
		while(c == ' ' || c == '\n')
			c = egetc();
		if(c < 0)
			return nil;
		case c {
		'\t' =>	return "\t";
		'{' =>	return "{";
		'}' =>	return "}";
		'~' =>	return "~";
		'^' =>	return "^";
		'"' =>
			s := "\"";
			while((c = egetc()) >= 0 && c != '"'){
				if(c == '\\'){
					c2 := egetc();
					if(c2 == '"'){
						s[len s] = '"';
						continue;
					}
					if(c2 >= 0)
						eungetc();
				}
				s[len s] = c;
			}
			return s;
		}
		s := "";
		while(!eseparates(c)){
			s[len s] = c;
			c = egetc();
		}
		if(c >= 0)
			eungetc();
		if(expand && eexpand < 1000)
			for(l := edefs; l != nil; l = tl l)
				if((hd l).t0 == s){
					eexpand++;
					esrc = ref Src((hd l).t1, 0) :: esrc;
					s = nil;
					break;
				}
		if(s != nil)
			return s;
	}
}

epk(): string
{
	if(!epeeked){
		epeek = elex(1);
		epeeked = 1;
	}
	return epeek;
}

enext(): string
{
	t := epk();
	epeeked = 0;
	ecount++;
	return t;
}

# a define's body: between the character after its name and that again
erawdelim(): string
{
	c := egetc();
	while(c == ' ' || c == '\t' || c == '\n')
		c = egetc();
	if(c < 0)
		return "";
	d := c;
	s := "";
	while((c = egetc()) >= 0 && c != d)
		s[len s] = c;
	return s;
}

# eqn's statements: define, delim, gsize and the rest; what they set
# here (delim, define) set; mark and lineup put aside
ecommands()
{
	for(;;){
		case epk() {
		"define" or "ndefine" or "tdefine" =>
			t := enext();
			epeeked = 0;
			name := elex(0);
			body := erawdelim();
			if(t != "ndefine")
				edefs = (name, body) :: edefs;
		"delim" =>
			enext();
			d := elex(0);
			if(d == "off" || len d < 2)
				dl1 = dl2 = 0;
			else{
				dl1 = d[0];
				dl2 = d[1];
			}
		"gsize" or "gfont" or "grfont" or "gbfont" =>
			enext();
			elex(0);
		"set" or "chartype" or "breakcost" =>
			enext();
			elex(0);
			elex(0);
		"bracketpieces" =>
			enext();
			for(k := 0; k < 5; k++)
				elex(0);
		"bracketsizes" =>
			enext();
			elex(0);
			n := int elex(0);
			for(k := 0; k < n && k < 100; k++)
				elex(0);
		"mark" or "lineup" =>
			enext();
		* =>
			return;
		}
	}
}

# boxes, until one of stops; which ended them
elist(stops: list of string): (string, string)
{
	r := "";
	for(;;){
		ecommands();
		t := epk();
		if(t == nil)
			return (r, nil);
		for(l := stops; l != nil; l = tl l)
			if(hd l == t){
				enext();
				return (r, t);
			}
		n := ecount;
		b := ebox();
		if(b != ""){
			if(r != "" && r[len r - 1] != ' ')
				r += " ";
			r += b;
		}
		if(ecount == n && epk() != nil){
			sys->fprint(stderr, "book2tex: eqn: %s out of place (%s line %d)\n", epk(), inname(), inline());
			enext();
		}
	}
}

ebox(): string
{
	b := eleft(0);
	while(epk() == "over"){
		enext();
		d := eleft(0);
		b = "\\frac{" + b + "}{" + d + "}";
	}
	return b;
}

# words that do not begin a box
estructural(t: string): int
{
	case t {
	"over" or "sub" or "sup" or "from" or "to" or "above" or "right" or "}" or
	"ccol" or "lcol" or "rcol" or "col" =>
		return 1;
	}
	return 0;
}

eleft(flg: int): string
{
	ecommands();
	t := epk();
	if(t == nil)
		return "";
	case t {
	"~" =>	enext(); return "\\ ";
	"^" =>	enext(); return "\\,";
	"\t" =>	enext(); return "\\quad ";
	}
	font := "";
	dx := 0;
	dy := 0;
	for(;;){
		case epk() {
		"fat" =>	enext();
		"roman" =>	enext(); font = "R";
		"italic" =>	enext(); font = "I";
		"bold" =>	enext(); font = "B";
		"font" =>
			enext();
			font = "R";
			case enext() {
			"I" or "2" =>	font = "I";
			"B" or "3" =>	font = "B";
			"BI" or "4" =>	font = "BI";
			"CW" or "CR" or "C" or "TT" =>	font = "TT";
			}
		"size" =>	enext(); enext();
		"fwd" =>	enext(); dx += int enext();
		"back" =>	enext(); dx -= int enext();
		"down" =>	enext(); dy += int enext();
		"up" =>	enext(); dy -= int enext();
		* =>
			break;
		}
		if(epk() == nil)
			break;
		case epk() {
		"fat" or "roman" or "italic" or "bold" or "font" or "size" or "fwd" or "back" or "down" or "up" =>
			continue;
		}
		break;
	}
	core := "";
	quoted := 0;
	t = epk();
	if(t == nil)
		;
	else if(t == "~" || t == "^" || t == "\t"){
		enext();
		case t {
		"~" =>	core = "\\ ";
		"^" =>	core = "\\,";
		* =>	core = "\\quad ";
		}
	}else if(t == "sqrt"){
		enext();
		core = "\\sqrt{" + eleft(0) + "}";
	}else if(t == "type"){
		enext();
		enext();
		core = eleft(flg);
	}else if(t == "pile" || t == "cpile"){
		core = epile("c");
	}else if(t == "lpile"){
		core = epile("l");
	}else if(t == "rpile"){
		core = epile("r");
	}else if(t == "matrix"){
		core = ematrix();
	}else if(t == "vcenter"){
		enext();
		core = eleft(flg);
	}else if(t == "ifdisplay"){
		enext();
		a := eleft(flg);
		b := eleft(flg);
		if(edisplay)
			core = a;
		else
			core = b;
	}else if(t == "{"){
		enext();
		(l, nil) := elist("}" :: nil);
		core = "{" + l + "}";
	}else if(t == "left"){
		enext();
		ld := edelim(enext(), 0);
		(l, st) := elist("right" :: nil);
		rd := ".";
		if(st != nil && epk() != nil)
			rd = edelim(enext(), 1);
		core = "\\left" + ld + " " + l + " \\right" + rd;
	}else if(!estructural(t)){
		enext();
		if(t[0] == '"'){
			core = estring(t[1:], font);
			quoted = 1;
		}else
			core = eword(t);
	}
	if(font != "" && !quoted && core != "")
		core = efont(font, core);
	if(dx)
		core = "\\hspace{" + em(dx) + "}" + core;
	if(dy)
		core = "\\raisebox{" + em(-dy) + "}{$" + core + "$}";
	for(;;){
		a := "";
		case epk() {
		"dyad" =>	a = "\\overleftrightarrow";
		"bar" =>	a = "\\overline";
		"under" =>	a = "\\underline";
		"vec" =>
			a = "\\vec";
			if(!esingle(core))
				a = "\\overrightarrow";
		"tilde" =>
			a = "\\tilde";
			if(!esingle(core))
				a = "\\widetilde";
		"hat" =>
			a = "\\hat";
			if(!esingle(core))
				a = "\\widehat";
		"dot" =>	a = "\\dot";
		"dotdot" =>	a = "\\ddot";
		}
		if(a == "")
			break;
		enext();
		core = a + "{" + core + "}";
	}
	subs, sups, froms, tos: string;
	if(epk() == "sub"){
		enext();
		subs = eleft(SUB);
	}
	if((subs != nil || !(flg & SUB)) && epk() == "sup"){
		enext();
		sups = eleft(0);
	}
	if(subs != nil || sups != nil){
		core = ebrace(core);
		if(subs != nil)
			core += "_{" + subs + "}";
		if(sups != nil)
			core += "^{" + sups + "}";
	}
	if(epk() == "from"){
		enext();
		froms = eleft(FROM);
	}
	if((froms != nil || !(flg & FROM)) && epk() == "to"){
		enext();
		tos = eleft(0);
	}
	if(froms != nil || tos != nil){
		case core {
		"\\sum" or "\\prod" or "\\bigcup" or "\\bigcap" or "\\lim" or "\\max" or "\\min" or "\\int" or "\\coprod" =>
			if(core == "\\int")
				core += "\\limits";
			if(froms != nil)
				core += "_{" + froms + "}";
			if(tos != nil)
				core += "^{" + tos + "}";
		* =>
			if(tos != nil)
				core = "\\overset{" + tos + "}{" + core + "}";
			if(froms != nil)
				core = "\\underset{" + froms + "}{" + core + "}";
		}
	}
	return core;
}

# one character, or one command: needs no braces
esingle(s: string): int
{
	if(len s == 1)
		return 1;
	if(len s < 2 || s[0] != '\\')
		return 0;
	for(i := 1; i < len s; i++)
		if(!isalpha(s[i]))
			return 0;
	return 1;
}

ebrace(s: string): string
{
	if(s == "")
		return "{}";
	if(esingle(s))
		return s;
	return "{" + s + "}";
}

em(n: int): string
{
	s := "";
	if(n < 0){
		s = "-";
		n = -n;
	}
	return s + sys->sprint("%d.%.2d", n / 100, n % 100) + "em";
}

efont(f, s: string): string
{
	case f {
	"R" =>	return "\\mathrm{" + s + "}";
	"I" =>	return "\\mathit{" + s + "}";
	"B" =>	return "\\symbf{" + s + "}";
	"BI" =>	return "\\symbfit{" + s + "}";
	"TT" =>	return "\\mathtt{" + s + "}";
	}
	return s;
}

# quoted text: eqn's italic, unless roman or bold
estring(s, font: string): string
{
	if(s == "")
		return "{}";
	# delimiters in the text are its own
	(d1, d2) := (dl1, dl2);
	dl1 = dl2 = 0;
	t := textarg(s);
	(dl1, dl2) = (d1, d2);
	case font {
	"R" =>	return "\\textrm{" + t + "}";
	"B" =>	return "\\textbf{" + t + "}";
	"BI" =>	return "\\textbf{\\textit{" + t + "}}";
	"TT" =>	return "\\texttt{" + t + "}";
	}
	return "\\textit{" + t + "}";
}

# left's or right's delimiter
edelim(t: string, right: int): string
{
	if(t != nil && t[0] == '"')
		t = t[1:];
	case t {
	"(" or ")" or "[" or "]" or "|" or "/" =>
		return t;
	"{" =>	return "\\{";
	"}" =>	return "\\}";
	"<" or "\\(la" =>	return "\\langle";
	">" or "\\(ra" =>	return "\\rangle";
	"floor" =>
		if(right)
			return "\\rfloor";
		return "\\lfloor";
	"ceiling" =>
		if(right)
			return "\\rceil";
		return "\\lceil";
	"\\(lf" =>	return "\\lfloor";
	"\\(rf" =>	return "\\rfloor";
	"\\(lc" =>	return "\\lceil";
	"\\(rc" =>	return "\\rceil";
	"||" or "\\(br" =>	return "\\|";
	}
	return ".";
}

# pile { a above b ... }
epile(align: string): string
{
	enext();
	if(epk() == "{")
		enext();
	rows: list of string;
	for(;;){
		(l, st) := elist("above" :: "}" :: nil);
		rows = l :: rows;
		if(st != "above")
			break;
	}
	return "\\begin{array}{" + align + "}" + join(rev(rows), " \\\\ ") + "\\end{array}";
}

# matrix { ccol { a above b } lcol { ... } }
ematrix(): string
{
	enext();
	if(epk() == "{")
		enext();
	aligns := "";
	cols: list of list of string;
	nrows := 0;
	for(;;){
		t := epk();
		if(t == nil)
			break;
		if(t == "}"){
			enext();
			break;
		}
		al := "";
		case t {
		"ccol" or "col" =>	al = "c";
		"lcol" =>	al = "l";
		"rcol" =>	al = "r";
		}
		enext();
		if(al == ""){
			sys->fprint(stderr, "book2tex: eqn: %s out of place in a matrix (%s line %d)\n", t, inname(), inline());
			continue;
		}
		if(epk() == "{")
			enext();
		col: list of string;
		n := 0;
		for(;;){
			(l, st) := elist("above" :: "}" :: nil);
			col = l :: col;
			n++;
			if(st != "above")
				break;
		}
		if(n > nrows)
			nrows = n;
		cols = rev(col) :: cols;
		aligns += al;
	}
	acols := array[len cols] of list of string;
	k := len cols;
	for(; cols != nil; cols = tl cols)
		acols[--k] = hd cols;
	rows: list of string;
	for(r := 0; r < nrows; r++){
		cells: list of string;
		for(c := 0; c < len acols; c++){
			v := "";
			if(acols[c] != nil){
				v = hd acols[c];
				acols[c] = tl acols[c];
			}
			cells = v :: cells;
		}
		rows = join(rev(cells), " & ") :: rows;
	}
	return "\\begin{array}{" + aligns + "}" + join(rev(rows), " \\\\ ") + "\\end{array}";
}

# eqn's words, and the characters operators are made of
ekw(w: string): (string, int)
{
	case w {
	"alpha" or "beta" or "gamma" or "delta" or "epsilon" or "zeta" or "eta" or
	"theta" or "iota" or "kappa" or "lambda" or "mu" or "nu" or "xi" or "pi" or
	"rho" or "sigma" or "tau" or "upsilon" or "phi" or "chi" or "psi" or "omega" =>
		return ("\\" + w, 1);
	"omicron" =>	return ("o", 1);
	"GAMMA" or "DELTA" or "THETA" or "LAMBDA" or "XI" or "PI" or "SIGMA" or
	"UPSILON" or "PHI" or "PSI" or "OMEGA" =>
		return ("\\" + w[0:1] + lower(w[1:]), 1);
	"ALPHA" =>	return ("\\mathrm{A}", 1);
	"BETA" =>	return ("\\mathrm{B}", 1);
	"CHI" =>	return ("\\mathrm{X}", 1);
	"EPSILON" =>	return ("\\mathrm{E}", 1);
	"ETA" =>	return ("\\mathrm{H}", 1);
	"IOTA" =>	return ("\\mathrm{I}", 1);
	"KAPPA" =>	return ("\\mathrm{K}", 1);
	"MU" =>	return ("\\mathrm{M}", 1);
	"NU" =>	return ("\\mathrm{N}", 1);
	"OMICRON" =>	return ("\\mathrm{O}", 1);
	"RHO" =>	return ("\\mathrm{P}", 1);
	"TAU" =>	return ("\\mathrm{T}", 1);
	"ZETA" =>	return ("\\mathrm{Z}", 1);
	"sin" or "cos" or "tan" or "sinh" or "cosh" or "tanh" or "coth" or "det" or
	"exp" or "lim" or "ln" or "log" or "max" or "min" =>
		return ("\\" + w, 1);
	"arc" =>	return ("\\mathrm{arc}", 1);
	"Im" or "Re" =>	return ("\\operatorname{" + w + "}", 1);
	"and" or "for" or "if" =>	return ("\\mathrm{" + w + "}", 1);
	"inf" or "infinity" =>	return ("\\infty", 1);
	"partial" =>	return ("\\partial", 1);
	"del" or "grad" =>	return ("\\nabla", 1);
	"times" =>	return ("\\times", 1);
	"cdot" =>	return ("\\cdot", 1);
	"approx" =>	return ("\\approx", 1);
	"half" =>	return ("\\frac{1}{2}", 1);
	"prime" =>	return ("{}'", 1);	# its own, after a superscript too
	"nothing" =>	return ("", 1);
	"dollar" =>	return ("\\$", 1);
	"sum" =>	return ("\\sum", 1);
	"int" =>	return ("\\int", 1);
	"prod" =>	return ("\\prod", 1);
	"union" =>	return ("\\bigcup", 1);
	"inter" =>	return ("\\bigcap", 1);
	}
	return (nil, 0);
}

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

eops := array[] of {
	(",...,", ",\\ldots,"), ("...", "\\ldots "), ("<=", "\\le "), (">=", "\\ge "),
	("==", "\\equiv "), ("!=", "\\ne "), ("->", "\\to "), ("<-", "\\gets "),
	("+-", "\\pm "), ("<<", "\\ll "), (">>", "\\gg "), (":=", "\\mathrel{:}= "),
};

# a word of an equation
eword(w: string): string
{
	(m, ok) := ekw(w);
	if(ok)
		return m;
	r := "";
	i := 0;
	Next:
	while(i < len w){
		c := w[i];
		if(c == '\\' && i + 1 < len w){
			(t, n) := mescape(w, i);
			r += t;
			i = n;
			continue;
		}
		for(k := 0; k < len eops; k++){
			(op, tex) := eops[k];
			if(len w - i >= len op && w[i:i + len op] == op){
				r += tex;
				i += len op;
				continue Next;
			}
		}
		if(isalpha(c)){
			j := i;
			while(j < len w && isalpha(w[j]))
				j++;
			run := w[i:j];
			(m, ok) = ekw(run);
			if(ok && run != "if" && run != "for" && run != "and")
				r += m + " ";
			else
				r += run;
			i = j;
			continue;
		}
		if(c >= 16r80){
			j := i;
			while(j < len w && w[j] >= 16r80)
				j++;
			if(j - i == 1)
				r += w[i:j];
			else
				r += "\\textit{" + w[i:j] + "}";
			i = j;
			continue;
		}
		case c {
		'#' or '$' or '%' or '&' or '_' =>
			r += "\\" + ch(c);
		* =>
			r += ch(c);
		}
		i++;
	}
	return trim(r);
}

# an escape in an equation
mescape(s: string, i: int): (string, int)
{
	c := s[i + 1];
	i += 2;
	case c {
	'(' or '[' =>
		(n, e) := escname(s, i - 1);
		return (mchar(n), e);
	'e' or '\\' =>
		return ("\\backslash ", i);
	' ' =>
		return ("\\ ", i);
	'|' or '^' =>
		return ("\\,", i);
	'f' =>
		(nil, e) := escname(s, i);
		return ("", e);
	's' =>
		if(i < len s && (s[i] == '+' || s[i] == '-'))
			i++;
		while(i < len s && isdigit(s[i]))
			i++;
		return ("", i);
	'-' =>
		return ("-", i);
	}
	return ("", i);
}

# a character troff names, in an equation
mchar(n: string): string
{
	case n {
	"mu" =>	return "\\times ";
	"mi" =>	return "-";
	"pl" =>	return "+";
	"eq" =>	return "=";
	"<=" =>	return "\\le ";
	">=" =>	return "\\ge ";
	"!=" =>	return "\\ne ";
	"+-" =>	return "\\pm ";
	"->" =>	return "\\to ";
	"<-" =>	return "\\gets ";
	"if" =>	return "\\infty ";
	"pd" =>	return "\\partial ";
	"gr" =>	return "\\nabla ";
	"sr" =>	return "\\surd ";
	"is" =>	return "\\int ";
	"su" =>	return "\\sum ";
	"pr" =>	return "\\prod ";
	"cu" =>	return "\\cup ";
	"ca" =>	return "\\cap ";
	"mo" =>	return "\\in ";
	"es" =>	return "\\emptyset ";
	"sb" =>	return "\\subset ";
	"sp" =>	return "\\supset ";
	"ib" =>	return "\\subseteq ";
	"ip" =>	return "\\supseteq ";
	"ap" =>	return "\\sim ";
	"~~" =>	return "\\approx ";
	"==" =>	return "\\equiv ";
	"de" =>	return "^{\\circ}";
	"fm" =>	return "'";
	"c." =>	return "\\cdot ";
	"**" =>	return "*";
	"br" or "or" =>	return "|";
	"lf" =>	return "\\lfloor ";
	"rf" =>	return "\\rfloor ";
	"lc" =>	return "\\lceil ";
	"rc" =>	return "\\rceil ";
	"la" =>	return "\\langle ";
	"ra" =>	return "\\rangle ";
	}
	t := tchar(n);
	case t {
	"---" =>	return "\\text{---}";
	"--" =>	return "\\text{--}";
	"``" or "''" or "`" =>	return "\\text{" + t + "}";
	}
	return t;
}

#
# tbl's tables, as tabulars
#

# a column's format: its key letter, font, rules before it
Fmt: adt {
	key:	int;
	font:	int;
	bars:	int;
	after:	int;	# rules after it, the last column's
};

table()
{
	closefont(cur);
	tab := '\t';
	centred := 0;
	box := 0;
	allbox := 0;
	s := readline();
	if(s == nil)
		return;
	# the options, ending in ;
	if(suffix(";", trim(s))){
		o := lower(s);
		if(contains(o, "center") || contains(o, "centre"))
			centred = 1;
		if(contains(o, "allbox"))
			allbox = 1;
		else if(contains(o, "doublebox") || contains(o, "doubleframe"))
			box = 2;
		else if(contains(o, "box") || contains(o, "frame"))
			box = 1;
		k := strindex(o, "tab(");
		if(k >= 0 && k + 4 < len s)
			tab = s[k + 4];
		s = readline();
	}
	(fmts, s2) := tblformats(s);
	s = s2;
	ncols := 0;
	for(fl := fmts; fl != nil; fl = tl fl)
		if(len hd fl > ncols)
			ncols = len hd fl;
	if(ncols == 0)
		ncols = 1;
	# the rows: cells, or a rule (nil, its kind)
	rows: list of (array of string, int);
	rowfmt: list of array of ref Fmt;
	fl = fmts;
	textcol := array[ncols] of {* => 0};
	for(; s != nil && !prefix(".TE", s); s = readline()){
		if(prefix(".T&", s)){
			(nf, s3) := tblformats(readline());
			if(nf != nil)
				fl = nf;
			unread(s3);
			continue;
		}
		if(s != "" && (s[0] == '.' || s[0] == '\''))
			continue;
		t := trim(s);
		if(t == "_" || t == "-"){
			rows = (nil, 1) :: rows;
			rowfmt = nil :: rowfmt;
			continue;
		}
		if(t == "="){
			rows = (nil, 2) :: rows;
			rowfmt = nil :: rowfmt;
			continue;
		}
		# a format all rules is a rule of its own
		while(fl != nil && tl fl != nil && allrules(hd fl)){
			rows = (nil, rulekind(hd fl)) :: rows;
			rowfmt = nil :: rowfmt;
			fl = tl fl;
		}
		cells := tblcells(s, tab);
		f: array of ref Fmt;
		if(fl != nil){
			f = hd fl;
			if(tl fl != nil)
				fl = tl fl;
		}
		for(k := 0; k < len cells && k < ncols; k++)
			if(cells[k] != "" && cells[k][0] == '\u0001'){
				cells[k] = cells[k][1:];
				textcol[k] = 1;
			}
		rows = (cells, 0) :: rows;
		rowfmt = f :: rowfmt;
	}
	# the columns' formats, from the first
	# the columns as the last format has them, which the most rows take
	first: array of ref Fmt;
	for(fl = fmts; fl != nil; fl = tl fl)
		first = hd fl;
	spec := "";
	for(c := 0; c < ncols; c++){
		b := 0;
		if(first != nil && c < len first)
			b = first[c].bars;
		if(allbox || box && c == 0)
			b = box + allbox;
		spec += bars(b);
		key := 'l';
		if(first != nil && c < len first)
			key = first[c].key;
		if(textcol[c])
			spec += "p{" + sys->sprint("%.2f", 0.8 / real ncols) + "\\linewidth}";
		else
			spec += align(key);
	}
	if(allbox || box)
		spec += bars(box + allbox);
	else if(first != nil && len first > 0)
		spec += bars(first[len first - 1].after);
	if(centred)
		emit(cur, "\\begin{center}");
	else
		emit(cur, "\\par\\noindent");
	emit(cur, "\\begin{tabular}{" + spec + "}");
	if(box || allbox)
		emit(cur, hline(box + allbox));
	rl := rev2(rows);
	ff := revf(rowfmt);
	for(; rl != nil; rl = tl rl){
		(cells, rule) := hd rl;
		f := hd ff;
		ff = tl ff;
		if(cells == nil){
			emit(cur, hline(rule));
			continue;
		}
		line := "";
		k := 0;
		while(k < ncols){
			key := 'l';
			font := R;
			if(f != nil && k < len f){
				key = f[k].key;
				font = f[k].font;
			}
			v := "";
			if(k < len cells)
				v = cells[k];
			span := 1;
			while(k + span < ncols && f != nil && k + span < len f && f[k + span].key == 's')
				span++;
			cell := "";
			tv := trim(v);
			if(key == '^' || key == '_' || key == '-' || key == '=' || key == 's')
				cell = "";
			else if(tv == "\\_" || tv == "_" || tv == "=")
				cell = "\\hrulefill";
			else{
				cell = textarg(v);
				if(font == B)
					cell = "\\textbf{" + cell + "}";
				else if(font == I)
					cell = "\\emph{" + cell + "}";
				else if(font == BI)
					cell = "\\textbf{\\emph{" + cell + "}}";
			}
			fk := 'l';
			if(first != nil && k < len first)
				fk = first[k].key;
			if(span > 1 || align(key) != align(fk) && key != '^' && key != 's' && !textcol[k]){
				lb := "";
				rb := "";
				if(k == 0)
					lb = bars(box + allbox);
				if(allbox || k + span == ncols && box)
					rb = bars(box + allbox);
				cell = "\\multicolumn{" + string span + "}{" + lb + align(key) + rb + "}{" + cell + "}";
			}
			if(k > 0)
				line += " & ";
			line += cell;
			k += span;
		}
		line += " \\\\";
		if(allbox && tl rl != nil && (hd tl rl).t0 != nil)
			line += " \\hline";
		emit(cur, line);
	}
	if(box || allbox)
		emit(cur, hline(box + allbox));
	emit(cur, "\\end{tabular}");
	if(centred)
		emit(cur, "\\end{center}");
	else
		emit(cur, "\\par");
	cur.intext = 0;
	cur.noindent = 1;
}

bars(n: int): string
{
	s := "";
	while(n-- > 0)
		s += "|";
	return s;
}

hline(n: int): string
{
	if(n >= 2)
		return "\\hline\\hline";
	return "\\hline";
}

align(key: int): string
{
	case key {
	'r' or 'n' =>	return "r";
	'c' =>	return "c";
	}
	return "l";
}

allrules(f: array of ref Fmt): int
{
	if(f == nil || len f == 0)
		return 0;
	for(i := 0; i < len f; i++)
		if(f[i].key != '_' && f[i].key != '-' && f[i].key != '=')
			return 0;
	return 1;
}

rulekind(f: array of ref Fmt): int
{
	if(f[0].key == '=')
		return 2;
	return 1;
}

contains(s, t: string): int
{
	return strindex(s, t) >= 0;
}

strindex(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i + len t] == t)
			return i;
	return -1;
}

rev2(l: list of (array of string, int)): list of (array of string, int)
{
	r: list of (array of string, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revf(l: list of array of ref Fmt): list of array of ref Fmt
{
	r: list of array of ref Fmt;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# a table's formats, the lines from s to the one ending in .; the line
# after them
tblformats(s: string): (list of array of ref Fmt, string)
{
	fmts: list of array of ref Fmt;
	for(; s != nil; s = readline()){
		t := trim(s);
		last := suffix(".", t);
		if(last)
			t = t[0:len t - 1];
		(nil, rl) := sys->tokenize(t, ",");
		for(; rl != nil; rl = tl rl)
			fmts = tblrow(hd rl) :: fmts;
		if(last)
			break;
	}
	r: list of array of ref Fmt;
	for(; fmts != nil; fmts = tl fmts)
		r = hd fmts :: r;
	return (r, readline());
}

# a format's row: l r c n a s ^ _ = and their fonts (b i f), and rules (|)
tblrow(s: string): array of ref Fmt
{
	cols: list of ref Fmt;
	bars := 0;
	i := 0;
	while(i < len s){
		c := s[i++];
		case c {
		'|' =>
			bars++;
		'l' or 'L' or 'r' or 'R' or 'c' or 'C' or 'n' or 'N' or 'a' or 'A' or
		's' or 'S' or '^' or '_' or '-' or '=' =>
			k := c;
			if(k >= 'A' && k <= 'Z')
				k += 'a' - 'A';
			cols = ref Fmt(k, R, bars, 0) :: cols;
			bars = 0;
		'b' or 'B' =>
			if(cols != nil)
				(hd cols).font = addfont((hd cols).font, B);
		'i' or 'I' =>
			if(cols != nil)
				(hd cols).font = addfont((hd cols).font, I);
		'f' or 'F' =>
			n := "";
			if(i + 2 < len s && s[i] == '('){
				n = s[i + 1:i + 3];
				i += 3;
			}else if(i < len s){
				n = s[i:i + 1];
				i++;
			}
			if(cols != nil)
				(hd cols).font = fontnamed(n);
		'w' or 'W' or 'p' or 'P' or 'v' or 'V' =>
			if(i < len s && s[i] == '('){
				while(i < len s && s[i] != ')')
					i++;
				i++;
			}else
				while(i < len s && (isdigit(s[i]) || s[i] == '.' || s[i] == '+' || s[i] == '-'))
					i++;
		}
	}
	if(cols != nil)
		(hd cols).after = bars;
	n := 0;
	for(l := cols; l != nil; l = tl l)
		n++;
	a := array[n] of ref Fmt;
	for(l = cols; l != nil; l = tl l)
		a[--n] = hd l;
	return a;
}

addfont(f, g: int): int
{
	if(f == B && g == I || f == I && g == B)
		return BI;
	return g;
}

# a data line's cells; a text block (T{ to T}) a cell, marked \001
tblcells(s: string, tab: int): array of string
{
	cells: list of string;
	for(;;){
		c := "";
		i := 0;
		for(; i < len s && s[i] != tab; i++)
			c[len c] = s[i];
		if(c == "T{"){
			blk := "";
			t: string;
			while((t = readline()) != nil && !prefix("T}", t)){
				if(blk != "")
					blk += " ";
				blk += t;
			}
			cells = ("\u0001" + blk) :: cells;
			if(t == nil)
				break;
			s = t[2:];
			if(s != "" && s[0] == tab){
				s = s[1:];
				continue;
			}
			break;
		}
		cells = c :: cells;
		if(i >= len s)
			break;
		s = s[i + 1:];
	}
	a := array[len cells] of string;
	k := len a;
	for(; cells != nil; cells = tl cells)
		a[--k] = hd cells;
	return a;
}

#
# pic's pictures
#

picture(first: string)
{
	closefont(cur);
	src := first + "\n";
	while((s := readline()) != nil){
		src += s + "\n";
		if(prefix(".PE", s))
			break;
	}
	npics++;
	stem := "book";
	if(outname != nil){
		stem = outname;
		for(i := len stem - 1; i >= 0; i--)
			if(stem[i] == '.'){
				stem = stem[0:i];
				break;
			}else if(stem[i] == '/')
				break;
	}
	name := stem + "-pic" + string npics;
	emit(cur, "% pic:");
	for((nil, l) := sys->tokenize(src, "\n"); l != nil; l = tl l)
		emit(cur, "% " + hd l);
	if(outname != nil && drawpic(src, name)){
		base := name;
		for(i := len base - 1; i >= 0; i--)
			if(base[i] == '/'){
				base = base[i + 1:];
				break;
			}
		emit(cur, "\\begin{center}");
		emit(cur, "\\includegraphics{" + base + "}");
		emit(cur, "\\end{center}");
	}else{
		emit(cur, "\\begin{center}");
		emit(cur, "\\fbox{\\textit{a picture (pic)}}");
		emit(cur, "\\end{center}");
	}
	cur.noindent = 1;
}

# a picture as a PDF of its own: pic's .PS line gives its height and
# width; troff sets it on a page that size, tr2pdf writes it
drawpic(src, name: string): int
{
	sh := load Sh Sh->PATH;
	if(sh == nil){
		warn(sys->sprint("cannot load sh: %r"));
		return 0;
	}
	tmp := name + ".pic";
	if(writefile(tmp, src) < 0)
		return 0;
	err := sh->system(ctxt, "pic < " + quote(tmp) + " > " + quote(name + ".tr"));
	if(err != nil){
		warn("pic: " + err);
		return 0;
	}
	out := readfile(name + ".tr");
	ht := 0.0;
	wd := 0.0;
	for((nil, l) := sys->tokenize(out, "\n"); l != nil; l = tl l)
		if(prefix(".PS ", hd l)){
			(nil, w) := sys->tokenize(hd l, " ");
			if(len w >= 3){
				ht = real hd tl w;
				wd = real hd tl tl w;
			}
			break;
		}
	if(ht <= 0.0 || wd <= 0.0){
		warn("pic gave no size for " + name);
		return 0;
	}
	pw := int (wd * 72.0 + 0.999) + 2;
	ph := int (ht * 72.0 + 0.999) + 2;
	doc := sys->sprint(".pl %dp\n.po 1p\n.ll %dp\n.vs 0\n\\X'papersize %dx%d'\n.sp |1p\n", ph, pw, pw, ph) +
		".de PS\n..\n.de PE\n..\n" + out;
	if(writefile(name + ".tr", doc) < 0)
		return 0;
	err = sh->system(ctxt, "troff < " + quote(name + ".tr") + " | tr2pdf > " + quote(name + ".pdf"));
	sys->remove(tmp);
	sys->remove(name + ".tr");
	if(err != nil){
		warn("troff | tr2pdf: " + err);
		return 0;
	}
	return 1;
}

quote(s: string): string
{
	r := "'";
	for(i := 0; i < len s; i++){
		if(s[i] == '\'')
			r += "'";
		r[len r] = s[i];
	}
	return r + "'";
}

writefile(name, s: string): int
{
	fd := sys->create(name, Sys->OWRITE, 8r666);
	if(fd == nil){
		warn(sys->sprint("%s: %r", name));
		return -1;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b){
		warn(sys->sprint("%s: %r", name));
		return -1;
	}
	return 0;
}

readfile(name: string): string
{
	f := bufio->open(name, Bufio->OREAD);
	if(f == nil)
		return "";
	s := "";
	while((t := f.gets('\n')) != nil)
		s += t;
	return s;
}

#
# the preamble: what the book uses
#

preamble(): string
{
	s := "% made by book2tex from " + srcname + "; for LuaLaTeX:\n";
	s += "%\tlualatex; biber; makeindex; lualatex; lualatex\n";
	s += "\\documentclass[" + ptsize + ",openright]{book}\n";
	s += "\\usepackage[paperwidth=" + papersize[0] + ",paperheight=" + papersize[1] +
		",top=" + margins[0] + ",bottom=" + margins[1] +
		",inner=" + margins[2] + ",outer=" + margins[3] + "]{geometry}\n";
	s += "\\usepackage{amsmath}\n";
	s += "\\usepackage{fontspec}\n";
	s += "\\usepackage{unicode-math}\n";
	s += "\\setmainfont{Libertinus Serif}\n";
	s += "\\setsansfont{Libertinus Sans}\n";
	s += "\\setmonofont{Libertinus Mono}\n";
	s += "\\setmathfont{Libertinus Math}\n";
	s += "\\usepackage{microtype}\n";
	s += "\\setlength{\\parindent}{1.5em}\n";
	if(haveepigraph){
		s += "\\usepackage{epigraph}\n";
		s += "\\setlength{\\epigraphwidth}{0.6\\textwidth}\n";
		s += "\\setlength{\\epigraphrule}{0pt}\n";
	}
	if(haveendnotes){
		s += "\\usepackage{endnotes}\n";
		s += "\\counterwithin*{endnote}{chapter}\n";
		s += "\\renewcommand{\\enoteheading}{}\n";
		s += "\\renewcommand{\\notesname}{Notes}\n";
	}
	if(havecites){
		b := bib;
		if(b == ""){
			b = srcname;
			for(i := len b - 1; i >= 0 && b[i] != '/'; i--)
				if(b[i] == '.'){
					b = b[0:i];
					break;
				}
			b += ".bib";
			warn("citations, and no database (-p): " + b + " is taken to be it");
		}else if(!suffix(".bib", b))
			warn(b + " is not BibTeX's, as biblatex needs");
		s += "\\usepackage[notes,backend=biber]{biblatex-chicago}\n";
		s += "\\addbibresource{" + b + "}\n";
	}
	if(haveindex){
		s += "\\usepackage{imakeidx}\n";
		s += "\\makeindex[intoc,columns=2]\n";
	}
	if(havepics)
		s += "\\usepackage{graphicx}\n";
	s += "\\usepackage[hidelinks]{hyperref}\n";
	s += "\\begin{document}\n";
	return s;
}
