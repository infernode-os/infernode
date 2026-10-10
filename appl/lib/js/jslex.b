implement Jslex;

#
# JavaScript's lexical grammar (ECMAScript 2025 §12): white space and
# line terminators, comments (with Annex B's HTML-like ones in scripts),
# identifiers and their escapes, punctuators, numeric literals (decimal,
# hex, octal, binary, legacy octal, separators, BigInt), strings and
# their escapes, templates, regular expression literals.
#
# A lexical error sets l.err (the first one wins) and returns Teof.
#

include "sys.m";
	sys: Sys;

include "jslex.m";

init()
{
	sys = load Sys Sys->PATH;
}

Lex.new(src: string, ismod: int): ref Lex
{
	if(sys == nil)
		init();
	l := ref Lex(src, 0, ismod, nil, 0);
	# a hashbang comment, first thing in the source
	if(len src >= 2 && src[0] == '#' && src[1] == '!')
		while(l.pos < len src && !islt(src[l.pos]))
			l.pos++;
	return l;
}

error(l: ref Lex, at: int, msg: string): ref Tok
{
	if(l.err == nil) {
		l.err = msg;
		l.errpos = at;
	}
	l.pos = len l.src;
	return ref Tok(Teof, at, at, nil, 0.0, nil, 0, 0, 0, 0, 0, nil);
}

islt(c: int): int
{
	return c == '\n' || c == '\r' || c == 16r2028 || c == 16r2029;
}

