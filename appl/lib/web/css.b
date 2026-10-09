implement Css;

#
# CSS syntax.  See module/web/css.m.
#
# Tokenizing follows CSS Syntax 3 §4; the token stream is then folded
# into component values (functions and blocks hold their contents), and
# every later stage walks those arrays.  Rule and declaration parsing
# follows §5 with the 2023 nesting changes: inside a style rule, an
# identifier starts a declaration unless what follows is a {} block, in
# which case it is a nested rule.
#

include "sys.m";
	sys: Sys;
include "web/css.m";

init()
{
	sys = load Sys Sys->PATH;
}

# ---- tokenizer (§4) ----

Fint, Fplus: con 1<<iota;	# Tok.flag bits for numbers

Lx: adt {
	s:	string;
	i:	int;
};

preprocess(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\r' || s[i] == '\f' || s[i] == 0)
			break;
	if(i == len s)
		return s;
	r := s[0:i];
	for(; i < len s; i++)
		case s[i] {
		'\r' =>
			r[len r] = '\n';
			if(i+1 < len s && s[i+1] == '\n')
				i++;
		'\f' =>
			r[len r] = '\n';
		0 =>
			r[len r] = 16rFFFD;
		* =>
			r[len r] = s[i];
		}
	return r;
}

peek(l: ref Lx, k: int): int
{
	if(l.i+k < len l.s)
		return l.s[l.i+k];
	return -1;
}

isws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n';
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

