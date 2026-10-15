implement Mkindex;

#
# mkindex - a book's index, from troff's output
#
#	mkindex [-l] [book.out ...]
#
# Reads troff's output for the entries -mbook's .index put there (x X
# idx ...) and the folio of each page (x X folio ...), and writes the
# index as troff's input for -mbook's .printindex: an entry a line, after
# .book-ix and its level, in the order of The Chicago Manual of Style
# (word by word, accents and case aside), each entry's pages after it.
#
# An entry is written as makeindex's: levels apart by !, a sort key
# before @ (aretē@ἀρετή sorts as aretē), and after | one of see{...},
# seealso{...}, ( and ) (a range's beginning and end, either with a
# format after it), textbf, textit or emph (its page in bold or italic).
# " quotes the next character.  Three pages or more in a row are a
# range; a range's second number is abbreviated as the Manual
# abbreviates it (101–8, 321–28).
# -l writes each page as -mbook's \*[book-pl folio shown]: a link to the
# page (book(1) gives it).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Mkindex: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# a page an entry is on
Loc: adt {
	pg:	int;	# the page, counted from the first
	fmt:	string;	# textbf, textit, or nil
	kind:	int;	# Single, Begin, End
};
Single, Begin, End: con iota;

Ent: adt {
	keys:	array of string;	# each level's sort key, folded
	shows:	array of string;	# each level as set
	locs:	list of Loc;
	see:	list of string;
	seealso:	list of string;
};

ents: list of ref Ent;
folio := array[64] of string;	# each page's folio
npg := 0;
stderr: ref Sys->FD;

links := 0;	# -l: each page a link to it (-mbook's \*[book-pl])

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	stderr = sys->fildes(2);
	if(args != nil)
		args = tl args;
	if(args != nil && hd args == "-l"){
		links = 1;
		args = tl args;
	}
	if(args == nil)
		read(bufio->fopen(sys->fildes(0), Bufio->OREAD));
	for(; args != nil; args = tl args){
		b := bufio->open(hd args, Bufio->OREAD);
		if(b == nil){
			sys->fprint(stderr, "mkindex: cannot open %s: %r\n", hd args);
			raise "fail:open";
		}
		read(b);
	}
	out := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	write(out);
	out.flush();
}

read(b: ref Iobuf)
{
	while((l := b.gets('\n')) != nil){
		if(len l > 0 && l[len l - 1] == '\n')
			l = l[0:len l - 1];
		if(len l > 1 && l[0] == 'p' && isdigit(l[1])){
			npg++;
			if(npg >= len folio){
				f := array[2 * len folio] of string;
				f[0:] = folio;
				folio = f;
			}
		}else if(prefix("x X idx ", l))
			entry(l[len "x X idx ":], npg);
		else if(prefix("x X folio ", l))
			folio[npg] = l[len "x X folio ":];
	}
}

# an entry, as makeindex reads it
entry(s: string, pg: int)
{
	# the levels, and what follows |, " quoting
	lv: list of string;
	cur := "";
	enc := "";
	inenc := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '"' && i + 1 < len s){
			cur[len cur] = s[++i];
			continue;
		}
		if(inenc){
			enc[len enc] = c;
			continue;
		}
		if(c == '!'){
			lv = cur :: lv;
			cur = "";
		}else if(c == '|')
			inenc = 1;
		else
			cur[len cur] = c;
	}
	lv = cur :: lv;
	n := 0;
	for(l := lv; l != nil; l = tl l)
		n++;
	if(n > 3){
		sys->fprint(stderr, "mkindex: more than three levels: %s\n", s);
		return;
	}
	keys := array[n] of string;
	shows := array[n] of string;
	for(k := n - 1; k >= 0; k--){
		v := trim(hd lv);
		lv = tl lv;
		show := v;
		key := v;
		for(j := 0; j < len v; j++)
			if(v[j] == '@'){
				key = trim(v[0:j]);
				show = trim(v[j + 1:]);
				break;
			}
		if(show == nil){
			sys->fprint(stderr, "mkindex: an empty level: %s\n", s);
			return;
		}
		keys[k] = sortkey(key);
		shows[k] = show;
	}
	e := find(keys, shows);
	enc = trim(enc);
	if(prefix("see{", enc) && enc[len enc - 1] == '}')
		e.see = add(e.see, enc[4:len enc - 1]);
	else if(prefix("seealso{", enc) && enc[len enc - 1] == '}')
		e.seealso = add(e.seealso, enc[8:len enc - 1]);
	else{
		kind := Single;
		if(prefix("(", enc)){
			kind = Begin;
			enc = enc[1:];
		}else if(prefix(")", enc)){
			kind = End;
			enc = enc[1:];
		}
		case enc {
		"" or "textbf" or "textit" =>
			;
		"emph" =>
			enc = "textit";
		* =>
			sys->fprint(stderr, "mkindex: unknown |%s: %s\n", enc, s);
			enc = "";
		}
		e.locs = Loc(pg, enc, kind) :: e.locs;
	}
}

find(keys, shows: array of string): ref Ent
{
	for(l := ents; l != nil; l = tl l){
		e := hd l;
		if(len e.keys != len keys)
			continue;
		same := 1;
		for(i := 0; i < len keys && same; i++)
			same = e.keys[i] == keys[i] && e.shows[i] == shows[i];
		if(same)
			return e;
	}
	e := ref Ent(keys, shows, nil, nil, nil);
	ents = e :: ents;
	return e;
}