isws(c: int): int
{
	case c {
	'\t' or 16r0B or 16r0C or ' ' or 16rA0 or 16rFEFF or 16r1680 or 16r202F or 16r205F or 16r3000 =>
		return 1;
	}
	return c >= 16r2000 && c <= 16r200A;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# ID_Start and ID_Continue: ASCII exactly; beyond it, any letter-like
# character that is not white space, a line terminator or a known
# punctuation range.  (Full Unicode tables to come.)
isidstart(c: int): int
{
	if(c < 128)
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '$' || c == '_';
	return inranges(idstart, c);
}

isidpart(c: int): int
{
	if(c < 128)
		return isidstart(c) || isdigit(c);
	return inranges(idcont, c);
}

# whether c is in a table of first, last pairs, sorted
inranges(t: array of int, c: int): int
{
	lo := 0;
	hi := len t / 2;
	while(lo < hi) {
		m := (lo + hi) / 2;
		if(c < t[2*m])
			hi = m;
		else if(c > t[2*m+1])
			lo = m + 1;
		else
			return 1;
	}
	return 0;
}

reserved(s: string): int
{
	case s {
	"await" or "break" or "case" or "catch" or "class" or "const" or "continue" or
	"debugger" or "default" or "delete" or "do" or "else" or "enum" or "export" or
	"extends" or "false" or "finally" or "for" or "function" or "if" or "import" or
	"in" or "instanceof" or "new" or "null" or "return" or "super" or "switch" or
	"this" or "throw" or "true" or "try" or "typeof" or "var" or "void" or "while" or
	"with" or "yield" =>
		return 1;
	}
	return 0;
}

# white space and comments; whether a line terminator was among them
skip(l: ref Lex): int
{
	s := l.src;
	n := len s;
	nl := 0;
	# --> begins a comment where only white space and comments precede it on its line
	startline := l.pos == 0 || atlinestart(l);
	while(l.pos < n) {
		c := s[l.pos];
		if(isws(c)) {
			l.pos++;
			continue;
		}
		if(islt(c)) {
			l.pos++;
			nl = 1;
			continue;
		}
		if(c == '/' && l.pos + 1 < n) {
			d := s[l.pos+1];
			if(d == '/') {
				while(l.pos < n && !islt(s[l.pos]))
					l.pos++;
				continue;
			}
			if(d == '*') {
				st := l.pos;
				l.pos += 2;
				for(;;) {
					if(l.pos + 1 >= n) {
						error(l, st, "unterminated comment");
						return nl;
					}
					if(s[l.pos] == '*' && s[l.pos+1] == '/') {
						l.pos += 2;
						break;
					}
					if(islt(s[l.pos]))
						nl = 1;
					l.pos++;
				}
				continue;
			}
		}
		if(!l.ismod) {
			# Annex B: <!-- anywhere, --> at the start of a line, run to its end
			if(c == '<' && l.pos + 3 < n && s[l.pos+1] == '!' && s[l.pos+2] == '-' && s[l.pos+3] == '-') {
				while(l.pos < n && !islt(s[l.pos]))
					l.pos++;
				continue;
			}
			if(c == '-' && (nl || startline) && l.pos + 2 < n && s[l.pos+1] == '-' && s[l.pos+2] == '>') {
				while(l.pos < n && !islt(s[l.pos]))
					l.pos++;
				continue;
			}
		}
		break;
	}
	return nl;
}

# whether only white space and comments lie between the last line terminator and l.pos
atlinestart(l: ref Lex): int
{
	s := l.src;
	for(i := l.pos - 1; i >= 0; i--) {
		c := s[i];
		if(islt(c))
			return 1;
		if(!isws(c))
			return 0;
	}
	return 1;
}

punct3 := array[] of {">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??="};
punct2 := array[] of {"=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "**"};

Lex.next(l: self ref Lex, regexok: int): ref Tok
{
	nl := skip(l);
	if(l.err != nil)
		return error(l, l.errpos, l.err);
	s := l.src;
	n := len s;
	st := l.pos;
	if(st >= n) {
		t := ref Tok(Teof, st, st, nil, 0.0, nil, nl, 0, 0, 0, 0, nil);
		return t;
	}
	c := s[st];
	t: ref Tok;
	if(isidstart(cpat(s, st).t0) || c == '\\')
		t = ident(l, Tident);
	else if(c == '#')
		t = private(l);
	else if(isdigit(c) || c == '.' && st + 1 < n && isdigit(s[st+1]))
		t = number(l);
	else if(c == '"' || c == '\'')
		t = str(l, c);
	else if(c == '`') {
		l.pos++;
		t = templ(l, st);
	} else if(c == '/' && regexok)
		t = regex(l);
	else
		t = punct(l);
	t.nlb = nl;
	return t;
}

Lex.template(l: self ref Lex, at: int): ref Tok
{
	l.pos = at + 1;	# past the }
	return templ(l, at);
}

punct(l: ref Lex): ref Tok
{
	s := l.src;
	st := l.pos;
	n := len s;
	if(st + 4 <= n && s[st:st+4] == ">>>=") {
		l.pos += 4;
		return ptok(st, l.pos, ">>>=");
	}
	if(st + 3 <= n) {
		p := s[st:st+3];
		for(i := 0; i < len punct3; i++)
			if(p == punct3[i]) {
				l.pos += 3;
				return ptok(st, l.pos, p);
			}
	}
	if(st + 2 <= n) {
		p := s[st:st+2];
		for(i := 0; i < len punct2; i++)
			if(p == punct2[i]) {
				if(p == "?." && st + 2 < n && isdigit(s[st+2]))
					break;	# a ? then a number: c?.5:d
				l.pos += 2;
				return ptok(st, l.pos, p);
			}
	}
	c := s[st];
	case c {
	'{' or '}' or '(' or ')' or '[' or ']' or ';' or ',' or '<' or '>' or '+' or '-' or
	'*' or '/' or '%' or '&' or '|' or '^' or '!' or '~' or '?' or ':' or '=' or '.' or '@' =>
		l.pos++;
		return ptok(st, l.pos, s[st:st+1]);
	}
	return error(l, st, sys->sprint("unexpected character U+%04X", c));
}

ptok(st, end: int, p: string): ref Tok
{
	return ref Tok(Tpunct, st, end, p, 0.0, nil, 0, 0, 0, 0, 0, nil);
}

# an identifier name from l.pos; \u escapes decoded (and noted)
identname(l: ref Lex): (string, int, int)
{
	s := l.src;
	n := len s;
	name := "";
	esc := 0;
	first := 1;
	while(l.pos < n) {
		c := s[l.pos];
		if(c == '\\') {
			at := l.pos;
			if(l.pos + 1 >= n || s[l.pos+1] != 'u') {
				error(l, at, "bad escape in identifier");
				return (nil, 0, 0);
			}
			l.pos += 2;
			c = uescape(l);
			if(c < 0)
				return (nil, 0, 0);
			if(first && !isidstart(c) || !first && !isidpart(c)) {
				error(l, at, "escape is not an identifier character");
				return (nil, 0, 0);
			}
			esc = 1;
		} else {
			w: int;
			(c, w) = cpat(s, l.pos);
			if(first && isidstart(c) || !first && isidpart(c))
				l.pos += w;
			else
				break;
		}
		name = putcp(name, c);
		first = 0;
	}
	return (name, esc, 1);
}

ident(l: ref Lex, kind: int): ref Tok
{
	st := l.pos;
	(name, esc, ok) := identname(l);
	if(!ok)
		return error(l, l.errpos, l.err);
	return ref Tok(kind, st, l.pos, name, 0.0, nil, 0, esc, 0, 0, 0, nil);
}

private(l: ref Lex): ref Tok
{
	st := l.pos;
	l.pos++;
	if(l.pos >= len l.src || !(isidstart(cpat(l.src, l.pos).t0) || l.src[l.pos] == '\\'))
		return error(l, st, "# without a name");
	t := ident(l, Tprivate);
	t.pos = st;
	return t;
}

# the code point at s[i], and how many code units it takes: JavaScript
# source is UTF-16, so beyond U+FFFF a character is a surrogate pair
cpat(s: string, i: int): (int, int)
{
	c := s[i];
	if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
		return (16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00), 2);
	return (c, 1);
}

# s with code point c appended, as UTF-16
putcp(s: string, c: int): string
{
	if(c > 16rFFFF) {
		c -= 16r10000;
		s[len s] = 16rD800 + (c >> 10);
		s[len s] = 16rDC00 + (c & 16r3FF);
	} else
		s[len s] = c;
	return s;
}

# UTF-8 to UTF-16; what is not well-formed becomes U+FFFD
utf16(b: array of byte): string
{
	s := "";
	n := len b;
	for(i := 0; i < n; ) {
		c := int b[i];
		need := 0;
		min := 0;
		if(c < 16r80) {
			s[len s] = c;
			i++;
			continue;
		} else if(c >= 16rC2 && c <= 16rDF) {
			need = 1;
			c &= 16r1F;
			min = 16r80;
		} else if(c >= 16rE0 && c <= 16rEF) {
			need = 2;
			c &= 16r0F;
			min = 16r800;
		} else if(c >= 16rF0 && c <= 16rF4) {
			need = 3;
			c &= 16r07;
			min = 16r10000;
		} else {
			s[len s] = 16rFFFD;
			i++;
			continue;
		}
		j := i + 1;
		for(k := 0; k < need; k++) {
			if(j >= n || (int b[j] & 16rC0) != 16r80)
				break;
			c = (c << 6) | (int b[j] & 16r3F);
			j++;
		}
		if(k < need || c < min || c > 16r10FFFF || c >= 16rD800 && c <= 16rDFFF) {
			s[len s] = 16rFFFD;
			i = j;
			continue;
		}
		s = putcp(s, c);
		i = j;
	}
	return s;
}

# after \u: XXXX or {X...}; the code point, or -1
uescape(l: ref Lex): int
{
	s := l.src;
	n := len s;
	at := l.pos;
	if(l.pos < n && s[l.pos] == '{') {
		l.pos++;
		v := 0;
		nd := 0;
		while(l.pos < n && (h := hexval(s[l.pos])) >= 0) {
			v = v * 16 + h;
			if(v > 16r10FFFF) {
				error(l, at, "code point beyond U+10FFFF");
				return -1;
			}
			l.pos++;
			nd++;
		}
		if(nd == 0 || l.pos >= n || s[l.pos] != '}') {
			error(l, at, "bad \\u{...} escape");
			return -1;
		}
		l.pos++;
		return v;
	}
	v := 0;
	for(i := 0; i < 4; i++) {
		if(l.pos >= n || (h := hexval(s[l.pos])) < 0) {
			error(l, at, "bad \\u escape");
			return -1;
		}
		v = v * 16 + h;
		l.pos++;
	}
	return v;
}

# digits in base, with _ separators between digits; (value, count, ok)
digits(l: ref Lex, base: int, sep: int): (real, int, int)
{
	s := l.src;
	n := len s;
	v := 0.0;
	nd := 0;
	last := 0;	# the last character was a digit
	while(l.pos < n) {
		c := s[l.pos];
		if(c == '_' && sep) {
			if(!last || l.pos + 1 >= n || hexval(s[l.pos+1]) < 0 || hexval(s[l.pos+1]) >= base) {
				error(l, l.pos, "misplaced numeric separator");
				return (0.0, 0, 0);
			}
			l.pos++;
			last = 0;
			continue;
		}
		d := hexval(c);
		if(d < 0 || d >= base)
			break;
		v = v * real base + real d;
		nd++;
		last = 1;
		l.pos++;
	}
	return (v, nd, 1);
}

number(l: ref Lex): ref Tok
{
	s := l.src;
	n := len s;
	st := l.pos;
	octal := 0;
	v := 0.0;
	if(s[st] == '0' && st + 1 < n && s[st+1] == '_')
		return error(l, st + 1, "separator after a leading zero");
	if(s[st] == '0' && st + 1 < n && (s[st+1] == 'x' || s[st+1] == 'X' || s[st+1] == 'o' || s[st+1] == 'O' || s[st+1] == 'b' || s[st+1] == 'B')) {
		base := 16;
		case s[st+1] {
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		l.pos += 2;
		(x, nd, ok) := digits(l, base, 1);
		if(!ok)
			return error(l, l.errpos, l.err);
		if(nd == 0)
			return error(l, st, "no digits");
		v = x;
		if(l.pos < n && s[l.pos] == 'n') {
			l.pos++;
			return endnum(l, ref Tok(Tbigint, st, l.pos, bigdigits(s[st:l.pos-1]), 0.0, nil, 0, 0, 0, 0, 0, nil));
		}
		return endnum(l, ref Tok(Tnum, st, l.pos, nil, v, nil, 0, 0, 0, 0, 0, nil));
	}
	if(s[st] == '0' && st + 1 < n && isdigit(s[st+1])) {
		# legacy: 017 is octal, 08 and 019 decimal; neither in strict code
		octal = 1;
		allocal := 1;
		e := st + 1;
		while(e < n && isdigit(s[e])) {
			if(s[e] >= '8')
				allocal = 0;
			e++;
		}
		if(e < n && s[e] == '_')
			return error(l, e, "separator in a legacy octal literal");
		if(allocal) {
			for(i := st + 1; i < e; i++)
				v = v * 8.0 + real (s[i] - '0');
			l.pos = e;
			if(l.pos < n && s[l.pos] == 'n')
				return error(l, st, "BigInt literal with a leading zero");
			return endnum(l, ref Tok(Tnum, st, l.pos, nil, v, nil, 0, 0, 1, 0, 0, nil));
		}
		# a leading-zero decimal: may have a fraction and exponent
	}
	intpart := 1;
	if(s[st] != '.') {
		(nil, nil, ok) := digits(l, 10, !octal);
		if(!ok)
			return error(l, l.errpos, l.err);
	} else
		intpart = 0;
	isint := 1;
	if(l.pos < n && s[l.pos] == 'n' && intpart) {
		if(octal)
			return error(l, st, "BigInt literal with a leading zero");
		l.pos++;
		return endnum(l, ref Tok(Tbigint, st, l.pos, bigdigits(s[st:l.pos-1]), 0.0, nil, 0, 0, 0, 0, 0, nil));
	}
	if(l.pos < n && s[l.pos] == '.') {
		isint = 0;
		l.pos++;
		if(l.pos < n && s[l.pos] == '_')
			return error(l, l.pos, "misplaced numeric separator");
		(nil, nil, ok) := digits(l, 10, 1);
		if(!ok)
			return error(l, l.errpos, l.err);
	}
	if(l.pos < n && (s[l.pos] == 'e' || s[l.pos] == 'E')) {
		isint = 0;
		l.pos++;
		if(l.pos < n && (s[l.pos] == '+' || s[l.pos] == '-'))
			l.pos++;
		if(l.pos < n && s[l.pos] == '_')
			return error(l, l.pos, "misplaced numeric separator");
		(nil, nd, ok) := digits(l, 10, 1);
		if(!ok)
			return error(l, l.errpos, l.err);
		if(nd == 0)
			return error(l, st, "exponent without digits");
	}
	if(l.pos < n && s[l.pos] == 'n')
		return error(l, st, "BigInt literal must be an integer");
	text := "";
	for(i := st; i < l.pos; i++)
		if(s[i] != '_')
			text[len text] = s[i];
	v = decimal(text);
	isint = 0;
	return endnum(l, ref Tok(Tnum, st, l.pos, nil, v, nil, 0, 0, octal, 0, 0, nil));
}

# a decimal literal's value.  The emulator's strtod (libmath/dtoa.c)
# does not return for values that are subnormal, so those are scaled
# into the normal range first, at the cost of a second rounding.
# TODO: correctly rounded conversion of our own (ToNumber needs it too).
decimal(text: string): real
{
	(m, e) := sci(text);
	if(m == nil)
		return 0.0;
	if(e > 309)
		return 1e308 * 10.0;
	if(e < -326)
		return 0.0;
	if(e < -300)
		return real (m + "e" + string (e + 300 - len m + 1)) * 1e-300;
	return real text;
}

# the significant digits of a decimal and the exponent of the first: 0.0012 is ("12", -3)
sci(text: string): (string, int)
{
	m := "";
	e := 0;
	seen := 0;		# a nonzero digit
	point := 0;
	i := 0;
	for(; i < len text; i++) {
		c := text[i];
		if(c == '.') {
			point = 1;
			continue;
		}
		if(c < '0' || c > '9')
			break;
		if(!seen && c == '0') {
			if(point)
				e--;
			continue;
		}
		if(!seen) {
			seen = 1;
			if(point)
				e--;
		} else if(!point)
			e++;
		m[len m] = c;
	}
	if(i < len text && (text[i] == 'e' || text[i] == 'E'))
		e += int text[i+1:];
	return (m, e);
}

bigdigits(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] != '_')
			r[len r] = s[i];
	return r;
}

# a numeric literal may not run straight into an identifier or digit (3in, 0x1g)
endnum(l: ref Lex, t: ref Tok): ref Tok
{
	if(l.pos < len l.src) {
		c := l.src[l.pos];
		if(isidstart(cpat(l.src, l.pos).t0) || isdigit(c) || c == '\\')
			return error(l, t.pos, "identifier starts immediately after a number");
	}
	return t;
}