ishex(c: int): int
{
	return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

isnamestart(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 16r80;
}

isname(c: int): int
{
	return isnamestart(c) || isdigit(c) || c == '-';
}

validescape(c0, c1: int): int
{
	return c0 == '\\' && c1 != '\n' && c1 != -1;
}

startsident(c0, c1, c2: int): int
{
	if(c0 == '-')
		return isnamestart(c1) || c1 == '-' || validescape(c1, c2);
	if(isnamestart(c0))
		return 1;
	return validescape(c0, c1);
}

startsnumber(c0, c1, c2: int): int
{
	if(c0 == '+' || c0 == '-') {
		if(isdigit(c1))
			return 1;
		return c1 == '.' && isdigit(c2);
	}
	if(c0 == '.')
		return isdigit(c1);
	return isdigit(c0);
}

# after the backslash
escape(l: ref Lx): int
{
	c := peek(l, 0);
	if(c == -1)
		return 16rFFFD;
	l.i++;
	if(!ishex(c))
		return c;
	v := hexdigit(c);
	for(n := 1; n < 6 && ishex(peek(l, 0)); n++)
		v = v*16 + hexdigit(l.s[l.i++]);
	if(isws(peek(l, 0)))
		l.i++;
	if(v == 0 || v > 16r10FFFF || (v >= 16rD800 && v <= 16rDFFF))
		v = 16rFFFD;
	return v;
}

hexdigit(c: int): int
{
	if(isdigit(c))
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

name(l: ref Lx): string
{
	r := "";
	for(;;) {
		c := peek(l, 0);
		if(isname(c)) {
			r[len r] = c;
			l.i++;
		} else if(validescape(c, peek(l, 1))) {
			l.i++;
			r[len r] = escape(l);
		} else
			return r;
	}
}

tok(kind: int, s: string): ref Tok
{
	return ref Tok(kind, s, 0.0, 0, nil);
}

# (value, flags): Fint if integer-valued, Fplus if written with a '+'
number(l: ref Lx): (real, int)
{
	st := l.i;
	isint := Fint;
	if(peek(l, 0) == '+')
		isint |= Fplus;
	if(peek(l, 0) == '+' || peek(l, 0) == '-')
		l.i++;
	while(isdigit(peek(l, 0)))
		l.i++;
	if(peek(l, 0) == '.' && isdigit(peek(l, 1))) {
		isint &= ~Fint;
		l.i += 2;
		while(isdigit(peek(l, 0)))
			l.i++;
	}
	c := peek(l, 0);
	if(c == 'e' || c == 'E') {
		c1 := peek(l, 1);
		if(isdigit(c1) || ((c1 == '+' || c1 == '-') && isdigit(peek(l, 2)))) {
			isint &= ~Fint;
			l.i += 2;
			while(isdigit(peek(l, 0)))
				l.i++;
		}
	}
	t := l.s[st:l.i];
	if(len t > 0 && t[0] == '+')
		t = t[1:];
	return (real t, isint);
}

numeric(l: ref Lx): ref Tok
{
	(n, isint) := number(l);
	if(startsident(peek(l, 0), peek(l, 1), peek(l, 2))) {
		t := tok(Kdimension, lower(name(l)));
		t.n = n;
		t.flag = isint;
		return t;
	}
	if(peek(l, 0) == '%') {
		l.i++;
		t := tok(Kpercent, nil);
		t.n = n;
		t.flag = isint;
		return t;
	}
	t := tok(Knumber, nil);
	t.n = n;
	t.flag = isint;
	return t;
}

identlike(l: ref Lx): ref Tok
{
	if((r := urange(l)) != nil)
		return r;
	s := name(l);
	if(peek(l, 0) == '(') {
		l.i++;
		if(lower(s) == "url") {
			while(isws(peek(l, 0)) && isws(peek(l, 1)))
				l.i++;
			c := peek(l, 0);
			if(isws(c))
				c = peek(l, 1);
			if(c != '"' && c != '\'')
				return url(l);
		}
		return tok(Kfunction, lower(s));
	}
	return tok(Kident, s);
}

# U+0000-00FF, u+4??: a unicode-range, as one identifier, as written.
# As numbers and dimensions its digits are lost ("+0131" is 131,
# "+1E00" is 1, "-00FF" is a dimension of unit "ff").  CSS Syntax now
# re-reads the tokens' text instead (§7.1); without that text, taken
# here, and only where it has a digit or "?", so that u+a, u+b (an
# adjacent-sibling selector) stay as they are.
urange(l: ref Lx): ref Tok
{
	c := peek(l, 0);
	if(c != 'u' && c != 'U' || peek(l, 1) != '+')
		return nil;
	i := l.i + 2;
	n := 0;
	digit := 0;
	while(i < len l.s && n < 6 && (ishex(l.s[i]) || l.s[i] == '?')) {
		if(isdigit(l.s[i]) || l.s[i] == '?')
			digit = 1;
		i++;
		n++;
	}
	if(n == 0)
		return nil;
	if(i + 1 < len l.s && l.s[i] == '-' && ishex(l.s[i+1])) {
		i++;
		m := 0;
		while(i < len l.s && m < 6 && ishex(l.s[i])) {
			if(isdigit(l.s[i]))
				digit = 1;
			i++;
			m++;
		}
	}
	if(!digit || i < len l.s && isname(l.s[i]))
		return nil;
	t := tok(Kident, l.s[l.i:i]);
	l.i = i;
	return t;
}

url(l: ref Lx): ref Tok
{
	while(isws(peek(l, 0)))
		l.i++;
	r := "";
	for(;;) {
		c := peek(l, 0);
		case c {
		')' or -1 =>
			l.i++;
			return tok(Kurl, r);
		'"' or '\'' or '(' =>
			return badurl(l);
		'\\' =>
			if(!validescape(c, peek(l, 1)))
				return badurl(l);
			l.i++;
			r[len r] = escape(l);
		* =>
			if(isws(c)) {
				while(isws(peek(l, 0)))
					l.i++;
				if(peek(l, 0) == ')' || peek(l, 0) == -1) {
					l.i++;
					return tok(Kurl, r);
				}
				return badurl(l);
			}
			r[len r] = c;
			l.i++;
		}
	}
}

badurl(l: ref Lx): ref Tok
{
	for(;;) {
		c := peek(l, 0);
		if(c == -1)
			break;
		l.i++;
		if(c == ')')
			break;
		if(validescape(c, peek(l, 0)))
			l.i++;
	}
	return tok(Kbadurl, nil);
}

str(l: ref Lx, q: int): ref Tok
{
	r := "";
	for(;;) {
		c := peek(l, 0);
		if(c == -1 || c == q) {
			l.i++;
			return tok(Kstring, r);
		}
		if(c == '\n')
			return tok(Kbadstring, r);
		l.i++;
		if(c == '\\') {
			n := peek(l, 0);
			if(n == -1)
				continue;
			if(n == '\n') {
				l.i++;
				continue;
			}
			r[len r] = escape(l);
		} else
			r[len r] = c;
	}
}

next(l: ref Lx): ref Tok
{
	# comments
	while(peek(l, 0) == '/' && peek(l, 1) == '*') {
		e := index(l.s, "*/", l.i+2);
		if(e < 0)
			l.i = len l.s;
		else
			l.i = e+2;
	}
	c := peek(l, 0);
	if(c == -1)
		return tok(Keof, nil);
	if(isws(c)) {
		while(isws(peek(l, 0)))
			l.i++;
		return tok(Kws, " ");
	}
	case c {
	'"' or '\'' =>
		l.i++;
		return str(l, c);
	'#' =>
		if(isname(peek(l, 1)) || validescape(peek(l, 1), peek(l, 2))) {
			l.i++;
			isid := startsident(peek(l, 0), peek(l, 1), peek(l, 2));
			t := tok(Khash, name(l));
			t.flag = isid;
			return t;
		}
	'(' =>
		l.i++;
		return tok(Klparen, "(");
	')' =>
		l.i++;
		return tok(Krparen, ")");
	'[' =>
		l.i++;
		return tok(Klbracket, "[");
	']' =>
		l.i++;
		return tok(Krbracket, "]");
	'{' =>
		l.i++;
		return tok(Klbrace, "{");
	'}' =>
		l.i++;
		return tok(Krbrace, "}");
	',' =>
		l.i++;
		return tok(Kcomma, ",");
	':' =>
		l.i++;
		return tok(Kcolon, ":");
	';' =>
		l.i++;
		return tok(Ksemicolon, ";");
	'+' or '.' =>
		if(startsnumber(c, peek(l, 1), peek(l, 2)))
			return numeric(l);
	'-' =>
		if(startsnumber(c, peek(l, 1), peek(l, 2)))
			return numeric(l);
		if(peek(l, 1) == '-' && peek(l, 2) == '>') {
			l.i += 3;
			return tok(Kcdc, nil);
		}
		if(startsident(c, peek(l, 1), peek(l, 2)))
			return identlike(l);
	'<' =>
		if(l.i+4 <= len l.s && l.s[l.i:l.i+4] == "<!--") {
			l.i += 4;
			return tok(Kcdo, nil);
		}
	'@' =>
		if(startsident(peek(l, 1), peek(l, 2), peek(l, 3))) {
			l.i++;
			return tok(Katkeyword, lower(name(l)));
		}
	'\\' =>
		if(validescape(c, peek(l, 1)))
			return identlike(l);
	* =>
		if(isdigit(c))
			return numeric(l);
		if(isnamestart(c))
			return identlike(l);
	}
	l.i++;
	r := "";
	r[0] = c;
	return tok(Kdelim, r);
}

# ---- component values (§5.4.7, §5.4.8) ----

tokenize(s: string): array of ref Tok
{
	l := ref Lx(preprocess(s), 0);
	(v, nil) := values(l, Keof);
	return v;
}

# Component values up to the closing token (or EOF).
values(l: ref Lx, close: int): (array of ref Tok, int)
{
	a := array[16] of ref Tok;
	n := 0;
	for(;;) {
		t := next(l);
		if(t.kind == Keof || t.kind == close)
			break;
		case t.kind {
		Kfunction =>
			(t.kids, nil) = values(l, Krparen);
		Klparen =>
			t = ref Tok(Kblock, "(", 0.0, 0, nil);
			(t.kids, nil) = values(l, Krparen);
		Klbracket =>
			t = ref Tok(Kblock, "[", 0.0, 0, nil);
			(t.kids, nil) = values(l, Krbracket);
		Klbrace =>
			t = ref Tok(Kblock, "{", 0.0, 0, nil);
			(t.kids, nil) = values(l, Krbrace);
		}
		if(n == len a) {
			b := array[2*n] of ref Tok;
			b[0:] = a;
			a = b;
		}
		a[n++] = t;
	}
	return (own(a[0:n]), n);
}

# v in an array of its own.  A slice keeps the whole array it was cut
# from: a rule that kept a slice of its sheet's tokens (an @media
# prelude, a declaration's value) kept every token of the sheet, 18M of
# a 700K sheet.
own(v: array of ref Tok): array of ref Tok
{
	if(len v == 0)
		return nil;
	a := array[len v] of ref Tok;
	a[0:] = v;
	return a;
}

trim(v: array of ref Tok): array of ref Tok
{
	i := 0;
	while(i < len v && v[i].kind == Kws)
		i++;
	e := len v;
	while(e > i && v[e-1].kind == Kws)
		e--;
	return v[i:e];
}

isblock(t: ref Tok, open: string): int
{
	return t.kind == Kblock && t.s == open;
}

# ---- rules (§5.4) ----

parse(s: string): ref Sheet
{
	if(sys == nil)
		init();
	return ref Sheet(rules(tokenize(s), 1));
}

rules(v: array of ref Tok, top: int): array of ref Rule
{
	r: list of ref Rule;
	for(i := 0; i < len v; ) {
		t := v[i];
		case t.kind {
		Kws =>
			i++;
			continue;
		# a stray ";" is not skipped: it starts the next rule's prelude
		# and so invalidates its selector (CSS Syntax 3 §5.4.1; Acid2)
		Kcdo or Kcdc =>
			if(top) {
				i++;
				continue;
			}
		Katkeyword =>
			ar: ref Rule;
			(ar, i) = atrule(v, i, nil);
			if(ar != nil)
				r = ar :: r;
			continue;
		}
		# qualified rule: prelude up to a {} block
		st := i;
		while(i < len v && !isblock(v[i], "{"))
			i++;
		if(i == len v)
			break;
		sels := parsesellist(trim(v[st:i]), nil);
		blk := v[i++].kids;
		if(sels == nil)
			continue;	# invalid selector: the whole rule is dropped
		for(l := blockrules(sels, blk); l != nil; l = tl l)
			r = hd l :: r;
	}
	return revrules(r);
}

revrules(r: list of ref Rule): array of ref Rule
{
	a := array[len r] of ref Rule;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd r;
		r = tl r;
	}
	return a;
}

# At v[i], an at-keyword.  parent is the enclosing style rule's selectors, if nested.
atrule(v: array of ref Tok, i: int, parent: array of ref Sel): (ref Rule, int)
{
	nm := v[i++].s;
	st := i;
	while(i < len v && v[i].kind != Ksemicolon && !isblock(v[i], "{"))
		i++;
	prelude := own(trim(v[st:i]));
	blk: array of ref Tok;
	hasblk := 0;
	if(i < len v) {
		if(isblock(v[i], "{")) {
			blk = v[i].kids;
			hasblk = 1;
		}
		i++;
	}
	inner := 0;
	case nm {
	"media" or "supports" or "container" or "layer" or "scope" or "starting-style" or "document" =>
		inner = 1;
	}
	sub: array of ref Rule;
	if(inner && hasblk) {
		if(parent != nil)
			sub = revrules(blockrules(parent, blk));
		else
			sub = rules(blk, 0);
	}
	case nm {
	"media" =>
		return (ref Rule.Media(prelude, sub), i);
	"supports" =>
		return (ref Rule.Supports(prelude, sub), i);
	"container" =>
		return (ref Rule.Container(prelude, sub), i);
	"layer" =>
		names := layernames(prelude);
		if(!hasblk)
			sub = nil;
		else if(names == nil)
			names = "" :: nil;	# anonymous layer
		return (ref Rule.Layer(names, sub), i);
	"scope" =>
		# @scope (<root>) [to (<limit>)] { rules }: the rules apply to
		# the root's descendants, as nested rules under :is(root) do;
		# the limit is not modelled.  Without a root, as a nested rule.
		if(len prelude > 0 && isblock(prelude[0], "(")) {
			roots := parsesellist(trim(prelude[0].kids), parent);
			if(roots == nil)
				return (nil, i);
			if(hasblk)
				sub = revrules(blockrules(roots, blk));
		}
		return (ref Rule.Media(nil, sub), i);
	"starting-style" or "document" =>
		# @starting-style is the state before a transition (none here);
		# @document is dead
		return (nil, i);
	"import" =>
		if(hasblk || len prelude == 0)
			return (nil, i);
		u := "";
		k := 0;
		case prelude[0].kind {
		Kstring or Kurl =>
			u = prelude[0].s;
		Kfunction =>
			if(prelude[0].s == "url" && len (uk := trim(prelude[0].kids)) > 0)
				u = uk[0].s;
		* =>
			return (nil, i);
		}
		k = 1;
		while(k < len prelude && prelude[k].kind == Kws)
			k++;
		layer: string;
		if(k < len prelude && prelude[k].kind == Kident && lower(prelude[k].s) == "layer") {
			layer = "";
			k++;
		} else if(k < len prelude && prelude[k].kind == Kfunction && prelude[k].s == "layer") {
			layer = tostring(prelude[k].kids);
			k++;
		}
		# supports() conditions on imports are ignored
		if(k < len prelude && prelude[k].kind == Kfunction && prelude[k].s == "supports")
			k++;
		return (ref Rule.Import(u, trim(prelude[k:]), layer), i);
	"font-face" =>
		if(!hasblk)
			return (nil, i);
		(d, nil) := declsandrules(blk, nil);
		return (ref Rule.Fontface(d), i);
	}
	return (ref Rule.Other(nm, prelude, blk), i);
}

layernames(v: array of ref Tok): list of string
{
	names: list of string;
	cur := "";
	for(k := 0; k < len v; k++) {
		t := v[k];
		case t.kind {
		Kident =>
			cur += t.s;
		Kdelim =>
			if(t.s == ".")
				cur += ".";
		Kcomma =>
			if(cur != "")
				names = cur :: names;
			cur = "";
		}
	}
	if(cur != "")
		names = cur :: names;
	r: list of string;
	for(; names != nil; names = tl names)
		r = hd names :: r;
	return r;
}

# The contents of a style rule's block, as rules in order: the rule's own
# declarations, then nested rules, with declarations that follow a nested
# rule becoming a rule of their own so the cascade sees them in order.
blockrules(sels: array of ref Sel, blk: array of ref Tok): list of ref Rule
{
	r: list of ref Rule;
	(decls, nested) := declsandrules(blk, sels);
	if(len decls > 0)
		r = ref Rule.Style(sels, decls) :: r;
	for(; nested != nil; nested = tl nested)
		r = hd nested :: r;
	# reverse into document order
	o: list of ref Rule;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# Declarations and nested rules of a block, both in document order.
# Without a parent (@font-face and the like) nested rules are skipped.
declsandrules(v: array of ref Tok, parent: array of ref Sel): (array of ref Decl, list of ref Rule)
{
	d := array[8] of ref Decl;
	nd := 0;
	nested: list of ref Rule;	# reverse order
	pend: list of ref Decl;		# declarations after a nested rule
	for(i := 0; i < len v; ) {
		t := v[i];
		case t.kind {
		Kws or Ksemicolon =>
			i++;
			continue;
		Katkeyword =>
			if(parent == nil) {	# e.g. @font-face: skip at-rules
				(nil, i) = atrule(v, i, nil);
				continue;
			}
			if(pend != nil) {
				nested = ref Rule.Style(parent, revdecls(pend)) :: nested;
				pend = nil;
			}
			ar: ref Rule;
			(ar, i) = atrule(v, i, parent);
			if(ar != nil)
				nested = ar :: nested;
			continue;
		}
		# a declaration?
		e := i;
		while(e < len v && v[e].kind != Ksemicolon)
			e++;
		decl := declaration(v[i:e]);
		if(decl != nil) {
			if(nested != nil)
				pend = decl :: pend;
			else {
				if(nd == len d) {
					a := array[2*nd] of ref Decl;
					a[0:] = d;
					d = a;
				}
				d[nd++] = decl;
			}
			i = e;
			continue;
		}
		# else a nested qualified rule, up to its {} block; a ';'
		# first means it was just an invalid declaration
		e = i;
		while(e < len v && !isblock(v[e], "{") && v[e].kind != Ksemicolon)
			e++;
		if(e == len v)
			break;
		if(v[e].kind == Ksemicolon) {
			i = e+1;
			continue;
		}
		if(parent != nil) {
			if(pend != nil) {
				nested = ref Rule.Style(parent, revdecls(pend)) :: nested;
				pend = nil;
			}
			sels := parsesellist(trim(v[i:e]), parent);
			if(sels != nil)
				for(l := blockrules(sels, v[e].kids); l != nil; l = tl l)
					nested = hd l :: nested;
		}
		i = e+1;
	}
	if(pend != nil)
		nested = ref Rule.Style(parent, revdecls(pend)) :: nested;
	r: list of ref Rule;
	for(; nested != nil; nested = tl nested)
		r = hd nested :: r;
	return (d[0:nd], r);
}

revdecls(l: list of ref Decl): array of ref Decl
{
	a := array[len l] of ref Decl;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# One declaration: ident ws* ':' value [! important].  nil if v is not one.
declaration(v: array of ref Tok): ref Decl
{
	v = trim(v);
	if(len v == 0 || v[0].kind != Kident)
		return nil;
	nm := v[0].s;
	i := 1;
	while(i < len v && v[i].kind == Kws)
		i++;
	if(i >= len v || v[i].kind != Kcolon)
		return nil;
	val := trim(v[i+1:]);
	custom := len nm > 2 && nm[0:2] == "--";
	if(!custom) {
		nm = lower(nm);
		for(k := 0; k < len val; k++)
			if(isblock(val[k], "{"))
				return nil;	# a nested rule, as in a:hover {...}
	}
	if(!validvars(val))
		return nil;
	imp := 0;
	n := len val;
	if(n >= 2 && val[n-1].kind == Kident && lower(val[n-1].s) == "important") {
		k := n-2;
		while(k >= 0 && val[k].kind == Kws)
			k--;
		if(k >= 0 && val[k].kind == Kdelim && val[k].s == "!") {
			imp = 1;
			val = trim(val[0:k]);
		}
	}
	return ref Decl(nm, own(val), imp);
}

# A var() whose arguments are malformed makes the declaration invalid
# at parse time (Variables 2 §2.3): it must have an argument, and
# nothing at the top level of its arguments may be a '!' or a ';'.
# The name is any <declaration-value>, judged only at computed-value
# time (variable-declaration-11, variable-reference-07,
# variable-supports-30)
validvars(v: array of ref Tok): int
{
	for(k := 0; k < len v; k++) {
		t := v[k];
		if(t.kind == Kfunction && t.s == "var") {
			a := trim(t.kids);
			if(len a == 0)
				return 0;
			for(j := 0; j < len a; j++)
				if(a[j].kind == Ksemicolon || a[j].kind == Kdelim && a[j].s == "!")
					return 0;
		}
		if(t.kids != nil && !validvars(t.kids))
			return 0;
	}
	return 1;
}

parsedecls(s: string): array of ref Decl
{
	if(sys == nil)
		init();
	(d, nil) := declsandrules(tokenize(s), nil);
	return d;
}

# ---- selectors (Selectors 4) ----

parsesels(s: string): array of ref Sel
{
	if(sys == nil)
		init();
	return parsesellist(trim(tokenize(s)), nil);
}

# A selector list; nil if any selector in it is invalid.  With a
# parent (a nested rule), '&' means :is(parent) and a selector without
# one is relative to it.
parsesellist(v: array of ref Tok, parent: array of ref Sel): array of ref Sel
{
	parts := splitcommas(v);
	a := array[len parts] of ref Sel;
	i := 0;
	for(; parts != nil; parts = tl parts) {
		s := complex(trim(hd parts), parent, parent != nil);
		if(s == nil)
			return nil;
		a[i++] = s;
	}
	if(i == 0)
		return nil;
	return a;
}

# Like parsesellist, but invalid selectors are dropped (:is, :where).
forgiving(v: array of ref Tok, relative: int): array of ref Sel
{
	r: list of ref Sel;
	for(parts := splitcommas(v); parts != nil; parts = tl parts)
		if((s := complex(trim(hd parts), nil, relative)) != nil)
			r = s :: r;
	a := array[len r] of ref Sel;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd r;
		r = tl r;
	}
	return a;
}

splitcommas(v: array of ref Tok): list of array of ref Tok
{
	r: list of array of ref Tok;
	st := 0;
	for(i := 0; i <= len v; i++)
		if(i == len v || v[i].kind == Kcomma) {
			r = v[st:i] :: r;
			st = i+1;
		}
	o: list of array of ref Tok;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

combinator(t: ref Tok): int
{
	if(t.kind == Kdelim)
		case t.s {
		">" or "+" or "~" =>
			return t.s[0];
		}
	return 0;
}

# A complex selector.  relative: may start with a combinator (nested
# rules, :has()).
complex(v: array of ref Tok, parent: array of ref Sel, relative: int): ref Sel
{
	if(len v == 0)
		return nil;
	cps: list of array of ref Simple;
	cbs: list of int;
	i := 0;
	lead := 0;
	if(relative) {
		lead = ' ';	# :has(.a .b) is :has(:scope .a .b)
		if((c := combinator(v[0])) != 0) {
			lead = c;
			i = 1;
		}
	}
	comb := lead;
	pseudo: string;
	hasnest := 0;
	for(;;) {
		while(i < len v && v[i].kind == Kws)
			i++;
		if(i >= len v)
			break;
		if(pseudo != nil)
			return nil;	# nothing may follow a pseudo-element
		cp: array of ref Simple;
		(cp, i, pseudo) = compound(v, i, parent);
		if(cp == nil && pseudo == nil)
			return nil;
		for(k := 0; k < len cp; k++)
			if(cp[k].kind == Spseudo && cp[k].name == "&")
				hasnest = 1;
		cps = cp :: cps;
		cbs = comb :: cbs;
		# combinator
		sawws := 0;
		while(i < len v && v[i].kind == Kws) {
			i++;
			sawws = 1;
		}
		if(i >= len v)
			break;
		if((cb := combinator(v[i])) != 0) {
			comb = cb;
			i++;
			while(i < len v && v[i].kind == Kws)
				i++;
			if(i >= len v)
				return nil;	# a combinator needs something after it
		} else if(sawws)
			comb = ' ';
		else
			return nil;
	}
	if(cps == nil)
		return nil;
	n := len cps;
	s := ref Sel(array[n] of array of ref Simple, array[n] of int, 0, pseudo);
	for(k := n-1; k >= 0; k--) {
		s.parts[k] = hd cps;
		s.combs[k] = hd cbs;
		cps = tl cps;
		cbs = tl cbs;
	}
	if(parent != nil) {
		# resolve '&'
		isp := ref Simple(Spseudo, "is", 0, nil, 0, 0, 0, parent);
		if(hasnest) {
			s.combs[0] = 0;	# '&' says where the parent goes; no implied descendant
			for(k = 0; k < n; k++)
				for(j := 0; j < len s.parts[k]; j++)
					if(s.parts[k][j].kind == Spseudo && s.parts[k][j].name == "&")
						s.parts[k][j] = isp;
		} else {
			# relative: "& <comb> sel"
			c := s.combs[0];
			if(c == 0)
				c = ' ';
			np := array[n+1] of array of ref Simple;
			nc := array[n+1] of int;
			np[0] = array[] of {isp};
			nc[0] = 0;
			np[1:] = s.parts;
			nc[1:] = s.combs;
			nc[1] = c;
			s.parts = np;
			s.combs = nc;
		}
	} else if(hasnest) {
		# '&' outside a nested rule is :scope, which is the root here
		for(k = 0; k < n; k++)
			for(j := 0; j < len s.parts[k]; j++)
				if(s.parts[k][j].kind == Spseudo && s.parts[k][j].name == "&")
					s.parts[k][j].name = "root";
	}
	s.spec = specificity(s);
	return s;
}

# A compound selector at v[i]: (simples, next index, pseudo-element).
compound(v: array of ref Tok, i: int, parent: array of ref Sel): (array of ref Simple, int, string)
{
	r: list of ref Simple;
	pseudo: string;
	first := 1;
	for(; i < len v; first = 0) {
		t := v[i];
		s: ref Simple;
		case t.kind {
		Kident =>
			if(!first)
				return (nil, i, nil);
			# a namespace prefix ("ns|tag") is accepted and ignored
			if(i+2 < len v && v[i+1].kind == Kdelim && v[i+1].s == "|") {
				i += 2;
				t = v[i];
			}
			s = ref Simple(Stype, lower(t.s), 0, nil, 0, 0, 0, nil);
			i++;
		Khash =>
			if(!t.flag)
				return (nil, i, nil);
			s = ref Simple(Sid, t.s, 0, nil, 0, 0, 0, nil);
			i++;
		Kblock =>
			if(t.s != "[")
				return (nil, i, nil);
			s = attrsel(trim(t.kids));
			if(s == nil)
				return (nil, i, nil);
			i++;
		Kcolon =>
			if(i+1 < len v && v[i+1].kind == Kcolon) {
				# pseudo-element
				i += 2;
				if(i >= len v)
					return (nil, i, nil);
				pt := v[i++];
				if(pt.kind != Kident && pt.kind != Kfunction)
					return (nil, i, nil);
				pseudo = lower(pt.s);
				continue;
			}
			i++;
			if(i >= len v)
				return (nil, i, nil);
			pt := v[i++];
			case pt.kind {
			Kident =>
				nm := lower(pt.s);
				case nm {
				"before" or "after" or "first-line" or "first-letter" =>
					pseudo = nm;	# legacy single-colon pseudo-elements
					continue;
				}
				if(!knownpseudo(nm))
					return (nil, i, nil);	# an unknown pseudo-class invalidates the rule
				s = ref Simple(Spseudo, nm, 0, nil, 0, 0, 0, nil);
			Kfunction =>
				s = pseudofn(pt, parent);
				if(s == nil)
					return (nil, i, nil);
			* =>
				return (nil, i, nil);
			}
		Kdelim =>
			case t.s {
			"*" =>
				if(!first)
					return (nil, i, nil);
				if(i+2 < len v && v[i+1].kind == Kdelim && v[i+1].s == "|")
					i += 2;
				s = ref Simple(Suniversal, nil, 0, nil, 0, 0, 0, nil);
				i++;
			"." =>
				if(i+1 >= len v || v[i+1].kind != Kident)
					return (nil, i, nil);
				s = ref Simple(Sclass, v[i+1].s, 0, nil, 0, 0, 0, nil);
				i += 2;
			"&" =>
				s = ref Simple(Spseudo, "&", 0, nil, 0, 0, 0, nil);
				i++;
			"|" =>
				i++;	# "|tag": no namespace
				continue;
			* =>
				return (rev(r), i, pseudo);
			}
		* =>
			return (rev(r), i, pseudo);
		}
		if(pseudo != nil && s.kind != Spseudo)
			return (nil, i, nil);
		r = s :: r;
	}
	return (rev(r), i, pseudo);
}

pseudoclasses := array[] of {
	"active", "any-link", "autofill", "blank", "checked", "closed", "current",
	"default", "defined", "disabled", "empty", "enabled", "first-child",
	"first-of-type", "focus", "focus-visible", "focus-within", "fullscreen",
	"future", "host", "hover", "in-range", "indeterminate", "invalid",
	"last-child", "last-of-type", "link", "local-link", "modal", "muted",
	"only-child", "only-of-type", "open", "optional", "out-of-range", "past",
	"paused", "picture-in-picture", "placeholder-shown", "playing",
	"popover-open", "read-only", "read-write", "required", "root", "scope",
	"target", "target-within", "user-invalid", "user-valid", "valid", "visited",
};

knownpseudo(nm: string): int
{
	lo := 0;
	hi := len pseudoclasses;
	while(lo < hi) {
		m := (lo+hi)/2;
		if(pseudoclasses[m] == nm)
			return 1;
		if(pseudoclasses[m] < nm)
			lo = m+1;
		else
			hi = m;
	}
	return 0;
}

rev(l: list of ref Simple): array of ref Simple
{
	if(l == nil)
		return nil;
	a := array[len l] of ref Simple;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

attrsel(v: array of ref Tok): ref Simple
{
	if(len v == 0)
		return nil;
	i := 0;
	if(len v > 2 && v[1].kind == Kdelim && v[1].s == "|" && (v[0].kind == Kident || v[0].kind == Kdelim) &&
	   !(v[2].kind == Kdelim && v[2].s == "="))
		i = 2;	# namespace prefix ignored
	else if(v[0].kind == Kdelim && v[0].s == "|")
		i = 1;
	if(v[i].kind != Kident)
		return nil;
	s := ref Simple(Sattr, lower(v[i].s), Aexists, nil, 0, 0, 0, nil);
	i++;
	while(i < len v && v[i].kind == Kws)
		i++;
	if(i >= len v)
		return s;
	if(v[i].kind != Kdelim)
		return nil;
	case v[i].s {
	"=" =>
		s.op = Aequals;
		i++;
	"~" or "|" or "^" or "$" or "*" =>
		if(i+1 >= len v || v[i+1].kind != Kdelim || v[i+1].s != "=")
			return nil;
		case v[i].s {
		"~" => s.op = Aword;
		"|" => s.op = Adash;
		"^" => s.op = Aprefix;
		"$" => s.op = Asuffix;
		"*" => s.op = Asubstr;
		}
		i += 2;
	* =>
		return nil;
	}
	while(i < len v && v[i].kind == Kws)
		i++;
	if(i >= len v || (v[i].kind != Kident && v[i].kind != Kstring))
		return nil;
	s.val = v[i++].s;
	while(i < len v && v[i].kind == Kws)
		i++;
	if(i < len v && v[i].kind == Kident) {
		case lower(v[i].s) {
		"i" => s.icase = 1;
		"s" => ;
		* => return nil;
		}
		i++;
	}
	while(i < len v && v[i].kind == Kws)
		i++;
	if(i != len v)
		return nil;
	return s;
}

pseudofn(t: ref Tok, parent: array of ref Sel): ref Simple
{
	nm := t.s;
	args := trim(t.kids);
	s := ref Simple(Spseudo, nm, 0, tostring(args), 0, 0, 0, nil);
	case nm {
	"is" or "matches" or "-webkit-any" or "where" =>
		s.name = nm;
		if(nm != "where")
			s.name = "is";
		s.sub = forgivingp(args, parent);
	"not" =>
		s.sub = parsesellistp(args, parent);
		if(s.sub == nil)
			return nil;
	"has" =>
		s.sub = forgiving(args, 1);
		if(len s.sub == 0)
			return nil;
	"nth-child" or "nth-last-child" or "nth-of-type" or "nth-last-of-type" =>
		# an+b [of S]
		k := 0;
		while(k < len args && !(args[k].kind == Kident && lower(args[k].s) == "of"))
			k++;
		ok: int;
		(ok, s.a, s.b) = anb(nows(tostring(args[0:k])));
		if(!ok)
			return nil;
		if(k < len args) {
			if(nm != "nth-child" && nm != "nth-last-child")
				return nil;
			s.sub = parsesellist(trim(args[k+1:]), nil);
			if(s.sub == nil)
				return nil;
		}
	"lang" or "dir" or "host" or "host-context" or "state" =>
		if(len args == 0)
			return nil;	# nothing to match: invalid (lang-selector-002)
	* =>
		return nil;
	}
	return s;
}

# Inside a nested rule, a '&' in :is()/:not() still refers to the parent.
forgivingp(v: array of ref Tok, parent: array of ref Sel): array of ref Sel
{
	if(parent == nil || !hasamp(v))
		return forgiving(v, 0);
	r: list of ref Sel;
	for(parts := splitcommas(v); parts != nil; parts = tl parts)
		if((s := complex(trim(hd parts), parent, 0)) != nil)
			r = s :: r;
	a := array[len r] of ref Sel;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd r;
		r = tl r;
	}
	return a;
}

parsesellistp(v: array of ref Tok, parent: array of ref Sel): array of ref Sel
{
	if(parent == nil || !hasamp(v))
		return parsesellist(v, nil);
	return parsesellist(v, parent);
}

hasamp(v: array of ref Tok): int
{
	for(i := 0; i < len v; i++)
		if(v[i].kind == Kdelim && v[i].s == "&")
			return 1;
	return 0;
}

nows(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(!isws(s[i]))
			r[len r] = s[i];
	return lower(r);
}

# An+B microsyntax, from its text with whitespace removed.
anb(s: string): (int, int, int)
{
	case s {
	"odd" =>
		return (1, 2, 1);
	"even" =>
		return (1, 2, 0);
	"" =>
		return (0, 0, 0);
	}
	for(i := 0; i < len s; i++)
		if(s[i] == 'n')
			break;
	if(i == len s) {
		(ok, b) := atoi(s);
		return (ok, 0, b);
	}
	a := 1;
	case s[0:i] {
	"" or "+" =>
		a = 1;
	"-" =>
		a = -1;
	* =>
		ok: int;
		(ok, a) = atoi(s[0:i]);
		if(!ok)
			return (0, 0, 0);
	}
	rest := s[i+1:];
	if(rest == "")
		return (1, a, 0);
	if(rest[0] != '+' && rest[0] != '-')
		return (0, 0, 0);
	(ok, b) := atoi(rest);
	return (ok, a, b);
}

atoi(s: string): (int, int)
{
	if(s == "")
		return (0, 0);
	neg := 0;
	i := 0;
	if(s[0] == '+' || s[0] == '-') {
		neg = s[0] == '-';
		i = 1;
	}
	if(i == len s)
		return (0, 0);
	v := 0;
	for(; i < len s; i++) {
		if(!isdigit(s[i]))
			return (0, 0);
		v = v*10 + s[i] - '0';
	}
	if(neg)
		v = -v;
	return (1, v);
}

Cmax: con 1023;

specificity(s: ref Sel): int
{
	a := 0;
	b := 0;
	c := 0;
	for(k := 0; k < len s.parts; k++)
		for(j := 0; j < len s.parts[k]; j++) {
			x := s.parts[k][j];
			case x.kind {
			Sid =>
				a++;
			Sclass or Sattr =>
				b++;
			Stype =>
				c++;
			Spseudo =>
				case x.name {
				"where" =>
					;
				"is" or "not" or "has" =>
					m := maxspec(x.sub);
					a += m >> 20;
					b += (m >> 10) & Cmax;
					c += m & Cmax;
				"nth-child" or "nth-last-child" =>
					b++;
					m := maxspec(x.sub);
					a += m >> 20;
					b += (m >> 10) & Cmax;
					c += m & Cmax;
				* =>
					b++;
				}
			}
		}
	if(s.pseudo != nil)
		c++;
	if(a > Cmax) a = Cmax;
	if(b > Cmax) b = Cmax;
	if(c > Cmax) c = Cmax;
	return (a << 20) | (b << 10) | c;
}

maxspec(l: array of ref Sel): int
{
	m := 0;
	for(i := 0; i < len l; i++)
		if(l[i].spec > m)
			m = l[i].spec;
	return m;
}

# ---- serialization (for debugging and for style files) ----

tostring(v: array of ref Tok): string
{
	r := "";
	for(i := 0; i < len v; i++) {
		t := v[i];
		case t.kind {
		Kident or Kdelim =>
			r += t.s;
		Kfunction =>
			r += t.s + "(" + tostring(t.kids) + ")";
		Katkeyword =>
			r += "@" + t.s;
		Khash =>
			r += "#" + t.s;
		Kstring or Kbadstring =>
			r += "\"" + t.s + "\"";
		Kurl =>
			r += "url(" + t.s + ")";
		Knumber =>
			r += signstr(t) + numstr(t.n);
		Kpercent =>
			r += signstr(t) + numstr(t.n) + "%";
		Kdimension =>
			r += signstr(t) + numstr(t.n) + t.s;
		Kws =>
			r += " ";
		Kcolon =>
			r += ":";
		Ksemicolon =>
			r += ";";
		Kcomma =>
			r += ",";
		Kblock =>
			cl := ")";
			case t.s {
			"[" => cl = "]";
			"{" => cl = "}";
			}
			r += t.s + tostring(t.kids) + cl;
		Kcdo =>
			r += "<!--";
		Kcdc =>
			r += "-->";
		}
	}
	return r;
}

signstr(t: ref Tok): string
{
	if(t.flag & Fplus)
		return "+";
	return "";
}

numstr(n: real): string
{
	if(n == real int n)
		return string int n;
	return sys->sprint("%g", n);
}

attrops := array[] of {"", "=", "~=", "|=", "^=", "$=", "*="};

seltostring(s: ref Sel): string
{
	r := "";
	for(k := 0; k < len s.parts; k++) {
		c := s.combs[k];
		if(c == ' ')
			r += " ";
		else if(c != 0) {
			if(k > 0)
				r += " ";
			r[len r] = c;
			r += " ";
		}
		for(j := 0; j < len s.parts[k]; j++) {
			x := s.parts[k][j];
			case x.kind {
			Stype => r += x.name;
			Suniversal => r += "*";
			Sid => r += "#" + x.name;
			Sclass => r += "." + x.name;
			Sattr =>
				r += "[" + x.name;
				if(x.op != Aexists)
					r += attrops[x.op] + "\"" + x.val + "\"";
				if(x.icase)
					r += " i";
				r += "]";
			Spseudo =>
				r += ":" + x.name;
				if(x.sub != nil && !prefix(x.name, "nth-")) {
					r += "(";
					for(m := 0; m < len x.sub; m++) {
						if(m > 0)
							r += ", ";
						r += seltostring(x.sub[m]);
					}
					r += ")";
				} else if(x.val != nil)
					r += "(" + x.val + ")";
			}
		}
	}
	if(s.pseudo != nil)
		r += "::" + s.pseudo;
	return r;
}

# ---- small things ----

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			break;
	if(i == len s)
		return s;
	r := s;
	for(; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

index(s, t: string, from: int): int
{
	n := len t;
	for(i := from; i+n <= len s; i++)
		if(s[i] == t[0] && s[i:i+n] == t)
			return i;
	return -1;
}