#
# order
#

# what an entry is sorted by: troff's escapes and punctuation out, a
# hyphen a space (word by word), letters folded
sortkey(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\\' && i + 1 < len s){
			i++;
			case s[i] {
			'f' or 's' or 'm' or '*' or 'n' =>
				i = escarg(s, i + 1);
			'(' =>
				i += 2;
			'[' =>
				while(i < len s && s[i] != ']')
					i++;
			'-' =>
				r += " ";
			'&' or '%' or '|' or '^' or ':' or 'c' =>
				;
			* =>
				r[len r] = s[i];
			}
			continue;
		}
		if(c == '-' || c == '–' || c == '—' || c == '/' || c == '\t')
			c = ' ';
		if(c == ' '){
			if(len r > 0 && r[len r - 1] != ' ')
				r += " ";
			continue;
		}
		if(isalnum(c))
			r += fold(c);
	}
	return trim(r);
}

# past an escape's argument: X, (XX or [XXX], or a size's ±N
escarg(s: string, i: int): int
{
	if(i >= len s)
		return i;
	case s[i] {
	'(' =>
		return i + 2;
	'[' =>
		while(i < len s && s[i] != ']')
			i++;
		return i;
	'+' or '-' =>
		i++;
	}
	while(i + 1 < len s && isdigit(s[i]) && isdigit(s[i + 1]))
		i++;
	return i;
}

isalnum(c: int): int
{
	return isdigit(c) || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
		c >= 16rc0 && c != 16rd7 && c != 16rf7 && c < 16r2000;
}

foldmap: array of string;

fold(c: int): string
{
	if(foldmap == nil){
		foldmap = array[16r2000] of string;
		for(i := 0; i < len foldtab; i++){
			(k, v) := foldtab[i];
			foldmap[k] = v;
		}
	}
	if(c >= 'A' && c <= 'Z')
		c += 'a' - 'A';
	if(c < len foldmap && foldmap[c] != nil)
		return foldmap[c];
	s := "";
	s[0] = c;
	return s;
}

# an entry's place in the index: a heading at its level, its own entry
# if it was indexed itself, its subentries
Node: adt {
	key:	string;
	show:	string;
	ent:	ref Ent;
	kids:	list of ref Node;
};

tree(): ref Node
{
	root := ref Node("", "", nil, nil);
	for(l := ents; l != nil; l = tl l){
		e := hd l;
		n := root;
		for(i := 0; i < len e.keys; i++){
			k: ref Node;
			for(t := n.kids; t != nil; t = tl t)
				if((hd t).key == e.keys[i] && (hd t).show == e.shows[i]){
					k = hd t;
					break;
				}
			if(k == nil){
				k = ref Node(e.keys[i], e.shows[i], nil, nil);
				n.kids = k :: n.kids;
			}
			n = k;
		}
		n.ent = e;
	}
	return root;
}

# a before b: by key (word by word: a space before any letter), then as set
before(a, b: ref Node): int
{
	if(a.key != b.key)
		return a.key < b.key;
	return a.show < b.show;
}

sorted(l: list of ref Node): array of ref Node
{
	n := 0;
	for(t := l; t != nil; t = tl t)
		n++;
	a := array[n] of ref Node;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	msort(a, array[n] of ref Node);
	return a;
}

msort(a, t: array of ref Node)
{
	if(len a < 2)
		return;
	m := len a / 2;
	msort(a[0:m], t[0:m]);
	msort(a[m:], t[m:]);
	i := 0;
	j := m;
	for(k := 0; k < len a; k++)
		if(j >= len a || i < m && !before(a[j], a[i]))
			t[k] = a[i++];
		else
			t[k] = a[j++];
	a[0:] = t[0:len a];
}

#
# writing
#

write(out: ref Iobuf)
{
	a := sorted(tree().kids);
	group := "";
	for(i := 0; i < len a; i++){
		g := groupof(a[i].key);
		if(i > 0 && g != group)
			out.puts(".book-ixgroup\n");
		group = g;
		emit(out, a[i], 0);
	}
}

# an entry: its heading, pages and cross-references; then its
# subentries, after them its See also
emit(out: ref Iobuf, n: ref Node, level: int)
{
	text := n.show;
	also := "";
	if((e := n.ent) != nil){
		if((pages := pagesof(e)) != nil)
			text += ", " + pages;
		if(e.see != nil)
			text += ". \\fISee\\fP " + join(rev(e.see), "; ");
		if(e.seealso != nil)
			also = join(rev(e.seealso), "; ");
	}
	if(also != nil && n.kids == nil){
		if(e.see != nil)
			text += "; \\fIsee also\\fP " + also;
		else
			text += ". \\fISee also\\fP " + also;
		also = nil;
	}
	line(out, level, text);
	kids := sorted(n.kids);
	for(i := 0; i < len kids; i++)
		emit(out, kids[i], level + 1);
	if(also != nil)
		line(out, level + 1, "\\fISee also\\fP " + also);
}

line(out: ref Iobuf, level: int, s: string)
{
	out.puts(sys->sprint(".book-ix %d\n", level));
	if(len s > 0 && (s[0] == '.' || s[0] == '\''))
		s = "\\&" + s;
	out.puts(s + "\n");
}