# an escape after \ in a string or template; (char or -1 for none,
# legacy: an octal or \8 \9 escape, ok)
escape(l: ref Lex, intemplate: int): (int, int, int)
{
	s := l.src;
	n := len s;
	at := l.pos - 1;
	if(l.pos >= n)
		return (-1, 0, 0);
	c := s[l.pos++];
	case c {
	'n' => return ('\n', 0, 1);
	't' => return ('\t', 0, 1);
	'r' => return ('\r', 0, 1);
	'b' => return ('\b', 0, 1);
	'f' => return (16r0C, 0, 1);
	'v' => return (16r0B, 0, 1);
	'\r' =>
		if(l.pos < n && s[l.pos] == '\n')
			l.pos++;
		return (-1, 0, 1);	# a line continuation
	'\n' or 16r2028 or 16r2029 =>
		return (-1, 0, 1);
	'x' =>
		if(l.pos + 2 > n || hexval(s[l.pos]) < 0 || hexval(s[l.pos+1]) < 0) {
			l.errpos = at;
			return (-1, 0, 0);
		}
		v := hexval(s[l.pos]) * 16 + hexval(s[l.pos+1]);
		l.pos += 2;
		return (v, 0, 1);
	'u' =>
		if(intemplate) {
			# an invalid escape in a template is not a lexical error: the
			# parser decides (tagged templates allow it)
			save := l.err;
			saveat := l.errpos;
			v := uescape(l);
			if(v < 0) {
				l.err = save;
				l.errpos = saveat;
				return (-1, 0, 0);
			}
			return (v, 0, 1);
		}
		v := uescape(l);
		if(v < 0)
			return (-1, 0, 0);
		return (v, 0, 1);
	'0' to '7' =>
		if(c == '0' && (l.pos >= n || !isdigit(s[l.pos])))
			return (0, 0, 1);
		if(intemplate)
			return (-1, 0, 0);
		# legacy octal: up to three digits, at most 377
		v := c - '0';
		if(l.pos < n && s[l.pos] >= '0' && s[l.pos] <= '7') {
			v = v * 8 + s[l.pos++] - '0';
			if(c <= '3' && l.pos < n && s[l.pos] >= '0' && s[l.pos] <= '7')
				v = v * 8 + s[l.pos++] - '0';
		}
		return (v, 1, 1);
	'8' or '9' =>
		if(intemplate)
			return (-1, 0, 0);
		return (c, 1, 1);
	}
	return (c, 0, 1);
}

str(l: ref Lex, q: int): ref Tok
{
	s := l.src;
	n := len s;
	st := l.pos;
	l.pos++;
	v := "";
	legacy := 0;
	for(;;) {
		if(l.pos >= n)
			return error(l, st, "unterminated string");
		c := s[l.pos];
		if(c == q) {
			l.pos++;
			break;
		}
		if(c == '\n' || c == '\r')
			return error(l, st, "unterminated string");
		l.pos++;
		if(c == '\\') {
			(e, leg, ok) := escape(l, 0);
			if(!ok)
				return error(l, l.pos - 1, "bad escape");
			if(leg)
				legacy = 1;
			if(e >= 0)
				v = putcp(v, e);
			continue;
		}
		v[len v] = c;
	}
	return ref Tok(Tstr, st, l.pos, v, 0.0, nil, 0, legacy, 0, 0, 0, nil);
}

# a template part from l.pos (after ` or }), to ${ or `
templ(l: ref Lex, st: int): ref Tok
{
	s := l.src;
	n := len s;
	v := "";
	raw := "";
	bad := 0;
	for(;;) {
		if(l.pos >= n)
			return error(l, st, "unterminated template");
		c := s[l.pos];
		if(c == '`') {
			l.pos++;
			return ref Tok(Ttemplate, st, l.pos, v, 0.0, nil, 0, 0, 0, 1, bad, raw);
		}
		if(c == '$' && l.pos + 1 < n && s[l.pos+1] == '{') {
			l.pos += 2;
			return ref Tok(Ttemplate, st, l.pos, v, 0.0, nil, 0, 0, 0, 0, bad, raw);
		}
		l.pos++;
		if(c == '\\') {
			rs := l.pos - 1;
			(e, nil, ok) := escape(l, 1);
			if(!ok) {
				bad = 1;
				# what follows \ and its letter is read again as template text
				l.pos = rs + 2;
			} else if(e >= 0)
				v = putcp(v, e);
			for(i := rs; i < l.pos && i < n; i++)
				raw[len raw] = s[i];
			continue;
		}
		if(c == '\r') {
			# CR and CRLF are LF in both cooked and raw
			if(l.pos < n && s[l.pos] == '\n')
				l.pos++;
			c = '\n';
		}
		v[len v] = c;
		raw[len raw] = c;
	}
}

regex(l: ref Lex): ref Tok
{
	s := l.src;
	n := len s;
	st := l.pos;
	l.pos++;
	inclass := 0;
	for(;;) {
		if(l.pos >= n || islt(s[l.pos]))
			return error(l, st, "unterminated regular expression");
		c := s[l.pos++];
		if(c == '\\') {
			if(l.pos >= n || islt(s[l.pos]))
				return error(l, st, "unterminated regular expression");
			l.pos++;
			continue;
		}
		if(c == '[')
			inclass = 1;
		else if(c == ']')
			inclass = 0;
		else if(c == '/' && !inclass)
			break;
	}
	body := s[st+1:l.pos-1];
	fst := l.pos;
	while(l.pos < n && isidpart(s[l.pos])) {
		if(s[l.pos] == '\\')
			return error(l, l.pos, "escape in regular expression flags");
		l.pos++;
	}
	if(l.pos < n && s[l.pos] == '\\')
		return error(l, l.pos, "escape in regular expression flags");
	flags := s[fst:l.pos];
	seen := "";
	for(i := 0; i < len flags; i++) {
		f := flags[i];
		case f {
		'd' or 'g' or 'i' or 'm' or 's' or 'u' or 'v' or 'y' =>
			;
		* =>
			return error(l, fst, "unknown regular expression flag");
		}
		for(j := 0; j < len seen; j++)
			if(seen[j] == f)
				return error(l, fst, "repeated regular expression flag");
		seen[len seen] = f;
	}
	for(i = 0; i < len seen; i++)
		if(seen[i] == 'u')
			for(j := 0; j < len seen; j++)
				if(seen[j] == 'v')
					return error(l, fst, "regular expression flags u and v together");
	return ref Tok(Tregex, st, l.pos, body, 0.0, flags, 0, 0, 0, 0, 0, nil);
}

