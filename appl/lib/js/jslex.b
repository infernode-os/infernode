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
	if(isws(c) || islt(c))
		return 0;
	if(c >= 16r2010 && c <= 16r206F || c >= 16r3000 && c <= 16r303F || c == 16rFEFF || c == 16rB7 || c >= 16r300 && c <= 16r36F)
		return c == 16r2118 || c == 16r212E;	# (the two Other_ID_Start characters in that range are not)
	return 1;
}

isidpart(c: int): int
{
	if(c < 128)
		return isidstart(c) || isdigit(c);
	if(c == 16r200C || c == 16r200D || c == 16rB7 || c >= 16r300 && c <= 16r36F || c == 16r387 || c >= 16r1369 && c <= 16r1371 || c == 16r19DA)
		return 1;
	return isidstart(c);
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
			if(c == '-' && (nl || l.pos == 0 || atlinestart(l)) && l.pos + 2 < n && s[l.pos+1] == '-' && s[l.pos+2] == '>') {
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
	if(isidstart(c) || c == '\\')
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
		} else if(first && isidstart(c) || !first && isidpart(c))
			l.pos++;
		else
			break;
		name[len name] = c;
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
	if(l.pos >= len l.src || !(isidstart(l.src[l.pos]) || l.src[l.pos] == '\\'))
		return error(l, st, "# without a name");
	t := ident(l, Tprivate);
	t.pos = st;
	return t;
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
		if(isidstart(c) || isdigit(c) || c == '\\')
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
				v[len v] = e;
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
				# skip what the escape would have been, to the next sensible point
				if(l.pos < rs + 2)
					l.pos = rs + 2;
			} else if(e >= 0)
				v[len v] = e;
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