# the group an entry is in: its first letter, digits and signs together
groupof(k: string): string
{
	if(k == nil || isdigit(k[0]) || !isalnum(k[0]))
		return "";
	return k[0:1];
}

# an entry's pages: in order, each once, three or more in a row a range
pagesof(e: ref Ent): string
{
	# the pages, each once, ranges given by ( and ) marked
	n := 0;
	for(l := e.locs; l != nil; l = tl l)
		n++;
	locs := array[n] of Loc;
	for(l = e.locs; l != nil; l = tl l)
		locs[--n] = hd l;
	sortlocs(locs);
	# a page once, in its strongest format (bold, italic, plain)
	nk := 0;
	for(m := 0; m < len locs; m++){
		if(nk > 0 && locs[m].kind == Single && locs[nk - 1].kind == Single && locs[m].pg == locs[nk - 1].pg){
			if(rank(locs[m].fmt) > rank(locs[nk - 1].fmt))
				locs[nk - 1].fmt = locs[m].fmt;
			continue;
		}
		locs[nk++] = locs[m];
	}
	locs = locs[0:nk];
	# explicit ranges first: a Begin to its End takes the pages between
	parts: list of string;
	i := 0;
	while(i < len locs){
		lc := locs[i];
		if(lc.kind == Begin){
			j := i + 1;
			while(j < len locs && locs[j].kind != End)
				j++;
			if(j >= len locs){
				sys->fprint(stderr, "mkindex: a range of %s not ended\n", e.shows[len e.shows - 1]);
				j = i;
			}
			parts = fmt(lc.fmt, span(lc.pg, locs[j].pg)) :: parts;
			i = j + 1;
			continue;
		}
		if(lc.kind == End){	# not begun
			sys->fprint(stderr, "mkindex: a range of %s ended, not begun\n", e.shows[len e.shows - 1]);
			i++;
			continue;
		}
		# a run of pages in a row, of the same format
		j := i;
		while(j + 1 < len locs && locs[j + 1].kind == Single && locs[j + 1].fmt == lc.fmt &&
				locs[j + 1].pg <= locs[j].pg + 1 && samekind(lc.pg, locs[j + 1].pg))
			j++;
		if(locs[j].pg - lc.pg >= 2)
			parts = fmt(lc.fmt, span(lc.pg, locs[j].pg)) :: parts;
		else
			for(k := i; k <= j; k++)
				if(k == i || locs[k].pg != locs[k - 1].pg)
					parts = fmt(lc.fmt, pagelink(folioof(locs[k].pg), folioof(locs[k].pg))) :: parts;
		i = j + 1;
	}
	return join(rev(parts), ", ");
}

sortlocs(a: array of Loc)
{
	for(i := 1; i < len a; i++){
		t := a[i];
		j := i;
		while(j > 0 && (a[j - 1].pg > t.pg || a[j - 1].pg == t.pg && a[j - 1].kind > t.kind)){
			a[j] = a[j - 1];
			j--;
		}
		a[j] = t;
	}
}

rank(f: string): int
{
	case f {
	"textbf" =>
		return 2;
	"textit" =>
		return 1;
	}
	return 0;
}

fmt(f, s: string): string
{
	case f {
	"textbf" =>
		return "\\fB" + s + "\\fP";
	"textit" =>
		return "\\fI" + s + "\\fP";
	}
	return s;
}

folioof(pg: int): string
{
	if(pg < len folio && folio[pg] != nil)
		return folio[pg];
	return "?";
}

# pages a to b: the second number abbreviated, a roman range in full
span(a, b: int): string
{
	fa := folioof(a);
	fb := folioof(b);
	if(fa == fb)
		return pagelink(fa, fa);
	if(isnum(fa) && isnum(fb))
		return pagelink(fa, fa) + "–" + pagelink(fb, inclusive(fa, fb));
	return pagelink(fa, fa) + "–" + pagelink(fb, fb);
}

# a page as shown: with -l, a link to the page whose folio is f
pagelink(f, shown: string): string
{
	if(!links || f == "?")
		return shown;
	return "\\*[book-pl " + f + " " + shown + "]";
}

# both arabic, or both not
samekind(a, b: int): int
{
	return isnum(folioof(a)) == isnum(folioof(b));
}

isnum(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++)
		if(!isdigit(s[i]))
			return 0;
	return 1;
}

# the Manual's inclusive numbers: 3–10, 71–72, 101–8, 321–28, 1496–1504
inclusive(a, b: string): string
{
	x := int a;
	y := int b;
	if(len a != len b || y <= x || x < 100 || x % 100 == 0)
		return b;
	k := 0;
	while(k < len a && a[k] == b[k])
		k++;
	if(len a == 4 && len a - k >= 3)
		return b;
	if(x % 100 >= 10 && len b - k < 2)
		k = len b - 2;
	return b[k:];
}

#
# strings
#

# l with s, once
add(l: list of string, s: string): list of string
{
	for(t := l; t != nil; t = tl t)
		if(hd t == s)
			return l;
	return s :: l;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

join(l: list of string, sep: string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != nil)
			s += sep;
		s += hd l;
	}
	return s;
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

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