# ID_Start beyond ASCII, as first, last pairs (Unicode 17.0, DerivedCoreProperties.txt)
idstart := array[] of {
	16rAA, 16rAA, 16rB5, 16rB5, 16rBA, 16rBA, 16rC0, 16rD6, 16rD8, 16rF6,
	16rF8, 16r2C1, 16r2C6, 16r2D1, 16r2E0, 16r2E4, 16r2EC, 16r2EC,
	16r2EE, 16r2EE, 16r370, 16r374, 16r376, 16r377, 16r37A, 16r37D,
	16r37F, 16r37F, 16r386, 16r386, 16r388, 16r38A, 16r38C, 16r38C,
	16r38E, 16r3A1, 16r3A3, 16r3F5, 16r3F7, 16r481, 16r48A, 16r52F,
	16r531, 16r556, 16r559, 16r559, 16r560, 16r588, 16r5D0, 16r5EA,
	16r5EF, 16r5F2, 16r620, 16r64A, 16r66E, 16r66F, 16r671, 16r6D3,
	16r6D5, 16r6D5, 16r6E5, 16r6E6, 16r6EE, 16r6EF, 16r6FA, 16r6FC,
	16r6FF, 16r6FF, 16r710, 16r710, 16r712, 16r72F, 16r74D, 16r7A5,
	16r7B1, 16r7B1, 16r7CA, 16r7EA, 16r7F4, 16r7F5, 16r7FA, 16r7FA,
	16r800, 16r815, 16r81A, 16r81A, 16r824, 16r824, 16r828, 16r828,
	16r840, 16r858, 16r860, 16r86A, 16r870, 16r887, 16r889, 16r88F,
	16r8A0, 16r8C9, 16r904, 16r939, 16r93D, 16r93D, 16r950, 16r950,
	16r958, 16r961, 16r971, 16r980, 16r985, 16r98C, 16r98F, 16r990,
	16r993, 16r9A8, 16r9AA, 16r9B0, 16r9B2, 16r9B2, 16r9B6, 16r9B9,
	16r9BD, 16r9BD, 16r9CE, 16r9CE, 16r9DC, 16r9DD, 16r9DF, 16r9E1,
	16r9F0, 16r9F1, 16r9FC, 16r9FC, 16rA05, 16rA0A, 16rA0F, 16rA10,
	16rA13, 16rA28, 16rA2A, 16rA30, 16rA32, 16rA33, 16rA35, 16rA36,
	16rA38, 16rA39, 16rA59, 16rA5C, 16rA5E, 16rA5E, 16rA72, 16rA74,
	16rA85, 16rA8D, 16rA8F, 16rA91, 16rA93, 16rAA8, 16rAAA, 16rAB0,
	16rAB2, 16rAB3, 16rAB5, 16rAB9, 16rABD, 16rABD, 16rAD0, 16rAD0,
	16rAE0, 16rAE1, 16rAF9, 16rAF9, 16rB05, 16rB0C, 16rB0F, 16rB10,
	16rB13, 16rB28, 16rB2A, 16rB30, 16rB32, 16rB33, 16rB35, 16rB39,
	16rB3D, 16rB3D, 16rB5C, 16rB5D, 16rB5F, 16rB61, 16rB71, 16rB71,
	16rB83, 16rB83, 16rB85, 16rB8A, 16rB8E, 16rB90, 16rB92, 16rB95,
	16rB99, 16rB9A, 16rB9C, 16rB9C, 16rB9E, 16rB9F, 16rBA3, 16rBA4,
	16rBA8, 16rBAA, 16rBAE, 16rBB9, 16rBD0, 16rBD0, 16rC05, 16rC0C,
	16rC0E, 16rC10, 16rC12, 16rC28, 16rC2A, 16rC39, 16rC3D, 16rC3D,
	16rC58, 16rC5A, 16rC5C, 16rC5D, 16rC60, 16rC61, 16rC80, 16rC80,
	16rC85, 16rC8C, 16rC8E, 16rC90, 16rC92, 16rCA8, 16rCAA, 16rCB3,
	16rCB5, 16rCB9, 16rCBD, 16rCBD, 16rCDC, 16rCDE, 16rCE0, 16rCE1,
	16rCF1, 16rCF2, 16rD04, 16rD0C, 16rD0E, 16rD10, 16rD12, 16rD3A,
	16rD3D, 16rD3D, 16rD4E, 16rD4E, 16rD54, 16rD56, 16rD5F, 16rD61,
	16rD7A, 16rD7F, 16rD85, 16rD96, 16rD9A, 16rDB1, 16rDB3, 16rDBB,
	16rDBD, 16rDBD, 16rDC0, 16rDC6, 16rE01, 16rE30, 16rE32, 16rE33,
	16rE40, 16rE46, 16rE81, 16rE82, 16rE84, 16rE84, 16rE86, 16rE8A,
	16rE8C, 16rEA3, 16rEA5, 16rEA5, 16rEA7, 16rEB0, 16rEB2, 16rEB3,
	16rEBD, 16rEBD, 16rEC0, 16rEC4, 16rEC6, 16rEC6, 16rEDC, 16rEDF,
	16rF00, 16rF00, 16rF40, 16rF47, 16rF49, 16rF6C, 16rF88, 16rF8C,
	16r1000, 16r102A, 16r103F, 16r103F, 16r1050, 16r1055, 16r105A, 16r105D,
	16r1061, 16r1061, 16r1065, 16r1066, 16r106E, 16r1070, 16r1075, 16r1081,
	16r108E, 16r108E, 16r10A0, 16r10C5, 16r10C7, 16r10C7, 16r10CD, 16r10CD,
	16r10D0, 16r10FA, 16r10FC, 16r1248, 16r124A, 16r124D, 16r1250, 16r1256,
	16r1258, 16r1258, 16r125A, 16r125D, 16r1260, 16r1288, 16r128A, 16r128D,
	16r1290, 16r12B0, 16r12B2, 16r12B5, 16r12B8, 16r12BE, 16r12C0, 16r12C0,
	16r12C2, 16r12C5, 16r12C8, 16r12D6, 16r12D8, 16r1310, 16r1312, 16r1315,
	16r1318, 16r135A, 16r1380, 16r138F, 16r13A0, 16r13F5, 16r13F8, 16r13FD,
	16r1401, 16r166C, 16r166F, 16r167F, 16r1681, 16r169A, 16r16A0, 16r16EA,
	16r16EE, 16r16F8, 16r1700, 16r1711, 16r171F, 16r1731, 16r1740, 16r1751,
	16r1760, 16r176C, 16r176E, 16r1770, 16r1780, 16r17B3, 16r17D7, 16r17D7,
	16r17DC, 16r17DC, 16r1820, 16r1878, 16r1880, 16r18A8, 16r18AA, 16r18AA,
	16r18B0, 16r18F5, 16r1900, 16r191E, 16r1950, 16r196D, 16r1970, 16r1974,
	16r1980, 16r19AB, 16r19B0, 16r19C9, 16r1A00, 16r1A16, 16r1A20, 16r1A54,
	16r1AA7, 16r1AA7, 16r1B05, 16r1B33, 16r1B45, 16r1B4C, 16r1B83, 16r1BA0,
	16r1BAE, 16r1BAF, 16r1BBA, 16r1BE5, 16r1C00, 16r1C23, 16r1C4D, 16r1C4F,
	16r1C5A, 16r1C7D, 16r1C80, 16r1C8A, 16r1C90, 16r1CBA, 16r1CBD, 16r1CBF,
	16r1CE9, 16r1CEC, 16r1CEE, 16r1CF3, 16r1CF5, 16r1CF6, 16r1CFA, 16r1CFA,
	16r1D00, 16r1DBF, 16r1E00, 16r1F15, 16r1F18, 16r1F1D, 16r1F20, 16r1F45,
	16r1F48, 16r1F4D, 16r1F50, 16r1F57, 16r1F59, 16r1F59, 16r1F5B, 16r1F5B,
	16r1F5D, 16r1F5D, 16r1F5F, 16r1F7D, 16r1F80, 16r1FB4, 16r1FB6, 16r1FBC,
	16r1FBE, 16r1FBE, 16r1FC2, 16r1FC4, 16r1FC6, 16r1FCC, 16r1FD0, 16r1FD3,
	16r1FD6, 16r1FDB, 16r1FE0, 16r1FEC, 16r1FF2, 16r1FF4, 16r1FF6, 16r1FFC,
	16r2071, 16r2071, 16r207F, 16r207F, 16r2090, 16r209C, 16r2102, 16r2102,
	16r2107, 16r2107, 16r210A, 16r2113, 16r2115, 16r2115, 16r2118, 16r211D,
	16r2124, 16r2124, 16r2126, 16r2126, 16r2128, 16r2128, 16r212A, 16r2139,
	16r213C, 16r213F, 16r2145, 16r2149, 16r214E, 16r214E, 16r2160, 16r2188,
	16r2C00, 16r2CE4, 16r2CEB, 16r2CEE, 16r2CF2, 16r2CF3, 16r2D00, 16r2D25,
	16r2D27, 16r2D27, 16r2D2D, 16r2D2D, 16r2D30, 16r2D67, 16r2D6F, 16r2D6F,
	16r2D80, 16r2D96, 16r2DA0, 16r2DA6, 16r2DA8, 16r2DAE, 16r2DB0, 16r2DB6,
	16r2DB8, 16r2DBE, 16r2DC0, 16r2DC6, 16r2DC8, 16r2DCE, 16r2DD0, 16r2DD6,
	16r2DD8, 16r2DDE, 16r3005, 16r3007, 16r3021, 16r3029, 16r3031, 16r3035,
	16r3038, 16r303C, 16r3041, 16r3096, 16r309B, 16r309F, 16r30A1, 16r30FA,
	16r30FC, 16r30FF, 16r3105, 16r312F, 16r3131, 16r318E, 16r31A0, 16r31BF,
	16r31F0, 16r31FF, 16r3400, 16r4DBF, 16r4E00, 16rA48C, 16rA4D0, 16rA4FD,
	16rA500, 16rA60C, 16rA610, 16rA61F, 16rA62A, 16rA62B, 16rA640, 16rA66E,
	16rA67F, 16rA69D, 16rA6A0, 16rA6EF, 16rA717, 16rA71F, 16rA722, 16rA788,
	16rA78B, 16rA7DC, 16rA7F1, 16rA801, 16rA803, 16rA805, 16rA807, 16rA80A,
	16rA80C, 16rA822, 16rA840, 16rA873, 16rA882, 16rA8B3, 16rA8F2, 16rA8F7,
	16rA8FB, 16rA8FB, 16rA8FD, 16rA8FE, 16rA90A, 16rA925, 16rA930, 16rA946,
	16rA960, 16rA97C, 16rA984, 16rA9B2, 16rA9CF, 16rA9CF, 16rA9E0, 16rA9E4,
	16rA9E6, 16rA9EF, 16rA9FA, 16rA9FE, 16rAA00, 16rAA28, 16rAA40, 16rAA42,
	16rAA44, 16rAA4B, 16rAA60, 16rAA76, 16rAA7A, 16rAA7A, 16rAA7E, 16rAAAF,
	16rAAB1, 16rAAB1, 16rAAB5, 16rAAB6, 16rAAB9, 16rAABD, 16rAAC0, 16rAAC0,
	16rAAC2, 16rAAC2, 16rAADB, 16rAADD, 16rAAE0, 16rAAEA, 16rAAF2, 16rAAF4,
	16rAB01, 16rAB06, 16rAB09, 16rAB0E, 16rAB11, 16rAB16, 16rAB20, 16rAB26,
	16rAB28, 16rAB2E, 16rAB30, 16rAB5A, 16rAB5C, 16rAB69, 16rAB70, 16rABE2,
	16rAC00, 16rD7A3, 16rD7B0, 16rD7C6, 16rD7CB, 16rD7FB, 16rF900, 16rFA6D,
	16rFA70, 16rFAD9, 16rFB00, 16rFB06, 16rFB13, 16rFB17, 16rFB1D, 16rFB1D,
	16rFB1F, 16rFB28, 16rFB2A, 16rFB36, 16rFB38, 16rFB3C, 16rFB3E, 16rFB3E,
	16rFB40, 16rFB41, 16rFB43, 16rFB44, 16rFB46, 16rFBB1, 16rFBD3, 16rFD3D,
	16rFD50, 16rFD8F, 16rFD92, 16rFDC7, 16rFDF0, 16rFDFB, 16rFE70, 16rFE74,
	16rFE76, 16rFEFC, 16rFF21, 16rFF3A, 16rFF41, 16rFF5A, 16rFF66, 16rFFBE,
	16rFFC2, 16rFFC7, 16rFFCA, 16rFFCF, 16rFFD2, 16rFFD7, 16rFFDA, 16rFFDC,
	16r10000, 16r1000B, 16r1000D, 16r10026, 16r10028, 16r1003A,
	16r1003C, 16r1003D, 16r1003F, 16r1004D, 16r10050, 16r1005D,
	16r10080, 16r100FA, 16r10140, 16r10174, 16r10280, 16r1029C,
	16r102A0, 16r102D0, 16r10300, 16r1031F, 16r1032D, 16r1034A,
	16r10350, 16r10375, 16r10380, 16r1039D, 16r103A0, 16r103C3,
	16r103C8, 16r103CF, 16r103D1, 16r103D5, 16r10400, 16r1049D,
	16r104B0, 16r104D3, 16r104D8, 16r104FB, 16r10500, 16r10527,
	16r10530, 16r10563, 16r10570, 16r1057A, 16r1057C, 16r1058A,
	16r1058C, 16r10592, 16r10594, 16r10595, 16r10597, 16r105A1,
	16r105A3, 16r105B1, 16r105B3, 16r105B9, 16r105BB, 16r105BC,
	16r105C0, 16r105F3, 16r10600, 16r10736, 16r10740, 16r10755,
	16r10760, 16r10767, 16r10780, 16r10785, 16r10787, 16r107B0,
	16r107B2, 16r107BA, 16r10800, 16r10805, 16r10808, 16r10808,
	16r1080A, 16r10835, 16r10837, 16r10838, 16r1083C, 16r1083C,
	16r1083F, 16r10855, 16r10860, 16r10876, 16r10880, 16r1089E,
	16r108E0, 16r108F2, 16r108F4, 16r108F5, 16r10900, 16r10915,
	16r10920, 16r10939, 16r10940, 16r10959, 16r10980, 16r109B7,
	16r109BE, 16r109BF, 16r10A00, 16r10A00, 16r10A10, 16r10A13,
	16r10A15, 16r10A17, 16r10A19, 16r10A35, 16r10A60, 16r10A7C,
	16r10A80, 16r10A9C, 16r10AC0, 16r10AC7, 16r10AC9, 16r10AE4,
	16r10B00, 16r10B35, 16r10B40, 16r10B55, 16r10B60, 16r10B72,
	16r10B80, 16r10B91, 16r10C00, 16r10C48, 16r10C80, 16r10CB2,
	16r10CC0, 16r10CF2, 16r10D00, 16r10D23, 16r10D4A, 16r10D65,
	16r10D6F, 16r10D85, 16r10E80, 16r10EA9, 16r10EB0, 16r10EB1,
	16r10EC2, 16r10EC7, 16r10F00, 16r10F1C, 16r10F27, 16r10F27,
	16r10F30, 16r10F45, 16r10F70, 16r10F81, 16r10FB0, 16r10FC4,
	16r10FE0, 16r10FF6, 16r11003, 16r11037, 16r11071, 16r11072,
	16r11075, 16r11075, 16r11083, 16r110AF, 16r110D0, 16r110E8,
	16r11103, 16r11126, 16r11144, 16r11144, 16r11147, 16r11147,
	16r11150, 16r11172, 16r11176, 16r11176, 16r11183, 16r111B2,
	16r111C1, 16r111C4, 16r111DA, 16r111DA, 16r111DC, 16r111DC,
	16r11200, 16r11211, 16r11213, 16r1122B, 16r1123F, 16r11240,
	16r11280, 16r11286, 16r11288, 16r11288, 16r1128A, 16r1128D,
	16r1128F, 16r1129D, 16r1129F, 16r112A8, 16r112B0, 16r112DE,
	16r11305, 16r1130C, 16r1130F, 16r11310, 16r11313, 16r11328,
	16r1132A, 16r11330, 16r11332, 16r11333, 16r11335, 16r11339,
	16r1133D, 16r1133D, 16r11350, 16r11350, 16r1135D, 16r11361,
	16r11380, 16r11389, 16r1138B, 16r1138B, 16r1138E, 16r1138E,
	16r11390, 16r113B5, 16r113B7, 16r113B7, 16r113D1, 16r113D1,
	16r113D3, 16r113D3, 16r11400, 16r11434, 16r11447, 16r1144A,
	16r1145F, 16r11461, 16r11480, 16r114AF, 16r114C4, 16r114C5,
	16r114C7, 16r114C7, 16r11580, 16r115AE, 16r115D8, 16r115DB,
	16r11600, 16r1162F, 16r11644, 16r11644, 16r11680, 16r116AA,
	16r116B8, 16r116B8, 16r11700, 16r1171A, 16r11740, 16r11746,
	16r11800, 16r1182B, 16r118A0, 16r118DF, 16r118FF, 16r11906,
	16r11909, 16r11909, 16r1190C, 16r11913, 16r11915, 16r11916,
	16r11918, 16r1192F, 16r1193F, 16r1193F, 16r11941, 16r11941,
	16r119A0, 16r119A7, 16r119AA, 16r119D0, 16r119E1, 16r119E1,
	16r119E3, 16r119E3, 16r11A00, 16r11A00, 16r11A0B, 16r11A32,
	16r11A3A, 16r11A3A, 16r11A50, 16r11A50, 16r11A5C, 16r11A89,
	16r11A9D, 16r11A9D, 16r11AB0, 16r11AF8, 16r11BC0, 16r11BE0,
	16r11C00, 16r11C08, 16r11C0A, 16r11C2E, 16r11C40, 16r11C40,
	16r11C72, 16r11C8F, 16r11D00, 16r11D06, 16r11D08, 16r11D09,
	16r11D0B, 16r11D30, 16r11D46, 16r11D46, 16r11D60, 16r11D65,
	16r11D67, 16r11D68, 16r11D6A, 16r11D89, 16r11D98, 16r11D98,
	16r11DB0, 16r11DDB, 16r11EE0, 16r11EF2, 16r11F02, 16r11F02,
	16r11F04, 16r11F10, 16r11F12, 16r11F33, 16r11FB0, 16r11FB0,
	16r12000, 16r12399, 16r12400, 16r1246E, 16r12480, 16r12543,
	16r12F90, 16r12FF0, 16r13000, 16r1342F, 16r13441, 16r13446,
	16r13460, 16r143FA, 16r14400, 16r14646, 16r16100, 16r1611D,
	16r16800, 16r16A38, 16r16A40, 16r16A5E, 16r16A70, 16r16ABE,
	16r16AD0, 16r16AED, 16r16B00, 16r16B2F, 16r16B40, 16r16B43,
	16r16B63, 16r16B77, 16r16B7D, 16r16B8F, 16r16D40, 16r16D6C,
	16r16E40, 16r16E7F, 16r16EA0, 16r16EB8, 16r16EBB, 16r16ED3,
	16r16F00, 16r16F4A, 16r16F50, 16r16F50, 16r16F93, 16r16F9F,
	16r16FE0, 16r16FE1, 16r16FE3, 16r16FE3, 16r16FF2, 16r16FF6,
	16r17000, 16r18CD5, 16r18CFF, 16r18D1E, 16r18D80, 16r18DF2,
	16r1AFF0, 16r1AFF3, 16r1AFF5, 16r1AFFB, 16r1AFFD, 16r1AFFE,
	16r1B000, 16r1B122, 16r1B132, 16r1B132, 16r1B150, 16r1B152,
	16r1B155, 16r1B155, 16r1B164, 16r1B167, 16r1B170, 16r1B2FB,
	16r1BC00, 16r1BC6A, 16r1BC70, 16r1BC7C, 16r1BC80, 16r1BC88,
	16r1BC90, 16r1BC99, 16r1D400, 16r1D454, 16r1D456, 16r1D49C,
	16r1D49E, 16r1D49F, 16r1D4A2, 16r1D4A2, 16r1D4A5, 16r1D4A6,
	16r1D4A9, 16r1D4AC, 16r1D4AE, 16r1D4B9, 16r1D4BB, 16r1D4BB,
	16r1D4BD, 16r1D4C3, 16r1D4C5, 16r1D505, 16r1D507, 16r1D50A,
	16r1D50D, 16r1D514, 16r1D516, 16r1D51C, 16r1D51E, 16r1D539,
	16r1D53B, 16r1D53E, 16r1D540, 16r1D544, 16r1D546, 16r1D546,
	16r1D54A, 16r1D550, 16r1D552, 16r1D6A5, 16r1D6A8, 16r1D6C0,
	16r1D6C2, 16r1D6DA, 16r1D6DC, 16r1D6FA, 16r1D6FC, 16r1D714,
	16r1D716, 16r1D734, 16r1D736, 16r1D74E, 16r1D750, 16r1D76E,
	16r1D770, 16r1D788, 16r1D78A, 16r1D7A8, 16r1D7AA, 16r1D7C2,
	16r1D7C4, 16r1D7CB, 16r1DF00, 16r1DF1E, 16r1DF25, 16r1DF2A,
	16r1E030, 16r1E06D, 16r1E100, 16r1E12C, 16r1E137, 16r1E13D,
	16r1E14E, 16r1E14E, 16r1E290, 16r1E2AD, 16r1E2C0, 16r1E2EB,
	16r1E4D0, 16r1E4EB, 16r1E5D0, 16r1E5ED, 16r1E5F0, 16r1E5F0,
	16r1E6C0, 16r1E6DE, 16r1E6E0, 16r1E6E2, 16r1E6E4, 16r1E6E5,
	16r1E6E7, 16r1E6ED, 16r1E6F0, 16r1E6F4, 16r1E6FE, 16r1E6FF,
	16r1E7E0, 16r1E7E6, 16r1E7E8, 16r1E7EB, 16r1E7ED, 16r1E7EE,
	16r1E7F0, 16r1E7FE, 16r1E800, 16r1E8C4, 16r1E900, 16r1E943,
	16r1E94B, 16r1E94B, 16r1EE00, 16r1EE03, 16r1EE05, 16r1EE1F,
	16r1EE21, 16r1EE22, 16r1EE24, 16r1EE24, 16r1EE27, 16r1EE27,
	16r1EE29, 16r1EE32, 16r1EE34, 16r1EE37, 16r1EE39, 16r1EE39,
	16r1EE3B, 16r1EE3B, 16r1EE42, 16r1EE42, 16r1EE47, 16r1EE47,
	16r1EE49, 16r1EE49, 16r1EE4B, 16r1EE4B, 16r1EE4D, 16r1EE4F,
	16r1EE51, 16r1EE52, 16r1EE54, 16r1EE54, 16r1EE57, 16r1EE57,
	16r1EE59, 16r1EE59, 16r1EE5B, 16r1EE5B, 16r1EE5D, 16r1EE5D,
	16r1EE5F, 16r1EE5F, 16r1EE61, 16r1EE62, 16r1EE64, 16r1EE64,
	16r1EE67, 16r1EE6A, 16r1EE6C, 16r1EE72, 16r1EE74, 16r1EE77,
	16r1EE79, 16r1EE7C, 16r1EE7E, 16r1EE7E, 16r1EE80, 16r1EE89,
	16r1EE8B, 16r1EE9B, 16r1EEA1, 16r1EEA3, 16r1EEA5, 16r1EEA9,
	16r1EEAB, 16r1EEBB, 16r20000, 16r2A6DF, 16r2A700, 16r2B81D,
	16r2B820, 16r2CEAD, 16r2CEB0, 16r2EBE0, 16r2EBF0, 16r2EE5D,
	16r2F800, 16r2FA1D, 16r30000, 16r3134A, 16r31350, 16r33479
};

