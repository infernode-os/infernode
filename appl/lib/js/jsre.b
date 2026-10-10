implement Jsre;

#
# The pattern grammar of §22.2.1, with Annex B.1.2's extensions where
# neither u nor v is set, by recursive descent.  The grammar's
# parameters are the mode: u (UnicodeMode: u or v), v (UnicodeSetsMode)
# and n (NamedCaptureGroups: u or v, or any group name in the pattern).
# Group counts and names are found first, by a scan, since a
# backreference may come before its group.
#

include "sys.m";
	sys: Sys;

include "jslex.m";
	jslex: Jslex;

include "jsre.m";

R: adt {
	s:	string;
	pos:	int;
	u, v, n:	int;
	ngroups:	int;		# in the whole pattern
	allnames:	list of string;
	group:	int;		# groups opened so far
	names:	array of string;
};

init()
{
	sys = load Sys Sys->PATH;
	jslex = load Jslex Jslex->PATH;
	jslex->init();
}

parseflags(s: string): (int, string)
{
	f := 0;
	for(i := 0; i < len s; i++) {
		b := 0;
		case s[i] {
		'd' => b = Fd;
		'g' => b = Fg;
		'i' => b = Fi;
		'm' => b = Fm;
		's' => b = Fs;
		'u' => b = Fu;
		'v' => b = Fv;
		'y' => b = Fy;
		* =>
			return (0, sys->sprint("invalid flag '%c'", s[i]));
		}
		if(f & b)
			return (0, sys->sprint("flag '%c' twice", s[i]));
		f |= b;
	}
	if((f & (Fu|Fv)) == (Fu|Fv))
		return (0, "flags u and v together");
	return (f, nil);
}

parse(pat: string, flags: int): (ref Pattern, string)
{
	if(sys == nil)
		init();
	u := (flags & (Fu|Fv)) != 0;
	r := ref R(pat, 0, u, (flags & Fv) != 0, u, 0, nil, 0, nil);
	{
		scan(r);
		if(r.allnames != nil)
			r.n = 1;
		r.names = array[r.ngroups + 1] of string;
		(re, nil) := disjunction(r);
		if(r.pos < len r.s) {
			if(r.s[r.pos] == ')')
				fail(r, "unmatched )");
			fail(r, "unexpected " + quote(r.s[r.pos]));
		}
		return (ref Pattern(re, flags, r.ngroups, r.names), nil);
	} exception e {
	"re:*" =>
		return (nil, "invalid regular expression: /" + pat + "/: " + e[3:]);
	}
}

fail(nil: ref R, msg: string)
{
	raise "re:" + msg;
}

quote(c: int): string
{
	if(c < 16r20 || c >= 16r7F)
		return sys->sprint("U+%.4X", c);
	return sys->sprint("'%c'", c);
}

# ---- characters ----

# the character at the current place, and how many code units it takes
# (in u mode a surrogate pair is one character); -1 at the end
peekc(r: ref R): (int, int)
{
	if(r.pos >= len r.s)
		return (-1, 0);
	c := r.s[r.pos];
	if(r.u && c >= 16rD800 && c <= 16rDBFF && r.pos + 1 < len r.s) {
		d := r.s[r.pos+1];
		if(d >= 16rDC00 && d <= 16rDFFF)
			return (16r10000 + ((c - 16rD800) << 10) + (d - 16rDC00), 2);
	}
	return (c, 1);
}

getc(r: ref R): int
{
	(c, w) := peekc(r);
	r.pos += w;
	return c;
}

at(r: ref R, c: int): int
{
	return r.pos < len r.s && r.s[r.pos] == c;
}

atstr(r: ref R, s: string): int
{
	return r.pos + len s <= len r.s && r.s[r.pos:r.pos + len s] == s;
}