# letters folded for sorting: lower case, accents and breathings off, ligatures
# spelt out (from Unicode's decompositions; made by a script, not by hand)
foldtab := array[] of {
	(16r00c0, "a"), (16r00c1, "a"), (16r00c2, "a"), (16r00c3, "a"),
	(16r00c4, "a"), (16r00c5, "a"), (16r00c6, "ae"), (16r00c7, "c"),
	(16r00c8, "e"), (16r00c9, "e"), (16r00ca, "e"), (16r00cb, "e"),
	(16r00cc, "i"), (16r00cd, "i"), (16r00ce, "i"), (16r00cf, "i"),
	(16r00d0, "d"), (16r00d1, "n"), (16r00d2, "o"), (16r00d3, "o"),
	(16r00d4, "o"), (16r00d5, "o"), (16r00d6, "o"), (16r00d8, "o"),
	(16r00d9, "u"), (16r00da, "u"), (16r00db, "u"), (16r00dc, "u"),
	(16r00dd, "y"), (16r00de, "th"), (16r00df, "ss"), (16r00e0, "a"),
	(16r00e1, "a"), (16r00e2, "a"), (16r00e3, "a"), (16r00e4, "a"),
	(16r00e5, "a"), (16r00e6, "ae"), (16r00e7, "c"), (16r00e8, "e"),
	(16r00e9, "e"), (16r00ea, "e"), (16r00eb, "e"), (16r00ec, "i"),
	(16r00ed, "i"), (16r00ee, "i"), (16r00ef, "i"), (16r00f0, "d"),
	(16r00f1, "n"), (16r00f2, "o"), (16r00f3, "o"), (16r00f4, "o"),
	(16r00f5, "o"), (16r00f6, "o"), (16r00f8, "o"), (16r00f9, "u"),
	(16r00fa, "u"), (16r00fb, "u"), (16r00fc, "u"), (16r00fd, "y"),
	(16r00fe, "th"), (16r00ff, "y"), (16r0100, "a"), (16r0101, "a"),
	(16r0102, "a"), (16r0103, "a"), (16r0104, "a"), (16r0105, "a"),
	(16r0106, "c"), (16r0107, "c"), (16r0108, "c"), (16r0109, "c"),
	(16r010a, "c"), (16r010b, "c"), (16r010c, "c"), (16r010d, "c"),
	(16r010e, "d"), (16r010f, "d"), (16r0110, "d"), (16r0111, "d"),
	(16r0112, "e"), (16r0113, "e"), (16r0114, "e"), (16r0115, "e"),
	(16r0116, "e"), (16r0117, "e"), (16r0118, "e"), (16r0119, "e"),
	(16r011a, "e"), (16r011b, "e"), (16r011c, "g"), (16r011d, "g"),
	(16r011e, "g"), (16r011f, "g"), (16r0120, "g"), (16r0121, "g"),
	(16r0122, "g"), (16r0123, "g"), (16r0124, "h"), (16r0125, "h"),
	(16r0126, "h"), (16r0127, "h"), (16r0128, "i"), (16r0129, "i"),
	(16r012a, "i"), (16r012b, "i"), (16r012c, "i"), (16r012d, "i"),
	(16r012e, "i"), (16r012f, "i"), (16r0130, "i"), (16r0131, "i"),
	(16r0132, "ĳ"), (16r0134, "j"), (16r0135, "j"), (16r0136, "k"),
	(16r0137, "k"), (16r0139, "l"), (16r013a, "l"), (16r013b, "l"),
	(16r013c, "l"), (16r013d, "l"), (16r013e, "l"), (16r013f, "ŀ"),
	(16r0141, "l"), (16r0142, "l"), (16r0143, "n"), (16r0144, "n"),
	(16r0145, "n"), (16r0146, "n"), (16r0147, "n"), (16r0148, "n"),
	(16r014a, "ŋ"), (16r014c, "o"), (16r014d, "o"), (16r014e, "o"),
	(16r014f, "o"), (16r0150, "o"), (16r0151, "o"), (16r0152, "oe"),
	(16r0153, "oe"), (16r0154, "r"), (16r0155, "r"), (16r0156, "r"),
	(16r0157, "r"), (16r0158, "r"), (16r0159, "r"), (16r015a, "s"),
	(16r015b, "s"), (16r015c, "s"), (16r015d, "s"), (16r015e, "s"),
	(16r015f, "s"), (16r0160, "s"), (16r0161, "s"), (16r0162, "t"),
	(16r0163, "t"), (16r0164, "t"), (16r0165, "t"), (16r0166, "ŧ"),
	(16r0168, "u"), (16r0169, "u"), (16r016a, "u"), (16r016b, "u"),
	(16r016c, "u"), (16r016d, "u"), (16r016e, "u"), (16r016f, "u"),
	(16r0170, "u"), (16r0171, "u"), (16r0172, "u"), (16r0173, "u"),
	(16r0174, "w"), (16r0175, "w"), (16r0176, "y"), (16r0177, "y"),
	(16r0178, "y"), (16r0179, "z"), (16r017a, "z"), (16r017b, "z"),
	(16r017c, "z"), (16r017d, "z"), (16r017e, "z"), (16r0181, "ɓ"),
	(16r0182, "ƃ"), (16r0184, "ƅ"), (16r0186, "ɔ"), (16r0187, "ƈ"),
	(16r0189, "ɖ"), (16r018a, "ɗ"), (16r018b, "ƌ"), (16r018e, "ǝ"),
	(16r018f, "ə"), (16r0190, "ɛ"), (16r0191, "ƒ"), (16r0193, "ɠ"),
	(16r0194, "ɣ"), (16r0196, "ɩ"), (16r0197, "ɨ"), (16r0198, "ƙ"),
	(16r019c, "ɯ"), (16r019d, "ɲ"), (16r019f, "ɵ"), (16r01a0, "o"),
	(16r01a1, "o"), (16r01a2, "ƣ"), (16r01a4, "ƥ"), (16r01a6, "ʀ"),
	(16r01a7, "ƨ"), (16r01a9, "ʃ"), (16r01ac, "ƭ"), (16r01ae, "ʈ"),
	(16r01af, "u"), (16r01b0, "u"), (16r01b1, "ʊ"), (16r01b2, "ʋ"),
	(16r01b3, "ƴ"), (16r01b5, "ƶ"), (16r01b7, "ʒ"), (16r01b8, "ƹ"),
	(16r01bc, "ƽ"), (16r01c4, "ǆ"), (16r01c5, "ǆ"), (16r01c7, "ǉ"),
	(16r01c8, "ǉ"), (16r01ca, "ǌ"), (16r01cb, "ǌ"), (16r01cd, "a"),
	(16r01ce, "a"), (16r01cf, "i"), (16r01d0, "i"), (16r01d1, "o"),
	(16r01d2, "o"), (16r01d3, "u"), (16r01d4, "u"), (16r01d5, "u"),
	(16r01d6, "u"), (16r01d7, "u"), (16r01d8, "u"), (16r01d9, "u"),
	(16r01da, "u"), (16r01db, "u"), (16r01dc, "u"), (16r01de, "a"),
	(16r01df, "a"), (16r01e0, "a"), (16r01e1, "a"), (16r01e2, "æ"),
	(16r01e3, "æ"), (16r01e4, "ǥ"), (16r01e6, "g"), (16r01e7, "g"),
	(16r01e8, "k"), (16r01e9, "k"), (16r01ea, "o"), (16r01eb, "o"),
	(16r01ec, "o"), (16r01ed, "o"), (16r01ee, "ʒ"), (16r01ef, "ʒ"),
	(16r01f0, "j"), (16r01f1, "ǳ"), (16r01f2, "ǳ"), (16r01f4, "g"),
	(16r01f5, "g"), (16r01f6, "ƕ"), (16r01f7, "ƿ"), (16r01f8, "n"),
	(16r01f9, "n"), (16r01fa, "a"), (16r01fb, "a"), (16r01fc, "æ"),
	(16r01fd, "æ"), (16r01fe, "ø"), (16r01ff, "ø"), (16r0200, "a"),
	(16r0201, "a"), (16r0202, "a"), (16r0203, "a"), (16r0204, "e"),
	(16r0205, "e"), (16r0206, "e"), (16r0207, "e"), (16r0208, "i"),
	(16r0209, "i"), (16r020a, "i"), (16r020b, "i"), (16r020c, "o"),
	(16r020d, "o"), (16r020e, "o"), (16r020f, "o"), (16r0210, "r"),
	(16r0211, "r"), (16r0212, "r"), (16r0213, "r"), (16r0214, "u"),
	(16r0215, "u"), (16r0216, "u"), (16r0217, "u"), (16r0218, "s"),
	(16r0219, "s"), (16r021a, "t"), (16r021b, "t"), (16r021c, "ȝ"),
	(16r021e, "h"), (16r021f, "h"), (16r0220, "ƞ"), (16r0222, "ȣ"),
	(16r0224, "ȥ"), (16r0226, "a"), (16r0227, "a"), (16r0228, "e"),
	(16r0229, "e"), (16r022a, "o"), (16r022b, "o"), (16r022c, "o"),
	(16r022d, "o"), (16r022e, "o"), (16r022f, "o"), (16r0230, "o"),
	(16r0231, "o"), (16r0232, "y"), (16r0233, "y"), (16r023a, "ⱥ"),
	(16r023b, "ȼ"), (16r023d, "ƚ"), (16r023e, "ⱦ"), (16r0241, "ɂ"),
	(16r0243, "ƀ"), (16r0244, "ʉ"), (16r0245, "ʌ"), (16r0246, "ɇ"),
	(16r0248, "ɉ"), (16r024a, "ɋ"), (16r024c, "ɍ"), (16r024e, "ɏ"),
	(16r0370, "ͱ"), (16r0372, "ͳ"), (16r0374, "ʹ"), (16r0376, "ͷ"),
	(16r037f, "ϳ"), (16r0386, "α"), (16r0388, "ε"), (16r0389, "η"),
	(16r038a, "ι"), (16r038c, "ο"), (16r038e, "υ"), (16r038f, "ω"),
	(16r0390, "ι"), (16r0391, "α"), (16r0392, "β"), (16r0393, "γ"),
	(16r0394, "δ"), (16r0395, "ε"), (16r0396, "ζ"), (16r0397, "η"),
	(16r0398, "θ"), (16r0399, "ι"), (16r039a, "κ"), (16r039b, "λ"),
	(16r039c, "μ"), (16r039d, "ν"), (16r039e, "ξ"), (16r039f, "ο"),
	(16r03a0, "π"), (16r03a1, "ρ"), (16r03a3, "σ"), (16r03a4, "τ"),
	(16r03a5, "υ"), (16r03a6, "φ"), (16r03a7, "χ"), (16r03a8, "ψ"),
	(16r03a9, "ω"), (16r03aa, "ι"), (16r03ab, "υ"), (16r03ac, "α"),
	(16r03ad, "ε"), (16r03ae, "η"), (16r03af, "ι"), (16r03b0, "υ"),
	(16r03c2, "σ"), (16r03ca, "ι"), (16r03cb, "υ"), (16r03cc, "ο"),
	(16r03cd, "υ"), (16r03ce, "ω"), (16r03cf, "ϗ"), (16r03d0, "β"),
	(16r03d1, "θ"), (16r03d3, "ϒ"), (16r03d4, "ϒ"), (16r03d5, "φ"),
	(16r03d6, "π"), (16r03d8, "ϙ"), (16r03da, "ϛ"), (16r03dc, "ϝ"),
	(16r03de, "ϟ"), (16r03e0, "ϡ"), (16r03e2, "ϣ"), (16r03e4, "ϥ"),
	(16r03e6, "ϧ"), (16r03e8, "ϩ"), (16r03ea, "ϫ"), (16r03ec, "ϭ"),
	(16r03ee, "ϯ"), (16r03f0, "κ"), (16r03f1, "ρ"), (16r03f2, "σ"),
	(16r03f4, "θ"), (16r03f5, "ε"), (16r03f7, "ϸ"), (16r03f9, "ϲ"),
	(16r03fa, "ϻ"), (16r03fd, "ͻ"), (16r03fe, "ͼ"), (16r03ff, "ͽ"),
	(16r1e00, "a"), (16r1e01, "a"), (16r1e02, "b"), (16r1e03, "b"),
	(16r1e04, "b"), (16r1e05, "b"), (16r1e06, "b"), (16r1e07, "b"),
	(16r1e08, "c"), (16r1e09, "c"), (16r1e0a, "d"), (16r1e0b, "d"),
	(16r1e0c, "d"), (16r1e0d, "d"), (16r1e0e, "d"), (16r1e0f, "d"),
	(16r1e10, "d"), (16r1e11, "d"), (16r1e12, "d"), (16r1e13, "d"),
	(16r1e14, "e"), (16r1e15, "e"), (16r1e16, "e"), (16r1e17, "e"),
	(16r1e18, "e"), (16r1e19, "e"), (16r1e1a, "e"), (16r1e1b, "e"),
	(16r1e1c, "e"), (16r1e1d, "e"), (16r1e1e, "f"), (16r1e1f, "f"),
	(16r1e20, "g"), (16r1e21, "g"), (16r1e22, "h"), (16r1e23, "h"),
	(16r1e24, "h"), (16r1e25, "h"), (16r1e26, "h"), (16r1e27, "h"),
	(16r1e28, "h"), (16r1e29, "h"), (16r1e2a, "h"), (16r1e2b, "h"),
	(16r1e2c, "i"), (16r1e2d, "i"), (16r1e2e, "i"), (16r1e2f, "i"),
	(16r1e30, "k"), (16r1e31, "k"), (16r1e32, "k"), (16r1e33, "k"),
	(16r1e34, "k"), (16r1e35, "k"), (16r1e36, "l"), (16r1e37, "l"),
	(16r1e38, "l"), (16r1e39, "l"), (16r1e3a, "l"), (16r1e3b, "l"),
	(16r1e3c, "l"), (16r1e3d, "l"), (16r1e3e, "m"), (16r1e3f, "m"),
	(16r1e40, "m"), (16r1e41, "m"), (16r1e42, "m"), (16r1e43, "m"),
	(16r1e44, "n"), (16r1e45, "n"), (16r1e46, "n"), (16r1e47, "n"),
	(16r1e48, "n"), (16r1e49, "n"), (16r1e4a, "n"), (16r1e4b, "n"),
	(16r1e4c, "o"), (16r1e4d, "o"), (16r1e4e, "o"), (16r1e4f, "o"),
	(16r1e50, "o"), (16r1e51, "o"), (16r1e52, "o"), (16r1e53, "o"),
	(16r1e54, "p"), (16r1e55, "p"), (16r1e56, "p"), (16r1e57, "p"),
	(16r1e58, "r"), (16r1e59, "r"), (16r1e5a, "r"), (16r1e5b, "r"),
	(16r1e5c, "r"), (16r1e5d, "r"), (16r1e5e, "r"), (16r1e5f, "r"),
	(16r1e60, "s"), (16r1e61, "s"), (16r1e62, "s"), (16r1e63, "s"),
	(16r1e64, "s"), (16r1e65, "s"), (16r1e66, "s"), (16r1e67, "s"),
	(16r1e68, "s"), (16r1e69, "s"), (16r1e6a, "t"), (16r1e6b, "t"),
	(16r1e6c, "t"), (16r1e6d, "t"), (16r1e6e, "t"), (16r1e6f, "t"),
	(16r1e70, "t"), (16r1e71, "t"), (16r1e72, "u"), (16r1e73, "u"),
	(16r1e74, "u"), (16r1e75, "u"), (16r1e76, "u"), (16r1e77, "u"),
	(16r1e78, "u"), (16r1e79, "u"), (16r1e7a, "u"), (16r1e7b, "u"),
	(16r1e7c, "v"), (16r1e7d, "v"), (16r1e7e, "v"), (16r1e7f, "v"),
	(16r1e80, "w"), (16r1e81, "w"), (16r1e82, "w"), (16r1e83, "w"),
	(16r1e84, "w"), (16r1e85, "w"), (16r1e86, "w"), (16r1e87, "w"),
	(16r1e88, "w"), (16r1e89, "w"), (16r1e8a, "x"), (16r1e8b, "x"),
	(16r1e8c, "x"), (16r1e8d, "x"), (16r1e8e, "y"), (16r1e8f, "y"),
	(16r1e90, "z"), (16r1e91, "z"), (16r1e92, "z"), (16r1e93, "z"),
	(16r1e94, "z"), (16r1e95, "z"), (16r1e96, "h"), (16r1e97, "t"),
	(16r1e98, "w"), (16r1e99, "y"), (16r1e9b, "ſ"), (16r1e9e, "ß"),
	(16r1ea0, "a"), (16r1ea1, "a"), (16r1ea2, "a"), (16r1ea3, "a"),
	(16r1ea4, "a"), (16r1ea5, "a"), (16r1ea6, "a"), (16r1ea7, "a"),
	(16r1ea8, "a"), (16r1ea9, "a"), (16r1eaa, "a"), (16r1eab, "a"),
	(16r1eac, "a"), (16r1ead, "a"), (16r1eae, "a"), (16r1eaf, "a"),
	(16r1eb0, "a"), (16r1eb1, "a"), (16r1eb2, "a"), (16r1eb3, "a"),
	(16r1eb4, "a"), (16r1eb5, "a"), (16r1eb6, "a"), (16r1eb7, "a"),
	(16r1eb8, "e"), (16r1eb9, "e"), (16r1eba, "e"), (16r1ebb, "e"),
	(16r1ebc, "e"), (16r1ebd, "e"), (16r1ebe, "e"), (16r1ebf, "e"),
	(16r1ec0, "e"), (16r1ec1, "e"), (16r1ec2, "e"), (16r1ec3, "e"),
	(16r1ec4, "e"), (16r1ec5, "e"), (16r1ec6, "e"), (16r1ec7, "e"),
	(16r1ec8, "i"), (16r1ec9, "i"), (16r1eca, "i"), (16r1ecb, "i"),
	(16r1ecc, "o"), (16r1ecd, "o"), (16r1ece, "o"), (16r1ecf, "o"),
	(16r1ed0, "o"), (16r1ed1, "o"), (16r1ed2, "o"), (16r1ed3, "o"),
	(16r1ed4, "o"), (16r1ed5, "o"), (16r1ed6, "o"), (16r1ed7, "o"),
	(16r1ed8, "o"), (16r1ed9, "o"), (16r1eda, "o"), (16r1edb, "o"),
	(16r1edc, "o"), (16r1edd, "o"), (16r1ede, "o"), (16r1edf, "o"),
	(16r1ee0, "o"), (16r1ee1, "o"), (16r1ee2, "o"), (16r1ee3, "o"),
	(16r1ee4, "u"), (16r1ee5, "u"), (16r1ee6, "u"), (16r1ee7, "u"),
	(16r1ee8, "u"), (16r1ee9, "u"), (16r1eea, "u"), (16r1eeb, "u"),
	(16r1eec, "u"), (16r1eed, "u"), (16r1eee, "u"), (16r1eef, "u"),
	(16r1ef0, "u"), (16r1ef1, "u"), (16r1ef2, "y"), (16r1ef3, "y"),
	(16r1ef4, "y"), (16r1ef5, "y"), (16r1ef6, "y"), (16r1ef7, "y"),
	(16r1ef8, "y"), (16r1ef9, "y"), (16r1efa, "ỻ"), (16r1efc, "ỽ"),
	(16r1efe, "ỿ"), (16r1f00, "α"), (16r1f01, "α"), (16r1f02, "α"),
	(16r1f03, "α"), (16r1f04, "α"), (16r1f05, "α"), (16r1f06, "α"),
	(16r1f07, "α"), (16r1f08, "α"), (16r1f09, "α"), (16r1f0a, "α"),
	(16r1f0b, "α"), (16r1f0c, "α"), (16r1f0d, "α"), (16r1f0e, "α"),
	(16r1f0f, "α"), (16r1f10, "ε"), (16r1f11, "ε"), (16r1f12, "ε"),
	(16r1f13, "ε"), (16r1f14, "ε"), (16r1f15, "ε"), (16r1f18, "ε"),
	(16r1f19, "ε"), (16r1f1a, "ε"), (16r1f1b, "ε"), (16r1f1c, "ε"),
	(16r1f1d, "ε"), (16r1f20, "η"), (16r1f21, "η"), (16r1f22, "η"),
	(16r1f23, "η"), (16r1f24, "η"), (16r1f25, "η"), (16r1f26, "η"),
	(16r1f27, "η"), (16r1f28, "η"), (16r1f29, "η"), (16r1f2a, "η"),
	(16r1f2b, "η"), (16r1f2c, "η"), (16r1f2d, "η"), (16r1f2e, "η"),
	(16r1f2f, "η"), (16r1f30, "ι"), (16r1f31, "ι"), (16r1f32, "ι"),
	(16r1f33, "ι"), (16r1f34, "ι"), (16r1f35, "ι"), (16r1f36, "ι"),
	(16r1f37, "ι"), (16r1f38, "ι"), (16r1f39, "ι"), (16r1f3a, "ι"),
	(16r1f3b, "ι"), (16r1f3c, "ι"), (16r1f3d, "ι"), (16r1f3e, "ι"),
	(16r1f3f, "ι"), (16r1f40, "ο"), (16r1f41, "ο"), (16r1f42, "ο"),
	(16r1f43, "ο"), (16r1f44, "ο"), (16r1f45, "ο"), (16r1f48, "ο"),
	(16r1f49, "ο"), (16r1f4a, "ο"), (16r1f4b, "ο"), (16r1f4c, "ο"),
	(16r1f4d, "ο"), (16r1f50, "υ"), (16r1f51, "υ"), (16r1f52, "υ"),
	(16r1f53, "υ"), (16r1f54, "υ"), (16r1f55, "υ"), (16r1f56, "υ"),
	(16r1f57, "υ"), (16r1f59, "υ"), (16r1f5b, "υ"), (16r1f5d, "υ"),
	(16r1f5f, "υ"), (16r1f60, "ω"), (16r1f61, "ω"), (16r1f62, "ω"),
	(16r1f63, "ω"), (16r1f64, "ω"), (16r1f65, "ω"), (16r1f66, "ω"),
	(16r1f67, "ω"), (16r1f68, "ω"), (16r1f69, "ω"), (16r1f6a, "ω"),
	(16r1f6b, "ω"), (16r1f6c, "ω"), (16r1f6d, "ω"), (16r1f6e, "ω"),
	(16r1f6f, "ω"), (16r1f70, "α"), (16r1f71, "α"), (16r1f72, "ε"),
	(16r1f73, "ε"), (16r1f74, "η"), (16r1f75, "η"), (16r1f76, "ι"),
	(16r1f77, "ι"), (16r1f78, "ο"), (16r1f79, "ο"), (16r1f7a, "υ"),
	(16r1f7b, "υ"), (16r1f7c, "ω"), (16r1f7d, "ω"), (16r1f80, "α"),
	(16r1f81, "α"), (16r1f82, "α"), (16r1f83, "α"), (16r1f84, "α"),
	(16r1f85, "α"), (16r1f86, "α"), (16r1f87, "α"), (16r1f88, "α"),
	(16r1f89, "α"), (16r1f8a, "α"), (16r1f8b, "α"), (16r1f8c, "α"),
	(16r1f8d, "α"), (16r1f8e, "α"), (16r1f8f, "α"), (16r1f90, "η"),
	(16r1f91, "η"), (16r1f92, "η"), (16r1f93, "η"), (16r1f94, "η"),
	(16r1f95, "η"), (16r1f96, "η"), (16r1f97, "η"), (16r1f98, "η"),
	(16r1f99, "η"), (16r1f9a, "η"), (16r1f9b, "η"), (16r1f9c, "η"),
	(16r1f9d, "η"), (16r1f9e, "η"), (16r1f9f, "η"), (16r1fa0, "ω"),
	(16r1fa1, "ω"), (16r1fa2, "ω"), (16r1fa3, "ω"), (16r1fa4, "ω"),
	(16r1fa5, "ω"), (16r1fa6, "ω"), (16r1fa7, "ω"), (16r1fa8, "ω"),
	(16r1fa9, "ω"), (16r1faa, "ω"), (16r1fab, "ω"), (16r1fac, "ω"),
	(16r1fad, "ω"), (16r1fae, "ω"), (16r1faf, "ω"), (16r1fb0, "α"),
	(16r1fb1, "α"), (16r1fb2, "α"), (16r1fb3, "α"), (16r1fb4, "α"),
	(16r1fb6, "α"), (16r1fb7, "α"), (16r1fb8, "α"), (16r1fb9, "α"),
	(16r1fba, "α"), (16r1fbb, "α"), (16r1fbc, "α"), (16r1fbe, "ι"),
	(16r1fc2, "η"), (16r1fc3, "η"), (16r1fc4, "η"), (16r1fc6, "η"),
	(16r1fc7, "η"), (16r1fc8, "ε"), (16r1fc9, "ε"), (16r1fca, "η"),
	(16r1fcb, "η"), (16r1fcc, "η"), (16r1fd0, "ι"), (16r1fd1, "ι"),
	(16r1fd2, "ι"), (16r1fd3, "ι"), (16r1fd6, "ι"), (16r1fd7, "ι"),
	(16r1fd8, "ι"), (16r1fd9, "ι"), (16r1fda, "ι"), (16r1fdb, "ι"),
	(16r1fe0, "υ"), (16r1fe1, "υ"), (16r1fe2, "υ"), (16r1fe3, "υ"),
	(16r1fe4, "ρ"), (16r1fe5, "ρ"), (16r1fe6, "υ"), (16r1fe7, "υ"),
	(16r1fe8, "υ"), (16r1fe9, "υ"), (16r1fea, "υ"), (16r1feb, "υ"),
	(16r1fec, "ρ"), (16r1ff2, "ω"), (16r1ff3, "ω"), (16r1ff4, "ω"),
	(16r1ff6, "ω"), (16r1ff7, "ω"), (16r1ff8, "ο"), (16r1ff9, "ο"),
	(16r1ffa, "ω"), (16r1ffb, "ω"), (16r1ffc, "ω")
};