# ID_Continue beyond ASCII, as first, last pairs (Unicode 17.0, DerivedCoreProperties.txt)
idcont := array[] of {
	16rAA, 16rAA, 16rB5, 16rB5, 16rB7, 16rB7, 16rBA, 16rBA, 16rC0, 16rD6,
	16rD8, 16rF6, 16rF8, 16r2C1, 16r2C6, 16r2D1, 16r2E0, 16r2E4,
	16r2EC, 16r2EC, 16r2EE, 16r2EE, 16r300, 16r374, 16r376, 16r377,
	16r37A, 16r37D, 16r37F, 16r37F, 16r386, 16r38A, 16r38C, 16r38C,
	16r38E, 16r3A1, 16r3A3, 16r3F5, 16r3F7, 16r481, 16r483, 16r487,
	16r48A, 16r52F, 16r531, 16r556, 16r559, 16r559, 16r560, 16r588,
	16r591, 16r5BD, 16r5BF, 16r5BF, 16r5C1, 16r5C2, 16r5C4, 16r5C5,
	16r5C7, 16r5C7, 16r5D0, 16r5EA, 16r5EF, 16r5F2, 16r610, 16r61A,
	16r620, 16r669, 16r66E, 16r6D3, 16r6D5, 16r6DC, 16r6DF, 16r6E8,
	16r6EA, 16r6FC, 16r6FF, 16r6FF, 16r710, 16r74A, 16r74D, 16r7B1,
	16r7C0, 16r7F5, 16r7FA, 16r7FA, 16r7FD, 16r7FD, 16r800, 16r82D,
	16r840, 16r85B, 16r860, 16r86A, 16r870, 16r887, 16r889, 16r88F,
	16r897, 16r8E1, 16r8E3, 16r963, 16r966, 16r96F, 16r971, 16r983,
	16r985, 16r98C, 16r98F, 16r990, 16r993, 16r9A8, 16r9AA, 16r9B0,
	16r9B2, 16r9B2, 16r9B6, 16r9B9, 16r9BC, 16r9C4, 16r9C7, 16r9C8,
	16r9CB, 16r9CE, 16r9D7, 16r9D7, 16r9DC, 16r9DD, 16r9DF, 16r9E3,
	16r9E6, 16r9F1, 16r9FC, 16r9FC, 16r9FE, 16r9FE, 16rA01, 16rA03,
	16rA05, 16rA0A, 16rA0F, 16rA10, 16rA13, 16rA28, 16rA2A, 16rA30,
	16rA32, 16rA33, 16rA35, 16rA36, 16rA38, 16rA39, 16rA3C, 16rA3C,
	16rA3E, 16rA42, 16rA47, 16rA48, 16rA4B, 16rA4D, 16rA51, 16rA51,
	16rA59, 16rA5C, 16rA5E, 16rA5E, 16rA66, 16rA75, 16rA81, 16rA83,
	16rA85, 16rA8D, 16rA8F, 16rA91, 16rA93, 16rAA8, 16rAAA, 16rAB0,
	16rAB2, 16rAB3, 16rAB5, 16rAB9, 16rABC, 16rAC5, 16rAC7, 16rAC9,
	16rACB, 16rACD, 16rAD0, 16rAD0, 16rAE0, 16rAE3, 16rAE6, 16rAEF,
	16rAF9, 16rAFF, 16rB01, 16rB03, 16rB05, 16rB0C, 16rB0F, 16rB10,
	16rB13, 16rB28, 16rB2A, 16rB30, 16rB32, 16rB33, 16rB35, 16rB39,
	16rB3C, 16rB44, 16rB47, 16rB48, 16rB4B, 16rB4D, 16rB55, 16rB57,
	16rB5C, 16rB5D, 16rB5F, 16rB63, 16rB66, 16rB6F, 16rB71, 16rB71,
	16rB82, 16rB83, 16rB85, 16rB8A, 16rB8E, 16rB90, 16rB92, 16rB95,
	16rB99, 16rB9A, 16rB9C, 16rB9C, 16rB9E, 16rB9F, 16rBA3, 16rBA4,
	16rBA8, 16rBAA, 16rBAE, 16rBB9, 16rBBE, 16rBC2, 16rBC6, 16rBC8,
	16rBCA, 16rBCD, 16rBD0, 16rBD0, 16rBD7, 16rBD7, 16rBE6, 16rBEF,
	16rC00, 16rC0C, 16rC0E, 16rC10, 16rC12, 16rC28, 16rC2A, 16rC39,
	16rC3C, 16rC44, 16rC46, 16rC48, 16rC4A, 16rC4D, 16rC55, 16rC56,
	16rC58, 16rC5A, 16rC5C, 16rC5D, 16rC60, 16rC63, 16rC66, 16rC6F,
	16rC80, 16rC83, 16rC85, 16rC8C, 16rC8E, 16rC90, 16rC92, 16rCA8,
	16rCAA, 16rCB3, 16rCB5, 16rCB9, 16rCBC, 16rCC4, 16rCC6, 16rCC8,
	16rCCA, 16rCCD, 16rCD5, 16rCD6, 16rCDC, 16rCDE, 16rCE0, 16rCE3,
	16rCE6, 16rCEF, 16rCF1, 16rCF3, 16rD00, 16rD0C, 16rD0E, 16rD10,
	16rD12, 16rD44, 16rD46, 16rD48, 16rD4A, 16rD4E, 16rD54, 16rD57,
	16rD5F, 16rD63, 16rD66, 16rD6F, 16rD7A, 16rD7F, 16rD81, 16rD83,
	16rD85, 16rD96, 16rD9A, 16rDB1, 16rDB3, 16rDBB, 16rDBD, 16rDBD,
	16rDC0, 16rDC6, 16rDCA, 16rDCA, 16rDCF, 16rDD4, 16rDD6, 16rDD6,
	16rDD8, 16rDDF, 16rDE6, 16rDEF, 16rDF2, 16rDF3, 16rE01, 16rE3A,
	16rE40, 16rE4E, 16rE50, 16rE59, 16rE81, 16rE82, 16rE84, 16rE84,
	16rE86, 16rE8A, 16rE8C, 16rEA3, 16rEA5, 16rEA5, 16rEA7, 16rEBD,
	16rEC0, 16rEC4, 16rEC6, 16rEC6, 16rEC8, 16rECE, 16rED0, 16rED9,
	16rEDC, 16rEDF, 16rF00, 16rF00, 16rF18, 16rF19, 16rF20, 16rF29,
	16rF35, 16rF35, 16rF37, 16rF37, 16rF39, 16rF39, 16rF3E, 16rF47,
	16rF49, 16rF6C, 16rF71, 16rF84, 16rF86, 16rF97, 16rF99, 16rFBC,
	16rFC6, 16rFC6, 16r1000, 16r1049, 16r1050, 16r109D, 16r10A0, 16r10C5,
	16r10C7, 16r10C7, 16r10CD, 16r10CD, 16r10D0, 16r10FA, 16r10FC, 16r1248,
	16r124A, 16r124D, 16r1250, 16r1256, 16r1258, 16r1258, 16r125A, 16r125D,
	16r1260, 16r1288, 16r128A, 16r128D, 16r1290, 16r12B0, 16r12B2, 16r12B5,
	16r12B8, 16r12BE, 16r12C0, 16r12C0, 16r12C2, 16r12C5, 16r12C8, 16r12D6,
	16r12D8, 16r1310, 16r1312, 16r1315, 16r1318, 16r135A, 16r135D, 16r135F,
	16r1369, 16r1371, 16r1380, 16r138F, 16r13A0, 16r13F5, 16r13F8, 16r13FD,
	16r1401, 16r166C, 16r166F, 16r167F, 16r1681, 16r169A, 16r16A0, 16r16EA,
	16r16EE, 16r16F8, 16r1700, 16r1715, 16r171F, 16r1734, 16r1740, 16r1753,
	16r1760, 16r176C, 16r176E, 16r1770, 16r1772, 16r1773, 16r1780, 16r17D3,
	16r17D7, 16r17D7, 16r17DC, 16r17DD, 16r17E0, 16r17E9, 16r180B, 16r180D,
	16r180F, 16r1819, 16r1820, 16r1878, 16r1880, 16r18AA, 16r18B0, 16r18F5,
	16r1900, 16r191E, 16r1920, 16r192B, 16r1930, 16r193B, 16r1946, 16r196D,
	16r1970, 16r1974, 16r1980, 16r19AB, 16r19B0, 16r19C9, 16r19D0, 16r19DA,
	16r1A00, 16r1A1B, 16r1A20, 16r1A5E, 16r1A60, 16r1A7C, 16r1A7F, 16r1A89,
	16r1A90, 16r1A99, 16r1AA7, 16r1AA7, 16r1AB0, 16r1ABD, 16r1ABF, 16r1ADD,
	16r1AE0, 16r1AEB, 16r1B00, 16r1B4C, 16r1B50, 16r1B59, 16r1B6B, 16r1B73,
	16r1B80, 16r1BF3, 16r1C00, 16r1C37, 16r1C40, 16r1C49, 16r1C4D, 16r1C7D,
	16r1C80, 16r1C8A, 16r1C90, 16r1CBA, 16r1CBD, 16r1CBF, 16r1CD0, 16r1CD2,
	16r1CD4, 16r1CFA, 16r1D00, 16r1F15, 16r1F18, 16r1F1D, 16r1F20, 16r1F45,
	16r1F48, 16r1F4D, 16r1F50, 16r1F57, 16r1F59, 16r1F59, 16r1F5B, 16r1F5B,
	16r1F5D, 16r1F5D, 16r1F5F, 16r1F7D, 16r1F80, 16r1FB4, 16r1FB6, 16r1FBC,
	16r1FBE, 16r1FBE, 16r1FC2, 16r1FC4, 16r1FC6, 16r1FCC, 16r1FD0, 16r1FD3,
	16r1FD6, 16r1FDB, 16r1FE0, 16r1FEC, 16r1FF2, 16r1FF4, 16r1FF6, 16r1FFC,
	16r200C, 16r200D, 16r203F, 16r2040, 16r2054, 16r2054, 16r2071, 16r2071,
	16r207F, 16r207F, 16r2090, 16r209C, 16r20D0, 16r20DC, 16r20E1, 16r20E1,
	16r20E5, 16r20F0, 16r2102, 16r2102, 16r2107, 16r2107, 16r210A, 16r2113,
	16r2115, 16r2115, 16r2118, 16r211D, 16r2124, 16r2124, 16r2126, 16r2126,
	16r2128, 16r2128, 16r212A, 16r2139, 16r213C, 16r213F, 16r2145, 16r2149,
	16r214E, 16r214E, 16r2160, 16r2188, 16r2C00, 16r2CE4, 16r2CEB, 16r2CF3,
	16r2D00, 16r2D25, 16r2D27, 16r2D27, 16r2D2D, 16r2D2D, 16r2D30, 16r2D67,
	16r2D6F, 16r2D6F, 16r2D7F, 16r2D96, 16r2DA0, 16r2DA6, 16r2DA8, 16r2DAE,
	16r2DB0, 16r2DB6, 16r2DB8, 16r2DBE, 16r2DC0, 16r2DC6, 16r2DC8, 16r2DCE,
	16r2DD0, 16r2DD6, 16r2DD8, 16r2DDE, 16r2DE0, 16r2DFF, 16r3005, 16r3007,
	16r3021, 16r302F, 16r3031, 16r3035, 16r3038, 16r303C, 16r3041, 16r3096,
	16r3099, 16r309F, 16r30A1, 16r30FF, 16r3105, 16r312F, 16r3131, 16r318E,
	16r31A0, 16r31BF, 16r31F0, 16r31FF, 16r3400, 16r4DBF, 16r4E00, 16rA48C,
	16rA4D0, 16rA4FD, 16rA500, 16rA60C, 16rA610, 16rA62B, 16rA640, 16rA66F,
	16rA674, 16rA67D, 16rA67F, 16rA6F1, 16rA717, 16rA71F, 16rA722, 16rA788,
	16rA78B, 16rA7DC, 16rA7F1, 16rA827, 16rA82C, 16rA82C, 16rA840, 16rA873,
	16rA880, 16rA8C5, 16rA8D0, 16rA8D9, 16rA8E0, 16rA8F7, 16rA8FB, 16rA8FB,
	16rA8FD, 16rA92D, 16rA930, 16rA953, 16rA960, 16rA97C, 16rA980, 16rA9C0,
	16rA9CF, 16rA9D9, 16rA9E0, 16rA9FE, 16rAA00, 16rAA36, 16rAA40, 16rAA4D,
	16rAA50, 16rAA59, 16rAA60, 16rAA76, 16rAA7A, 16rAAC2, 16rAADB, 16rAADD,
	16rAAE0, 16rAAEF, 16rAAF2, 16rAAF6, 16rAB01, 16rAB06, 16rAB09, 16rAB0E,
	16rAB11, 16rAB16, 16rAB20, 16rAB26, 16rAB28, 16rAB2E, 16rAB30, 16rAB5A,
	16rAB5C, 16rAB69, 16rAB70, 16rABEA, 16rABEC, 16rABED, 16rABF0, 16rABF9,
	16rAC00, 16rD7A3, 16rD7B0, 16rD7C6, 16rD7CB, 16rD7FB, 16rF900, 16rFA6D,
	16rFA70, 16rFAD9, 16rFB00, 16rFB06, 16rFB13, 16rFB17, 16rFB1D, 16rFB28,
	16rFB2A, 16rFB36, 16rFB38, 16rFB3C, 16rFB3E, 16rFB3E, 16rFB40, 16rFB41,
	16rFB43, 16rFB44, 16rFB46, 16rFBB1, 16rFBD3, 16rFD3D, 16rFD50, 16rFD8F,
	16rFD92, 16rFDC7, 16rFDF0, 16rFDFB, 16rFE00, 16rFE0F, 16rFE20, 16rFE2F,
	16rFE33, 16rFE34, 16rFE4D, 16rFE4F, 16rFE70, 16rFE74, 16rFE76, 16rFEFC,
	16rFF10, 16rFF19, 16rFF21, 16rFF3A, 16rFF3F, 16rFF3F, 16rFF41, 16rFF5A,
	16rFF65, 16rFFBE, 16rFFC2, 16rFFC7, 16rFFCA, 16rFFCF, 16rFFD2, 16rFFD7,
	16rFFDA, 16rFFDC, 16r10000, 16r1000B, 16r1000D, 16r10026,
	16r10028, 16r1003A, 16r1003C, 16r1003D, 16r1003F, 16r1004D,
	16r10050, 16r1005D, 16r10080, 16r100FA, 16r10140, 16r10174,
	16r101FD, 16r101FD, 16r10280, 16r1029C, 16r102A0, 16r102D0,
	16r102E0, 16r102E0, 16r10300, 16r1031F, 16r1032D, 16r1034A,
	16r10350, 16r1037A, 16r10380, 16r1039D, 16r103A0, 16r103C3,
	16r103C8, 16r103CF, 16r103D1, 16r103D5, 16r10400, 16r1049D,
	16r104A0, 16r104A9, 16r104B0, 16r104D3, 16r104D8, 16r104FB,
	16r10500, 16r10527, 16r10530, 16r10563, 16r10570, 16r1057A,
	16r1057C, 16r1058A, 16r1058C, 16r10592, 16r10594, 16r10595,
	16r10597, 16r105A1, 16r105A3, 16r105B1, 16r105B3, 16r105B9,
	16r105BB, 16r105BC, 16r105C0, 16r105F3, 16r10600, 16r10736,
	16r10740, 16r10755, 16r10760, 16r10767, 16r10780, 16r10785,
	16r10787, 16r107B0, 16r107B2, 16r107BA, 16r10800, 16r10805,
	16r10808, 16r10808, 16r1080A, 16r10835, 16r10837, 16r10838,
	16r1083C, 16r1083C, 16r1083F, 16r10855, 16r10860, 16r10876,
	16r10880, 16r1089E, 16r108E0, 16r108F2, 16r108F4, 16r108F5,
	16r10900, 16r10915, 16r10920, 16r10939, 16r10940, 16r10959,
	16r10980, 16r109B7, 16r109BE, 16r109BF, 16r10A00, 16r10A03,
	16r10A05, 16r10A06, 16r10A0C, 16r10A13, 16r10A15, 16r10A17,
	16r10A19, 16r10A35, 16r10A38, 16r10A3A, 16r10A3F, 16r10A3F,
	16r10A60, 16r10A7C, 16r10A80, 16r10A9C, 16r10AC0, 16r10AC7,
	16r10AC9, 16r10AE6, 16r10B00, 16r10B35, 16r10B40, 16r10B55,
	16r10B60, 16r10B72, 16r10B80, 16r10B91, 16r10C00, 16r10C48,
	16r10C80, 16r10CB2, 16r10CC0, 16r10CF2, 16r10D00, 16r10D27,
	16r10D30, 16r10D39, 16r10D40, 16r10D65, 16r10D69, 16r10D6D,
	16r10D6F, 16r10D85, 16r10E80, 16r10EA9, 16r10EAB, 16r10EAC,
	16r10EB0, 16r10EB1, 16r10EC2, 16r10EC7, 16r10EFA, 16r10F1C,
	16r10F27, 16r10F27, 16r10F30, 16r10F50, 16r10F70, 16r10F85,
	16r10FB0, 16r10FC4, 16r10FE0, 16r10FF6, 16r11000, 16r11046,
	16r11066, 16r11075, 16r1107F, 16r110BA, 16r110C2, 16r110C2,
	16r110D0, 16r110E8, 16r110F0, 16r110F9, 16r11100, 16r11134,
	16r11136, 16r1113F, 16r11144, 16r11147, 16r11150, 16r11173,
	16r11176, 16r11176, 16r11180, 16r111C4, 16r111C9, 16r111CC,
	16r111CE, 16r111DA, 16r111DC, 16r111DC, 16r11200, 16r11211,
	16r11213, 16r11237, 16r1123E, 16r11241, 16r11280, 16r11286,
	16r11288, 16r11288, 16r1128A, 16r1128D, 16r1128F, 16r1129D,
	16r1129F, 16r112A8, 16r112B0, 16r112EA, 16r112F0, 16r112F9,
	16r11300, 16r11303, 16r11305, 16r1130C, 16r1130F, 16r11310,
	16r11313, 16r11328, 16r1132A, 16r11330, 16r11332, 16r11333,
	16r11335, 16r11339, 16r1133B, 16r11344, 16r11347, 16r11348,
	16r1134B, 16r1134D, 16r11350, 16r11350, 16r11357, 16r11357,
	16r1135D, 16r11363, 16r11366, 16r1136C, 16r11370, 16r11374,
	16r11380, 16r11389, 16r1138B, 16r1138B, 16r1138E, 16r1138E,
	16r11390, 16r113B5, 16r113B7, 16r113C0, 16r113C2, 16r113C2,
	16r113C5, 16r113C5, 16r113C7, 16r113CA, 16r113CC, 16r113D3,
	16r113E1, 16r113E2, 16r11400, 16r1144A, 16r11450, 16r11459,
	16r1145E, 16r11461, 16r11480, 16r114C5, 16r114C7, 16r114C7,
	16r114D0, 16r114D9, 16r11580, 16r115B5, 16r115B8, 16r115C0,
	16r115D8, 16r115DD, 16r11600, 16r11640, 16r11644, 16r11644,
	16r11650, 16r11659, 16r11680, 16r116B8, 16r116C0, 16r116C9,
	16r116D0, 16r116E3, 16r11700, 16r1171A, 16r1171D, 16r1172B,
	16r11730, 16r11739, 16r11740, 16r11746, 16r11800, 16r1183A,
	16r118A0, 16r118E9, 16r118FF, 16r11906, 16r11909, 16r11909,
	16r1190C, 16r11913, 16r11915, 16r11916, 16r11918, 16r11935,
	16r11937, 16r11938, 16r1193B, 16r11943, 16r11950, 16r11959,
	16r119A0, 16r119A7, 16r119AA, 16r119D7, 16r119DA, 16r119E1,
	16r119E3, 16r119E4, 16r11A00, 16r11A3E, 16r11A47, 16r11A47,
	16r11A50, 16r11A99, 16r11A9D, 16r11A9D, 16r11AB0, 16r11AF8,
	16r11B60, 16r11B67, 16r11BC0, 16r11BE0, 16r11BF0, 16r11BF9,
	16r11C00, 16r11C08, 16r11C0A, 16r11C36, 16r11C38, 16r11C40,
	16r11C50, 16r11C59, 16r11C72, 16r11C8F, 16r11C92, 16r11CA7,
	16r11CA9, 16r11CB6, 16r11D00, 16r11D06, 16r11D08, 16r11D09,
	16r11D0B, 16r11D36, 16r11D3A, 16r11D3A, 16r11D3C, 16r11D3D,
	16r11D3F, 16r11D47, 16r11D50, 16r11D59, 16r11D60, 16r11D65,
	16r11D67, 16r11D68, 16r11D6A, 16r11D8E, 16r11D90, 16r11D91,
	16r11D93, 16r11D98, 16r11DA0, 16r11DA9, 16r11DB0, 16r11DDB,
	16r11DE0, 16r11DE9, 16r11EE0, 16r11EF6, 16r11F00, 16r11F10,
	16r11F12, 16r11F3A, 16r11F3E, 16r11F42, 16r11F50, 16r11F5A,
	16r11FB0, 16r11FB0, 16r12000, 16r12399, 16r12400, 16r1246E,
	16r12480, 16r12543, 16r12F90, 16r12FF0, 16r13000, 16r1342F,
	16r13440, 16r13455, 16r13460, 16r143FA, 16r14400, 16r14646,
	16r16100, 16r16139, 16r16800, 16r16A38, 16r16A40, 16r16A5E,
	16r16A60, 16r16A69, 16r16A70, 16r16ABE, 16r16AC0, 16r16AC9,
	16r16AD0, 16r16AED, 16r16AF0, 16r16AF4, 16r16B00, 16r16B36,
	16r16B40, 16r16B43, 16r16B50, 16r16B59, 16r16B63, 16r16B77,
	16r16B7D, 16r16B8F, 16r16D40, 16r16D6C, 16r16D70, 16r16D79,
	16r16E40, 16r16E7F, 16r16EA0, 16r16EB8, 16r16EBB, 16r16ED3,
	16r16F00, 16r16F4A, 16r16F4F, 16r16F87, 16r16F8F, 16r16F9F,
	16r16FE0, 16r16FE1, 16r16FE3, 16r16FE4, 16r16FF0, 16r16FF6,
	16r17000, 16r18CD5, 16r18CFF, 16r18D1E, 16r18D80, 16r18DF2,
	16r1AFF0, 16r1AFF3, 16r1AFF5, 16r1AFFB, 16r1AFFD, 16r1AFFE,
	16r1B000, 16r1B122, 16r1B132, 16r1B132, 16r1B150, 16r1B152,
	16r1B155, 16r1B155, 16r1B164, 16r1B167, 16r1B170, 16r1B2FB,
	16r1BC00, 16r1BC6A, 16r1BC70, 16r1BC7C, 16r1BC80, 16r1BC88,
	16r1BC90, 16r1BC99, 16r1BC9D, 16r1BC9E, 16r1CCF0, 16r1CCF9,
	16r1CF00, 16r1CF2D, 16r1CF30, 16r1CF46, 16r1D165, 16r1D169,
	16r1D16D, 16r1D172, 16r1D17B, 16r1D182, 16r1D185, 16r1D18B,
	16r1D1AA, 16r1D1AD, 16r1D242, 16r1D244, 16r1D400, 16r1D454,
	16r1D456, 16r1D49C, 16r1D49E, 16r1D49F, 16r1D4A2, 16r1D4A2,
	16r1D4A5, 16r1D4A6, 16r1D4A9, 16r1D4AC, 16r1D4AE, 16r1D4B9,
	16r1D4BB, 16r1D4BB, 16r1D4BD, 16r1D4C3, 16r1D4C5, 16r1D505,
	16r1D507, 16r1D50A, 16r1D50D, 16r1D514, 16r1D516, 16r1D51C,
	16r1D51E, 16r1D539, 16r1D53B, 16r1D53E, 16r1D540, 16r1D544,
	16r1D546, 16r1D546, 16r1D54A, 16r1D550, 16r1D552, 16r1D6A5,
	16r1D6A8, 16r1D6C0, 16r1D6C2, 16r1D6DA, 16r1D6DC, 16r1D6FA,
	16r1D6FC, 16r1D714, 16r1D716, 16r1D734, 16r1D736, 16r1D74E,
	16r1D750, 16r1D76E, 16r1D770, 16r1D788, 16r1D78A, 16r1D7A8,
	16r1D7AA, 16r1D7C2, 16r1D7C4, 16r1D7CB, 16r1D7CE, 16r1D7FF,
	16r1DA00, 16r1DA36, 16r1DA3B, 16r1DA6C, 16r1DA75, 16r1DA75,
	16r1DA84, 16r1DA84, 16r1DA9B, 16r1DA9F, 16r1DAA1, 16r1DAAF,
	16r1DF00, 16r1DF1E, 16r1DF25, 16r1DF2A, 16r1E000, 16r1E006,
	16r1E008, 16r1E018, 16r1E01B, 16r1E021, 16r1E023, 16r1E024,
	16r1E026, 16r1E02A, 16r1E030, 16r1E06D, 16r1E08F, 16r1E08F,
	16r1E100, 16r1E12C, 16r1E130, 16r1E13D, 16r1E140, 16r1E149,
	16r1E14E, 16r1E14E, 16r1E290, 16r1E2AE, 16r1E2C0, 16r1E2F9,
	16r1E4D0, 16r1E4F9, 16r1E5D0, 16r1E5FA, 16r1E6C0, 16r1E6DE,
	16r1E6E0, 16r1E6F5, 16r1E6FE, 16r1E6FF, 16r1E7E0, 16r1E7E6,
	16r1E7E8, 16r1E7EB, 16r1E7ED, 16r1E7EE, 16r1E7F0, 16r1E7FE,
	16r1E800, 16r1E8C4, 16r1E8D0, 16r1E8D6, 16r1E900, 16r1E94B,
	16r1E950, 16r1E959, 16r1EE00, 16r1EE03, 16r1EE05, 16r1EE1F,
	16r1EE21, 16r1EE22, 16r1EE24, 16r1EE24, 16r1EE27, 16r1EE27,
	16r1EE29, 16r1EE32, 16r1EE34, 16r1EE37, 16r1EE39, 16r1EE39,
	16r1EE3B, 16r1EE3B, 16r1EE42, 16r1EE42, 16r1EE47, 16r1EE47,
	16r1EE49, 16r1EE49, 16r1EE4B, 16r1EE4B, 16r1EE4D, 16r1EE4F,
	16r1EE51, 16r1EE52, 16r1EE54, 16r1EE54, 16r1EE57, 16r1EE57,
	16r1EE59, 16r1EE59, 16r1EE5B, 16r1EE5B, 16r1EE5D, 16r1EE5D,
	16r1EE5F, 16r1EE5F, 16r1EE61, 16r1EE62, 16r1EE64, 16r1EE64,
	16r1EE67, 16r1EE6A, 16r1EE6C, 16r1EE72, 16r1EE74, 16r1EE77,
	16r1EE79, 16r1EE7C, 16r1EE7E, 16r1EE7E, 16r1EE80, 16r1EE89,
	16r1EE8B, 16r1EE9B, 16r1EEA1, 16r1EEA3, 16r1EEA5, 16r1EEA9,
	16r1EEAB, 16r1EEBB, 16r1FBF0, 16r1FBF9, 16r20000, 16r2A6DF,
	16r2A700, 16r2B81D, 16r2B820, 16r2CEAD, 16r2CEB0, 16r2EBE0,
	16r2EBF0, 16r2EE5D, 16r2F800, 16r2FA1D, 16r30000, 16r3134A,
	16r31350, 16r33479, 16rE0100, 16rE01EF
};