eat(r: ref R, c: int): int
{
	if(at(r, c)) {
		r.pos++;
		return 1;
	}
	return 0;
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

issyntax(c: int): int
{
	case c {
	'^' or '$' or '\\' or '.' or '*' or '+' or '?' or '(' or ')' or '[' or ']' or '{' or '}' or '|' =>
		return 1;
	}
	return 0;
}

isletter(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

# ---- the scan for groups ----

scan(r: ref R)
{
	s := r.s;
	n := len s;
	depth := 0;	# class nesting (v mode nests)
	for(i := 0; i < n; i++) {
		c := s[i];
		if(c == '\\') {
			i++;
			continue;
		}
		if(depth > 0) {
			if(c == ']')
				depth--;
			else if(c == '[' && r.v)
				depth++;
			continue;
		}
		if(c == '[') {
			depth = 1;
			continue;
		}
		if(c != '(')
			continue;
		if(i + 1 < n && s[i+1] == '?') {
			if(i + 2 < n && s[i+2] == '<' && i + 3 < n && s[i+3] != '=' && s[i+3] != '!') {
				r.ngroups++;
				t := ref R(s, i + 3, r.u, r.v, 1, 0, nil, 0, nil);
				{
					r.allnames = groupname(t) :: r.allnames;
				} exception {
				"re:*" =>
					;	# reported when parsed
				}
			}
			continue;
		}
		r.ngroups++;
	}
}

# ---- disjunctions, alternatives, terms ----

# (the tree, the group names within it)
disjunction(r: ref R): (ref Re, list of string)
{
	alts: list of ref Re;
	names: list of string;
	for(;;) {
		(a, an) := alternative(r);
		alts = a :: alts;
		for(; an != nil; an = tl an)
			if(!has(names, hd an))
				names = hd an :: names;
		if(!eat(r, '|'))
			break;
	}
	if(tl alts == nil)
		return (hd alts, names);
	return (ref Re.Alt(rev(alts)), names);
}

alternative(r: ref R): (ref Re, list of string)
{
	items: list of ref Re;
	names: list of string;
	while(r.pos < len r.s && !at(r, '|') && !at(r, ')')) {
		(t, tn) := term(r);
		for(; tn != nil; tn = tl tn) {
			if(has(names, hd tn))
				fail(r, "group name " + hd tn + " twice in one alternative");
			names = hd tn :: names;
		}
		items = t :: items;
	}
	if(items == nil)
		return (ref Re.Empty, names);
	if(tl items == nil)
		return (hd items, names);
	return (ref Re.Seq(rev(items)), names);
}

has(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

rev(l: list of ref Re): array of ref Re
{
	a := array[len l] of ref Re;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

term(r: ref R): (ref Re, list of string)
{
	(c, nil) := peekc(r);
	case c {
	'^' =>
		r.pos++;
		noquant(r);
		return (ref Re.Assert(Abol), nil);
	'$' =>
		r.pos++;
		noquant(r);
		return (ref Re.Assert(Aeol), nil);
	'\\' =>
		if(atstr(r, "\\b") || atstr(r, "\\B")) {
			k := Aword;
			if(r.s[r.pos+1] == 'B')
				k = Anotword;
			r.pos += 2;
			noquant(r);
			return (ref Re.Assert(k), nil);
		}
	'(' =>
		if(atstr(r, "(?=") || atstr(r, "(?!") || atstr(r, "(?<=") || atstr(r, "(?<!")) {
			behind := r.s[r.pos+2] == '<';
			neg := r.s[r.pos+2+behind] == '!';
			r.pos += 3 + behind;
			(e, names) := disjunction(r);
			if(!eat(r, ')'))
				fail(r, "unterminated group");
			a: ref Re = ref Re.Look(behind, neg, e);
			# Annex B: a lookahead may be repeated, outside u mode
			if(behind || r.u)
				noquant(r);
			else
				a = quantifier(r, a);
			return (a, names);
		}
	}
	(a, names) := atom(r);
	return (quantifier(r, a), names);
}

# no quantifier may follow an assertion
noquant(r: ref R)
{
	(c, nil) := peekc(r);
	if(c == '*' || c == '+' || c == '?' || c == '{' && braced(r).t0)
		fail(r, "nothing to repeat");
}

# a {n}, {n,} or {n,m} here: (well-formed, n, m, length); m -1 for no limit
braced(r: ref R): (int, int, int, int)
{
	s := r.s;
	i := r.pos;
	if(i >= len s || s[i] != '{')
		return (0, 0, 0, 0);
	i++;
	(lo, j) := number(s, i);
	if(j == i)
		return (0, 0, 0, 0);
	i = j;
	hi := lo;
	if(i < len s && s[i] == ',') {
		i++;
		(hi, j) = number(s, i);
		if(j == i)
			hi = -1;
		i = j;
	}
	if(i >= len s || s[i] != '}')
		return (0, 0, 0, 0);
	return (1, lo, hi, i + 1 - r.pos);
}

# decimal digits at s[i]: (value, where they end); values are clamped
number(s: string, i: int): (int, int)
{
	v := 0;
	while(i < len s && isdigit(s[i])) {
		if(v < 16r7FFFFFFF / 10)
			v = v * 10 + s[i] - '0';
		else
			v = 16r7FFFFFFF;
		i++;
	}
	return (v, i);
}

quantifier(r: ref R, a: ref Re): ref Re
{
	min, max: int;
	(c, nil) := peekc(r);
	case c {
	'*' =>
		min = 0;
		max = -1;
		r.pos++;
	'+' =>
		min = 1;
		max = -1;
		r.pos++;
	'?' =>
		min = 0;
		max = 1;
		r.pos++;
	'{' =>
		(ok, lo, hi, n) := braced(r);
		if(!ok) {
			if(r.u)
				fail(r, "incomplete quantifier");
			return a;
		}
		if(hi >= 0 && lo > hi)
			fail(r, "numbers out of order in {} quantifier");
		min = lo;
		max = hi;
		r.pos += n;
	* =>
		return a;
	}
	greedy := !eat(r, '?');
	return ref Re.Repeat(min, max, greedy, a);
}

# ---- atoms ----

atom(r: ref R): (ref Re, list of string)
{
	(c, w) := peekc(r);
	case c {
	'.' =>
		r.pos++;
		return (ref Re.Any, nil);
	'(' =>
		return group(r);
	'[' =>
		r.pos++;
		return (class(r), nil);
	'\\' =>
		r.pos++;
		return (atomescape(r), nil);
	'*' or '+' or '?' =>
		fail(r, "nothing to repeat");
	'{' =>
		if(r.u)
			fail(r, "lone {");
		if(braced(r).t0)
			fail(r, "nothing to repeat");
	'}' =>
		if(r.u)
			fail(r, "lone }");
	']' =>
		if(r.u)
			fail(r, "lone ]");
	}
	r.pos += w;
	return (ref Re.Char(c), nil);
}

group(r: ref R): (ref Re, list of string)
{
	r.pos++;	# (
	if(eat(r, '?')) {
		if(eat(r, ':')) {
			(e, names) := disjunction(r);
			if(!eat(r, ')'))
				fail(r, "unterminated group");
			return (ref Re.Mod(0, 0, e), names);
		}
		if(eat(r, '<')) {
			name := groupname(r);
			r.group++;
			n := r.group;
			r.names[n] = name;
			(e, names) := disjunction(r);
			if(!eat(r, ')'))
				fail(r, "unterminated group");
			if(has(names, name))
				fail(r, "group name " + name + " twice in one alternative");
			return (ref Re.Group(n, name, e), name :: names);
		}
		return modifiers(r);
	}
	r.group++;
	n := r.group;
	(e, names) := disjunction(r);
	if(!eat(r, ')'))
		fail(r, "unterminated group");
	return (ref Re.Group(n, nil, e), names);
}

# (?ims-ims: ...), after the ?
modifiers(r: ref R): (ref Re, list of string)
{
	add := 0;
	rem := 0;
	minus := 0;
	for(;;) {
		if(r.pos >= len r.s)
			fail(r, "invalid group");
		c := r.s[r.pos++];
		b := 0;
		case c {
		'i' => b = Fi;
		'm' => b = Fm;
		's' => b = Fs;
		'-' =>
			if(minus)
				fail(r, "invalid group modifiers");
			minus = 1;
			continue;
		':' =>
			if(minus && add == 0 && rem == 0)
				fail(r, "empty group modifiers");
			(e, names) := disjunction(r);
			if(!eat(r, ')'))
				fail(r, "unterminated group");
			return (ref Re.Mod(add, rem, e), names);
		* =>
			fail(r, "invalid group");
		}
		if((add | rem) & b)
			fail(r, "repeated group modifier");
		if(minus)
			rem |= b;
		else
			add |= b;
	}
}

# a group name up to and past its >: identifier characters, which may be
# written as \u escapes (always with u's escapes) or surrogate pairs
groupname(r: ref R): string
{
	name := "";
	first := 1;
	for(;;) {
		if(r.pos >= len r.s)
			fail(r, "unterminated group name");
		c := r.s[r.pos];
		if(c == '>') {
			r.pos++;
			break;
		}
		if(c == '\\') {
			r.pos++;
			if(!eat(r, 'u'))
				fail(r, "invalid group name");
			c = unicodeescape(r, 1);
			if(c < 0)
				fail(r, "invalid group name");
		} else {
			r.pos++;
			if(c >= 16rD800 && c <= 16rDBFF && r.pos < len r.s && r.s[r.pos] >= 16rDC00 && r.s[r.pos] <= 16rDFFF) {
				c = 16r10000 + ((c - 16rD800) << 10) + (r.s[r.pos] - 16rDC00);
				r.pos++;
			}
		}
		if(first && !jslex->isidstart(c) || !first && !jslex->isidpart(c))
			fail(r, "invalid group name");
		name = putcp(name, c);
		first = 0;
	}
	if(name == nil)
		fail(r, "empty group name");
	return name;
}

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

# after \u: XXXX, a pair of \uXXXX surrogates, or (in u mode) {X...};
# the code point, or -1 if malformed (r.pos is then unchanged)
unicodeescape(r: ref R, u: int): int
{
	s := r.s;
	st := r.pos;
	if(u && at(r, '{')) {
		r.pos++;
		v := 0;
		nd := 0;
		while(r.pos < len s && (h := hexval(s[r.pos])) >= 0) {
			v = v * 16 + h;
			if(v > 16r10FFFF) {
				r.pos = st;
				return -1;
			}
			r.pos++;
			nd++;
		}
		if(nd == 0 || !eat(r, '}')) {
			r.pos = st;
			return -1;
		}
		return v;
	}
	v := hex4(s, r.pos);
	if(v < 0)
		return -1;
	r.pos += 4;
	if(u && v >= 16rD800 && v <= 16rDBFF && r.pos + 6 <= len s && s[r.pos] == '\\' && s[r.pos+1] == 'u') {
		w := hex4(s, r.pos + 2);
		if(w >= 16rDC00 && w <= 16rDFFF) {
			r.pos += 6;
			return 16r10000 + ((v - 16rD800) << 10) + (w - 16rDC00);
		}
	}
	return v;
}

hex4(s: string, i: int): int
{
	if(i + 4 > len s)
		return -1;
	v := 0;
	for(j := i; j < i + 4; j++) {
		h := hexval(s[j]);
		if(h < 0)
			return -1;
		v = v * 16 + h;
	}
	return v;
}

# after a \ outside a class
atomescape(r: ref R): ref Re
{
	if(r.pos >= len r.s)
		fail(r, "\\ at end of pattern");
	c := r.s[r.pos];
	if(c >= '1' && c <= '9') {
		st := r.pos;
		(n, e) := number(r.s, r.pos);
		if(n <= r.ngroups) {
			r.pos = e;
			return ref Re.Backref(n, nil);
		}
		if(r.u)
			fail(r, "backreference to a group that does not exist");
		r.pos = st;	# Annex B: an octal escape, or \8 \9 themselves
	}
	if(c == 'k' && r.n) {
		r.pos++;
		if(!eat(r, '<'))
			fail(r, "invalid named reference");
		name := groupname(r);
		if(!has(r.allnames, name))
			fail(r, "reference to group " + name + ", which does not exist");
		return ref Re.Backref(0, name);
	}
	if(k := classesc(c)) {
		r.pos++;
		return ref Re.Class(0, ref Set(Ounion, one(ref Item.Esc(k - 1))));
	}
	if((c == 'p' || c == 'P') && r.u) {
		r.pos++;
		it := property(r, c == 'P');
		return ref Re.Class(0, ref Set(Ounion, one(it)));
	}
	ch := charescape(r, 0);
	return ref Re.Char(ch);
}

# a class escape letter: its kind, plus one; 0 for none
classesc(c: int): int
{
	case c {
	'd' => return Cdigit + 1;
	'D' => return Cnotdigit + 1;
	's' => return Cspace + 1;
	'S' => return Cnotspace + 1;
	'w' => return Cword + 1;
	'W' => return Cnotword + 1;
	}
	return 0;
}

# a character escape after \ (r.pos at the letter); inclass: in a
# legacy class, where \c may take a digit or _
charescape(r: ref R, inclass: int): int
{
	s := r.s;
	c := s[r.pos];
	case c {
	'f' => r.pos++; return 16r0C;
	'n' => r.pos++; return '\n';
	'r' => r.pos++; return '\r';
	't' => r.pos++; return '\t';
	'v' => r.pos++; return 16r0B;
	'c' =>
		if(r.pos + 1 < len s) {
			d := s[r.pos+1];
			if(isletter(d) || inclass && !r.u && (isdigit(d) || d == '_')) {
				r.pos += 2;
				return d % 32;
			}
		}
		if(r.u)
			fail(r, "invalid \\c escape");
		return '\\';	# Annex B: the \ itself, and c follows
	'0' =>
		if(r.pos + 1 >= len s || !isdigit(s[r.pos+1])) {
			r.pos++;
			return 0;
		}
		if(r.u)
			fail(r, "invalid decimal escape");
		return octal(r);
	'1' to '7' =>
		if(r.u)
			fail(r, "invalid escape");
		return octal(r);
	'x' =>
		r.pos++;
		if(r.pos + 2 <= len s && hexval(s[r.pos]) >= 0 && hexval(s[r.pos+1]) >= 0) {
			v := hexval(s[r.pos]) * 16 + hexval(s[r.pos+1]);
			r.pos += 2;
			return v;
		}
		if(r.u)
			fail(r, "invalid \\x escape");
		return 'x';
	'u' =>
		r.pos++;
		v := unicodeescape(r, r.u);
		if(v >= 0)
			return v;
		if(r.u)
			fail(r, "invalid unicode escape");
		return 'u';
	}
	# an identity escape
	(ch, w) := peekc(r);
	if(r.u) {
		if(!issyntax(ch) && ch != '/' && !(inclass && ch == '-'))
			fail(r, "invalid escape");
	} else if(ch == 'k' && r.n)
		fail(r, "invalid escape");
	r.pos += w;
	return ch;
}

# Annex B: \0 to \377
octal(r: ref R): int
{
	s := r.s;
	v := s[r.pos++] - '0';
	if(r.pos < len s && s[r.pos] >= '0' && s[r.pos] <= '7') {
		v = v * 8 + s[r.pos++] - '0';
		if(v < 32 && r.pos < len s && s[r.pos] >= '0' && s[r.pos] <= '7')
			v = v * 8 + s[r.pos++] - '0';
	}
	return v;
}

# \p{...} after the p; neg: \P
property(r: ref R, neg: int): ref Item
{
	if(!eat(r, '{'))
		fail(r, "invalid property name");
	st := r.pos;
	while(r.pos < len r.s && (isletter(r.s[r.pos]) || isdigit(r.s[r.pos]) || r.s[r.pos] == '_'))
		r.pos++;
	name := r.s[st:r.pos];
	value: string;
	if(eat(r, '=')) {
		vs := r.pos;
		while(r.pos < len r.s && (isletter(r.s[r.pos]) || isdigit(r.s[r.pos]) || r.s[r.pos] == '_'))
			r.pos++;
		value = r.s[vs:r.pos];
		if(value == nil)
			fail(r, "invalid property name");
	}
	if(!eat(r, '}') || name == nil)
		fail(r, "invalid property name");
	if(value != nil) {
		case name {
		"General_Category" or "gc" =>
			if(!lookup(gcnames, value))
				fail(r, "invalid property value " + value);
		"Script" or "sc" or "Script_Extensions" or "scx" =>
			if(!lookup(scnames, value))
				fail(r, "invalid property value " + value);
		* =>
			fail(r, "invalid property name " + name);
		}
	} else if(!lookup(gcnames, name) && !lookup(binnames, name)) {
		if(!r.v || !lookup(strnames, name))
			fail(r, "invalid property name " + name);
		if(neg)
			fail(r, "negated property of strings");
	}
	return ref Item.Prop(neg, name, value);
}

lookup(t: array of string, s: string): int
{
	lo := 0;
	hi := len t;
	while(lo < hi) {
		m := (lo + hi) / 2;
		if(s < t[m])
			hi = m;
		else if(s > t[m])
			lo = m + 1;
		else
			return 1;
	}
	return 0;
}

# ---- classes ----

# after the [
class(r: ref R): ref Re
{
	neg := eat(r, '^');
	if(r.v) {
		(set, strs) := classset(r);
		if(neg && strs)
			fail(r, "negated class that may contain strings");
		return ref Re.Class(neg, set);
	}
	items: list of ref Item;
	for(;;) {
		if(r.pos >= len r.s)
			fail(r, "unterminated character class");
		if(eat(r, ']'))
			break;
		a := classatom(r);
		if(at(r, '-') && r.pos + 1 < len r.s && r.s[r.pos+1] != ']') {
			r.pos++;
			b := classatom(r);
			pick x := a {
			Range =>
				pick y := b {
				Range =>
					if(x.lo > y.lo)
						fail(r, "range out of order in character class");
					items = ref Item.Range(x.lo, y.lo) :: items;
					continue;
				}
			}
			# a class escape at either end: an error, or in a legacy
			# pattern both ends and the - (Annex B)
			if(r.u)
				fail(r, "invalid character class range");
			items = b :: ref Item.Range('-', '-') :: a :: items;
			continue;
		}
		items = a :: items;
	}
	return ref Re.Class(neg, ref Set(Ounion, revitems(items)));
}

one(it: ref Item): array of ref Item
{
	a := array[1] of ref Item;
	a[0] = it;
	return a;
}

revitems(l: list of ref Item): array of ref Item
{
	a := array[len l] of ref Item;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# one character (as a Range of itself) or class escape, in a legacy or u class
classatom(r: ref R): ref Item
{
	c := getc(r);
	if(c != '\\')
		return ref Item.Range(c, c);
	if(r.pos >= len r.s)
		fail(r, "\\ at end of pattern");
	d := r.s[r.pos];
	if(d == 'b') {
		r.pos++;
		return ref Item.Range(8, 8);
	}
	if(r.u && d == '-') {
		r.pos++;
		return ref Item.Range('-', '-');
	}
	if(k := classesc(d)) {
		r.pos++;
		return ref Item.Esc(k - 1);
	}
	if((d == 'p' || d == 'P') && r.u) {
		r.pos++;
		return property(r, d == 'P');
	}
	if(isdigit(d) && d != '0' && r.u)
		fail(r, "invalid class escape");
	if(d >= '8' && !r.u && isdigit(d)) {
		r.pos++;
		return ref Item.Range(d, d);
	}
	ch := charescape(r, 1);
	return ref Item.Range(ch, ch);
}

# ---- v-mode class sets ----

# the contents of a v-mode class, up to and past its ]: (set, whether it may contain strings)
classset(r: ref R): (ref Set, int)
{
	if(eat(r, ']'))
		return (ref Set(Ounion, nil), 0);
	(first, fs, firstchar) := operand(r);
	if(atstr(r, "&&") || atstr(r, "--")) {
		op := Ointer;
		ops := "&&";
		if(r.s[r.pos] == '-') {
			op = Osub;
			ops = "--";
		}
		items := first :: nil;
		strs := fs;
		while(atstr(r, ops)) {
			r.pos += 2;
			if(op == Ointer && at(r, '&'))
				fail(r, "invalid set operation");
			(it, s, nil) := operand(r);
			items = it :: items;
			if(op == Ointer)
				strs = strs && s;
		}
		if(!eat(r, ']')) {
			if(atstr(r, "&&") || atstr(r, "--"))
				fail(r, "mixed set operations without brackets");
			fail(r, "invalid set operation");
		}
		return (ref Set(op, revitems(items)), strs);
	}
	# a union, of operands and ranges
	items: list of ref Item;
	strs := fs;
	prev := first;
	prevchar := firstchar;
	for(;;) {
		if(at(r, '-') && !atstr(r, "--")) {
			if(!prevchar)
				fail(r, "invalid character class range");
			r.pos++;
			(hi, nil, ischar) := operand(r);
			if(!ischar)
				fail(r, "invalid character class range");
			pick x := prev {
			Range =>
				pick y := hi {
				Range =>
					if(x.lo > y.lo)
						fail(r, "range out of order in character class");
					prev = ref Item.Range(x.lo, y.lo);
				}
			}
			prevchar = 0;
			continue;
		}
		items = prev :: items;
		if(eat(r, ']'))
			break;
		if(r.pos >= len r.s)
			fail(r, "unterminated character class");
		if(atstr(r, "&&") || atstr(r, "--"))
			fail(r, "mixed set operations without brackets");
		s: int;
		(prev, s, prevchar) = operand(r);
		strs = strs || s;
	}
	return (ref Set(Ounion, revitems(items)), strs);
}

# a v-mode operand: (item, may contain strings, is a single character)
operand(r: ref R): (ref Item, int, int)
{
	if(r.pos >= len r.s)
		fail(r, "unterminated character class");
	if(eat(r, '[')) {
		neg := eat(r, '^');
		(set, strs) := classset(r);
		if(neg && strs)
			fail(r, "negated class that may contain strings");
		return (ref Item.Nested(neg, set), strs && !neg, 0);
	}
	if(at(r, '\\') && r.pos + 1 < len r.s) {
		d := r.s[r.pos+1];
		if(k := classesc(d)) {
			r.pos += 2;
			return (ref Item.Esc(k - 1), 0, 0);
		}
		if(d == 'p' || d == 'P') {
			r.pos += 2;
			it := property(r, d == 'P');
			strs := 0;
			pick p := it {
			Prop =>
				strs = p.value == nil && lookup(strnames, p.name);
			}
			return (it, strs, 0);
		}
		if(d == 'q') {
			r.pos += 2;
			if(!eat(r, '{'))
				fail(r, "invalid escape");
			return qstrings(r);
		}
	}
	c := setchar(r);
	return (ref Item.Range(c, c), 0, 1);
}

# \q{a|bc|...} after the {
qstrings(r: ref R): (ref Item, int, int)
{
	l: list of string;
	s := "";
	strs := 0;
	n := 0;
	for(;;) {
		if(r.pos >= len r.s)
			fail(r, "unterminated class string disjunction");
		if(at(r, '}') || at(r, '|')) {
			if(n != 1)
				strs = 1;
			l = s :: l;
			s = "";
			n = 0;
			if(eat(r, '}'))
				break;
			r.pos++;
			continue;
		}
		s = putcp(s, setchar(r));
		n++;
	}
	a := array[len l] of string;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return (ref Item.Strs(a), strs, 0);
}

# a single character in a v-mode class
setchar(r: ref R): int
{
	(c, w) := peekc(r);
	if(r.pos + 1 < len r.s && r.s[r.pos+1] == c && isdoublepunct(c))
		fail(r, "invalid set operation");
	case c {
	'(' or ')' or '[' or ']' or '{' or '}' or '/' or '-' or '|' =>
		fail(r, "invalid character in character class: " + quote(c));
	'\\' =>
		r.pos++;
		if(r.pos >= len r.s)
			fail(r, "\\ at end of pattern");
		d := r.s[r.pos];
		if(d == 'b') {
			r.pos++;
			return 8;
		}
		if(isreservedpunct(d)) {
			r.pos++;
			return d;
		}
		if(isdigit(d) && d != '0')
			fail(r, "invalid class escape");
		return charescape(r, 1);
	}
	r.pos += w;
	return c;
}

isdoublepunct(c: int): int
{
	case c {
	'&' or '!' or '#' or '$' or '%' or '*' or '+' or ',' or '.' or ':' or ';' or '<' or '=' or '>' or '?' or '@' or '^' or '`' or '~' =>
		return 1;
	}
	return 0;
}

isreservedpunct(c: int): int
{
	case c {
	'&' or '-' or '!' or '#' or '%' or ',' or ':' or ';' or '<' or '=' or '>' or '@' or '`' or '~' =>
		return 1;
	}
	return 0;
}

# ---- property names ----

# General_Category values and their aliases (Unicode 17.0, PropertyValueAliases.txt)
gcnames := array[] of {
	"C", "Cased_Letter", "Cc", "Cf", "Close_Punctuation", "Cn", "Co",
	"Combining_Mark", "Connector_Punctuation", "Control", "Cs",
	"Currency_Symbol", "Dash_Punctuation", "Decimal_Number", "Enclosing_Mark",
	"Final_Punctuation", "Format", "Initial_Punctuation", "L", "LC", "Letter",
	"Letter_Number", "Line_Separator", "Ll", "Lm", "Lo", "Lowercase_Letter",
	"Lt", "Lu", "M", "Mark", "Math_Symbol", "Mc", "Me", "Mn",
	"Modifier_Letter", "Modifier_Symbol", "N", "Nd", "Nl", "No",
	"Nonspacing_Mark", "Number", "Open_Punctuation", "Other", "Other_Letter",
	"Other_Number", "Other_Punctuation", "Other_Symbol", "P",
	"Paragraph_Separator", "Pc", "Pd", "Pe", "Pf", "Pi", "Po", "Private_Use",
	"Ps", "Punctuation", "S", "Sc", "Separator", "Sk", "Sm", "So",
	"Space_Separator", "Spacing_Mark", "Surrogate", "Symbol",
	"Titlecase_Letter", "Unassigned", "Uppercase_Letter", "Z", "Zl", "Zp",
	"Zs", "cntrl", "digit", "punct"
};

# Script values and their aliases (Unicode 17.0, PropertyValueAliases.txt)
scnames := array[] of {
	"Adlam", "Adlm", "Aghb", "Ahom", "Anatolian_Hieroglyphs", "Arab",
	"Arabic", "Armenian", "Armi", "Armn", "Avestan", "Avst", "Bali",
	"Balinese", "Bamu", "Bamum", "Bass", "Bassa_Vah", "Batak", "Batk", "Beng",
	"Bengali", "Berf", "Beria_Erfe", "Bhaiksuki", "Bhks", "Bopo", "Bopomofo",
	"Brah", "Brahmi", "Brai", "Braille", "Bugi", "Buginese", "Buhd", "Buhid",
	"Cakm", "Canadian_Aboriginal", "Cans", "Cari", "Carian",
	"Caucasian_Albanian", "Chakma", "Cham", "Cher", "Cherokee", "Chorasmian",
	"Chrs", "Common", "Copt", "Coptic", "Cpmn", "Cprt", "Cuneiform",
	"Cypriot", "Cypro_Minoan", "Cyrillic", "Cyrl", "Deseret", "Deva",
	"Devanagari", "Diak", "Dives_Akuru", "Dogr", "Dogra", "Dsrt", "Dupl",
	"Duployan", "Egyp", "Egyptian_Hieroglyphs", "Elba", "Elbasan", "Elym",
	"Elymaic", "Ethi", "Ethiopic", "Gara", "Garay", "Geor", "Georgian",
	"Glag", "Glagolitic", "Gong", "Gonm", "Goth", "Gothic", "Gran", "Grantha",
	"Greek", "Grek", "Gujarati", "Gujr", "Gukh", "Gunjala_Gondi", "Gurmukhi",
	"Guru", "Gurung_Khema", "Han", "Hang", "Hangul", "Hani",
	"Hanifi_Rohingya", "Hano", "Hanunoo", "Hatr", "Hatran", "Hebr", "Hebrew",
	"Hira", "Hiragana", "Hluw", "Hmng", "Hmnp", "Hrkt", "Hung",
	"Imperial_Aramaic", "Inherited", "Inscriptional_Pahlavi",
	"Inscriptional_Parthian", "Ital", "Java", "Javanese", "Kaithi", "Kali",
	"Kana", "Kannada", "Katakana", "Katakana_Or_Hiragana", "Kawi", "Kayah_Li",
	"Khar", "Kharoshthi", "Khitan_Small_Script", "Khmer", "Khmr", "Khoj",
	"Khojki", "Khudawadi", "Kirat_Rai", "Kits", "Knda", "Krai", "Kthi",
	"Lana", "Lao", "Laoo", "Latin", "Latn", "Lepc", "Lepcha", "Limb", "Limbu",
	"Lina", "Linb", "Linear_A", "Linear_B", "Lisu", "Lyci", "Lycian", "Lydi",
	"Lydian", "Mahajani", "Mahj", "Maka", "Makasar", "Malayalam", "Mand",
	"Mandaic", "Mani", "Manichaean", "Marc", "Marchen", "Masaram_Gondi",
	"Medefaidrin", "Medf", "Meetei_Mayek", "Mend", "Mende_Kikakui", "Merc",
	"Mero", "Meroitic_Cursive", "Meroitic_Hieroglyphs", "Miao", "Mlym",
	"Modi", "Mong", "Mongolian", "Mro", "Mroo", "Mtei", "Mult", "Multani",
	"Myanmar", "Mymr", "Nabataean", "Nag_Mundari", "Nagm", "Nand",
	"Nandinagari", "Narb", "Nbat", "New_Tai_Lue", "Newa", "Nko", "Nkoo",
	"Nshu", "Nushu", "Nyiakeng_Puachue_Hmong", "Ogam", "Ogham", "Ol_Chiki",
	"Ol_Onal", "Olck", "Old_Hungarian", "Old_Italic", "Old_North_Arabian",
	"Old_Permic", "Old_Persian", "Old_Sogdian", "Old_South_Arabian",
	"Old_Turkic", "Old_Uyghur", "Onao", "Oriya", "Orkh", "Orya", "Osage",
	"Osge", "Osma", "Osmanya", "Ougr", "Pahawh_Hmong", "Palm", "Palmyrene",
	"Pau_Cin_Hau", "Pauc", "Perm", "Phag", "Phags_Pa", "Phli", "Phlp", "Phnx",
	"Phoenician", "Plrd", "Prti", "Psalter_Pahlavi", "Qaac", "Qaai", "Rejang",
	"Rjng", "Rohg", "Runic", "Runr", "Samaritan", "Samr", "Sarb", "Saur",
	"Saurashtra", "Sgnw", "Sharada", "Shavian", "Shaw", "Shrd", "Sidd",
	"Siddham", "Sidetic", "Sidt", "SignWriting", "Sind", "Sinh", "Sinhala",
	"Sogd", "Sogdian", "Sogo", "Sora", "Sora_Sompeng", "Soyo", "Soyombo",
	"Sund", "Sundanese", "Sunu", "Sunuwar", "Sylo", "Syloti_Nagri", "Syrc",
	"Syriac", "Tagalog", "Tagb", "Tagbanwa", "Tai_Le", "Tai_Tham", "Tai_Viet",
	"Tai_Yo", "Takr", "Takri", "Tale", "Talu", "Tamil", "Taml", "Tang",
	"Tangsa", "Tangut", "Tavt", "Tayo", "Telu", "Telugu", "Tfng", "Tglg",
	"Thaa", "Thaana", "Thai", "Tibetan", "Tibt", "Tifinagh", "Tirh",
	"Tirhuta", "Tnsa", "Todhri", "Todr", "Tolong_Siki", "Tols", "Toto",
	"Tulu_Tigalari", "Tutg", "Ugar", "Ugaritic", "Unknown", "Vai", "Vaii",
	"Vith", "Vithkuqi", "Wancho", "Wara", "Warang_Citi", "Wcho", "Xpeo",
	"Xsux", "Yezi", "Yezidi", "Yi", "Yiii", "Zanabazar_Square", "Zanb",
	"Zinh", "Zyyy", "Zzzz"
};

# binary properties and their aliases (ECMA-262, table of binary Unicode properties)
binnames := array[] of {
	"AHex", "ASCII", "ASCII_Hex_Digit", "Alpha", "Alphabetic", "Any",
	"Assigned", "Bidi_C", "Bidi_Control", "Bidi_M", "Bidi_Mirrored", "CI",
	"CWCF", "CWCM", "CWKCF", "CWL", "CWT", "CWU", "Case_Ignorable", "Cased",
	"Changes_When_Casefolded", "Changes_When_Casemapped",
	"Changes_When_Lowercased", "Changes_When_NFKC_Casefolded",
	"Changes_When_Titlecased", "Changes_When_Uppercased", "DI", "Dash",
	"Default_Ignorable_Code_Point", "Dep", "Deprecated", "Dia", "Diacritic",
	"EBase", "EComp", "EMod", "EPres", "Emoji", "Emoji_Component",
	"Emoji_Modifier", "Emoji_Modifier_Base", "Emoji_Presentation", "Ext",
	"ExtPict", "Extended_Pictographic", "Extender", "Gr_Base", "Gr_Ext",
	"Grapheme_Base", "Grapheme_Extend", "Hex", "Hex_Digit", "IDC", "IDS",
	"IDSB", "IDST", "IDS_Binary_Operator", "IDS_Trinary_Operator",
	"ID_Continue", "ID_Start", "Ideo", "Ideographic", "Join_C",
	"Join_Control", "LOE", "Logical_Order_Exception", "Lower", "Lowercase",
	"Math", "NChar", "Noncharacter_Code_Point", "Pat_Syn", "Pat_WS",
	"Pattern_Syntax", "Pattern_White_Space", "QMark", "Quotation_Mark", "RI",
	"Radical", "Regional_Indicator", "SD", "STerm", "Sentence_Terminal",
	"Soft_Dotted", "Term", "Terminal_Punctuation", "UIdeo",
	"Unified_Ideograph", "Upper", "Uppercase", "VS", "Variation_Selector",
	"White_Space", "XIDC", "XIDS", "XID_Continue", "XID_Start", "space"
};

# properties of strings, in v mode only (ECMA-262)
strnames := array[] of {
	"Basic_Emoji", "Emoji_Keycap_Sequence", "RGI_Emoji",
	"RGI_Emoji_Flag_Sequence", "RGI_Emoji_Modifier_Sequence",
	"RGI_Emoji_Tag_Sequence", "RGI_Emoji_ZWJ_Sequence"
};

