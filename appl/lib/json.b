implement JSON;

#
# Javascript `Object' Notation (JSON): RFC4627
#

include "sys.m";
	sys: Sys;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "json.m";

init(b: Bufio)
{
	sys = load Sys Sys->PATH;
	bufio = b;
}

jvarray(a: array of ref JValue): ref JValue.Array
{
	return ref JValue.Array(a);
}

jvbig(i: big): ref JValue.Int
{
	return ref JValue.Int(i);
}

jvfalse(): ref JValue.False
{
	return ref JValue.False;
}

jvint(i: int): ref JValue.Int
{
	return ref JValue.Int(big i);
}

jvnull(): ref JValue.Null
{
	return ref JValue.Null;
}

jvobject(m: list of (string, ref JValue)): ref JValue.Object
{
	# could `uniq' the labels
	return ref JValue.Object(m);
}

jvreal(r: real): ref JValue.Real
{
	return ref JValue.Real(r);
}

jvstring(s: string): ref JValue.String
{
	return ref JValue.String(s);
}

jvtrue(): ref JValue.True
{
	return ref JValue.True;
}

Syntax: exception(string);
Badwrite: exception;

# How deep arrays and objects may nest.  readval calls itself for each
# level, and a document of nothing but '[' had it do so until memory
# ran out: an exception readjson does not catch, in whoever was reading.
Maxdepth: con 512;

readjson(fd: ref Iobuf): (ref JValue, string)
{
	{
		p := Parse.mk(fd);
		c := p.getns();
		if(c == Bufio->EOF)
			return (nil, nil);
		p.unget(c);
		return (readval(p), nil);
	}exception e{
	Syntax =>
		return (nil, sys->sprint("JSON syntax error (offset %bd): %s", fd.offset(), e));
	}
}

writejson(fd: ref Iobuf, val: ref JValue): int
{
	{
		writeval(fd, val);
		return 0;
	}exception{
	Badwrite =>
		return -1;
	}
}

#
# value ::= string | number | object | array | 'true' | 'false' | 'null'
#
readval(p: ref Parse): ref JValue raises(Syntax)
{
	{
		while((c := p.getc()) == ' ' || c == '\t' || c == '\n' || c == '\r')
			{}
		if(c < 0){
			if(c == Bufio->EOF)
				raise Syntax("unexpected end-of-input");
			raise Syntax(sys->sprint("read error: %r"));
		}
		case c {
		'{' =>
			# object ::= '{' [pair (',' pair)*] '}'
			if(++p.depth > Maxdepth)
				raise Syntax("nested too deep");
			l:  list of (string, ref JValue);
			if((c = p.getns()) != '}'){
				p.unget(c);
				rl: list of (string, ref JValue);
				do{
					# pair ::= string ':' value
					c = p.getns();
					if(c != '"')
						raise Syntax("missing member name");
					name := readstring(p, c);
					if(p.getns() != ':')
						raise Syntax("missing ':'");
					rl = (name, readval(p)) :: rl;
				}while((c = p.getns()) == ',');
				for(; rl != nil; rl = tl rl)
					l = hd rl :: l;
			}
			if(c != '}')
				raise Syntax("missing '}' at end of object");
			p.depth--;
			return ref JValue.Object(l);
		'[' =>
			#	array ::= '[' [value (',' value)*] ']'
			if(++p.depth > Maxdepth)
				raise Syntax("nested too deep");
			l: list of ref JValue;
			n := 0;
			if((c = p.getns()) != ']'){
				p.unget(c);
				do{
					l = readval(p) :: l;
					n++;
				}while((c = p.getns()) == ',');
			}
			if(c != ']')
				raise Syntax("missing ']' at end of array");			
			a := array[n] of ref JValue;
			for(; --n >= 0; l = tl l)
				a[n] = hd l;
			p.depth--;
			return ref JValue.Array(a);
		'"' =>
			return ref JValue.String(readstring(p, c));
		'-' or '0' to '9' =>
			#	number ::=	int frac? exp?
			#	int ::= '-'? [0-9] | [1-9][0-9]+
			#	frac ::= '.' [0-9]+
			#	exp ::= [eE][-+]? [0-9]+
			if(c == '-')
				intp := "-";
			else
				p.unget(c);
			intp += readdigits(p);		# we don't enforce the absence of leading zeros
			fracp: string;
			c = p.getc();
			if(c == '.'){
				fracp = readdigits(p);
				c = p.getc();
			}
			exp := "";
			if(c == 'e' || c == 'E'){
				exp[0] = c;
				c = p.getc();
				if(c == '-' || c == '+')
					exp[1] = c;
				else
					p.unget(c);
				exp += readdigits(p);
			}else
				p.unget(c);
			if(fracp != nil || exp != nil)
				return ref JValue.Real(real (intp+"."+fracp+exp));
			# An integer that does not fit a big is a real: the
			# conversion gave the largest big for any of them, with
			# no error, a number the sender had not written.
			if(!fitsbig(intp))
				return ref JValue.Real(real intp);
			return ref JValue.Int(big intp);
		'a' to 'z' =>
			# 'true' | 'false' | 'null'
			s: string;
			do{
				s[len s] = c;
			}while((c = p.getc()) >= 'a' && c <= 'z');
			p.unget(c);
			case s {
			"true" =>	return ref JValue.True();
			"false" =>	return ref JValue.False();
			"null" =>	return ref JValue.Null();
			* =>	raise Syntax("invalid literal: "+s);
			}
		* =>
			raise Syntax(sys->sprint("unexpected character #%.4ux", c));
		}
	}exception{
	Syntax =>
		raise;
	}
}

# whether the digits of s, with or without a sign, are a big's
fitsbig(s: string): int
{
	neg := 0;
	i := 0;
	if(len s > 0 && s[0] == '-'){
		neg = 1;
		i = 1;
	}
	while(i < len s - 1 && s[i] == '0')
		i++;
	d := s[i:];
	if(len d != 19)
		return len d < 19;
	lim := "9223372036854775807";
	if(neg)
		lim = "9223372036854775808";
	return d <= lim;	# the same length: as strings, as numbers
}

# string ::= '"' char* '"'
# char ::= [^\x00-\x1F"\\] | '\"' | '\/' | '\b' | '\f' | '\n' | '\r' | '\t' | '\u' hex hex hex hex
readstring(p: ref Parse, delim: int): string raises(Syntax)
{
	{
		s := "";
	Str:
		while((c := p.getc()) != delim && c >= 0){
			if(c == '\\'){
				c = p.getc();
				if(c < 0)
					break;
				if(c != 'u')
					c = unesc(c);
				else{
					c = hex4(p);
					# A character past U+FFFF is written as two, and
					# the pair is the one character.  Half of one alone
					# is no character: it was kept as it came, and was
					# bytes that are not UTF-8 when written again.
					while(c >= 16rD800 && c <= 16rDBFF){
						c1 := p.getc();
						if(c1 != '\\'){
							p.unget(c1);
							c = Sys->UTFerror;
							break;
						}
						c2 := p.getc();
						if(c2 < 0){
							c = c2;
							break Str;
						}
						if(c2 != 'u'){
							s[len s] = Sys->UTFerror;
							c = unesc(c2);
							break;
						}
						lo := hex4(p);
						if(lo >= 16rDC00 && lo <= 16rDFFF){
							c = 16r10000 + ((c - 16rD800) << 10) + (lo - 16rDC00);
							break;
						}
						s[len s] = Sys->UTFerror;
						c = lo;	# which may be the first half of another
					}
					if(c >= 16rDC00 && c <= 16rDFFF)
						c = Sys->UTFerror;
				}
			}
			s[len s] = c;
		}
		if(c < 0){
			if(c == Bufio->ERROR)
				raise Syntax(sys->sprint("read error: %r"));
			raise Syntax("unterminated string");
		}
		return s;
	}exception{
	Syntax =>
		raise;
	}
}

# the character after a backslash that is not 'u'
unesc(c: int): int
{
	case c {
	'b' =>	return '\b';
	'f' =>	return '\f';
	'n' =>	return '\n';
	'r' =>	return '\r';
	't' =>	return '\t';
	}
	return c;	# itself, including '"', '/', and '\'
}

# four hex digits
hex4(p: ref Parse): int raises(Syntax)
{
	{
		c := 0;
		for(i := 0; i < 4; i++)
			c = (c<<4) | hex(p.getc());
		return c;
	}exception{
	Syntax =>
		raise;
	}
}

# hex ::= [0-9a-fA-F]
hex(c: int): int raises(Syntax)
{
	case c {
	'0' to '9' =>
		return c-'0';
	'a' to 'f' =>
		return 10+(c-'a');
	'A' to 'F' =>
		return 10+(c-'A');
	* =>
		raise Syntax("invalid hex digit");
	}
}

# digits ::= [0-9]+
readdigits(p: ref Parse): string raises(Syntax)
{
	c := p.getc();
	if(!(c >= '0' && c <= '9'))
		raise Syntax("expected integer literal");
	s := "";
	s[0] = c;
	while((c = p.getc()) >= '0' && c <= '9')
		s[len s] = c;
	p.unget(c);
	return s;
}

writeval(out: ref Iobuf, o: ref JValue) raises(Badwrite)
{
	{
		if(o == nil){
			puts(out, "null");
			return;
		}
		pick r := o {
		String =>
			writestring(out, r.s);
		Int =>
			puts(out, r.text());
		Real =>
			# JSON has no infinity and no NaN
			rs := realtext(r.value);
			if(rs == nil)
				raise Badwrite;
			puts(out, rs);
		Object =>	# '{' [pair (',' pair)*] '}'
			putc(out, '{');
			for(l := r.mem; l != nil; l = tl l){
				if(l != r.mem)
					putc(out, ',');
				(n, v) := hd l;
				writestring(out, n);
				putc(out, ':');
				writeval(out, v);
			}
			putc(out, '}');
		Array =>	# '[' [value (',' value)*] ']'
			putc(out, '[');
			for(i := 0; i < len r.a; i++){
				if(i != 0)
					putc(out, ',');
				writeval(out, r.a[i]);
			}
			putc(out, ']');
		True =>
			puts(out, "true");
		False =>
			puts(out, "false");
		Null =>
			puts(out, "null");
		* =>
			raise "writeval: unknown value";	# can't happen
		}
	}exception{
	Badwrite =>
		raise;
	}
}

writestring(out: ref Iobuf, s: string) raises(Badwrite)
{
	{
		putc(out, '"');
		for(i := 0; i < len s; i++){
			c := s[i];
			if(needesc(c))
				puts(out, escout(c));
			else
				putc(out, c);
		}
		putc(out, '"');
	}exception{
	Badwrite =>
		raise;
	}
}

escout(c: int): string
{
	case c {
	'"' =>		return "\\\"";
	'\\' =>	return "\\\\";
	'/' =>	return "\\/";
	'\b' =>	return "\\b";
	'\f' =>	return "\\f";
	'\n' =>	return "\\n";
	'\t' =>	return "\\t";
	'\r' =>	return "\\r";
	* =>		return sys->sprint("\\u%.4ux", c);
	}
}

puts(out: ref Iobuf, s: string) raises(Badwrite)
{
	if(out.puts(s) == Bufio->ERROR)
		raise Badwrite;
}

putc(out: ref Iobuf, c: int) raises(Badwrite)
{
	if(out.putc(c) == Bufio->ERROR)
		raise Badwrite;
}

Parse: adt {
	input:	ref Iobuf;
	eof:		int;
	depth:	int;

	mk:		fn(io: ref Iobuf): ref Parse;
	getc:		fn(nil: self ref Parse): int;
	unget:	fn(nil: self ref Parse, c: int);
	getns:	fn(nil: self ref Parse): int;
};

Parse.mk(io: ref Iobuf): ref Parse
{
	return ref Parse(io, 0, 0);
}

Parse.getc(p: self ref Parse): int
{
	if(p.eof)
		return p.eof;
	c := p.input.getc();
	if(c < 0)
		p.eof = c;
	return c;
}

Parse.unget(p: self ref Parse, c: int)
{
	if(c >= 0)
		p.input.ungetc();
}

# skip white space
Parse.getns(p: self ref Parse): int
{
	while((c := p.getc()) == ' ' || c == '\t' || c == '\n' || c == '\r')
		{}
	return c;
}

JValue.isarray(v: self ref JValue): int
{
	return tagof v == tagof JValue.Array;
}

JValue.isint(v: self ref JValue): int
{
	return tagof v == tagof JValue.Int;
}

JValue.isnumber(v: self ref JValue): int
{
	return tagof v == tagof JValue.Int || tagof v == tagof JValue.Real;
}

JValue.isobject(v: self ref JValue): int
{
	return tagof v == tagof JValue.Object;
}

JValue.isreal(v: self ref JValue): int
{
	return tagof v == tagof JValue.Real;
}

JValue.isstring(v: self ref JValue): int
{
	return tagof v == tagof JValue.String;
}

JValue.istrue(v: self ref JValue): int
{
	return tagof v == tagof JValue.True;
}

JValue.isfalse(v: self ref JValue): int
{
	return tagof v == tagof JValue.False;
}

JValue.isnull(v: self ref JValue): int
{
	return tagof v == tagof JValue.Null;
}

JValue.copy(v: self ref JValue): ref JValue
{
	pick r := v {
	True or False or Null =>
		return ref *r;
	Int =>
		return ref *r;
	Real =>
		return ref *r;
	String =>
		return ref *r;
	Array =>
		a := array[len r.a] of ref JValue;
		a[0:] = r.a;
		return ref JValue.Array(a);
	Object =>
		return ref *r;
	* =>
		raise "json: bad copy";	# can't happen
	}
}

JValue.eq(a: self ref JValue, b: ref JValue): int
{
	if(a == b)
		return 1;
	if(a == nil || b == nil || tagof a != tagof b)
		return 0;
	pick r := a {
	True or False or Null =>
		return 1;	# tags were equal above
	Int =>
		pick s := b {
		Int =>
			return r.value == s.value;
		}
	Real =>
		pick s := b {
		Real =>
			return r.value == s.value;
		}
	String =>
		pick s := b {
		String =>
			return r.s == s.s;
		}
	Array =>
		pick s := b {
		Array =>
			if(len r.a != len s.a)
				return 0;
			for(i := 0; i < len r.a; i++)
				if(r.a[i] == nil){
					if(s.a[i] != nil)
						return 0;
				}else if(!r.a[i].eq(s.a[i]))
					return 0;
			return 1;
		}
	Object =>
		pick s := b {
		Object =>
			ls := s.mem;
			for(lr := r.mem; lr != nil; lr = tl lr){
				if(ls == nil)
					return 0;
				(rn, rv) := hd lr;
				(sn, sv) := hd ls;
				if(rn != sn)
					return 0;
				if(rv == nil){
					if(sv != nil)
						return 0;
				}else if(!rv.eq(sv))
					return 0;
				ls = tl ls;
			}
			return ls == nil;
		}
	}
	return 0;
}

JValue.get(v: self ref JValue, mem: string): ref JValue
{
	pick r := v {
	Object =>
		for(l := r.mem; l != nil; l = tl l)
			if((hd l).t0 == mem)
				return (hd l).t1;
		return nil;
	* =>
		return nil;
	}
}

# might be better if the interface were applicative?
# this is similar to behaviour of Limbo's own ref adt, though
JValue.set(v: self ref JValue, mem: string, val: ref JValue)
{
	pick j := v {
	Object =>
		ol: list of (string, ref JValue);
		for(l := j.mem; l != nil; l = tl l)
			if((hd l).t0 == mem){
				l = tl l;
				for(; ol != nil; ol = tl ol)
					l = hd ol :: l;
				j.mem = l;
				return;
			}else
				ol = hd l :: ol;
		j.mem = (mem, val) :: j.mem;
	* =>
		raise "json: set non-object";
	}
}

JValue.text(v: self ref JValue): string
{
	if(v == nil)
		return "null";
	pick r := v {
	True =>
		return "true";
	False =>
		return "false";
	Null =>
		return "null";
	Int =>
		return string r.value;
	Real =>
		rs := realtext(r.value);
		if(rs == nil)
			return "null";
		return rs;
	String =>
		return quote(r.s);		# quoted, or not?
	Array =>
		s := "[";
		for(i := 0; i < len r.a; i++){
			if(i != 0)
				s += ", ";
			s += r.a[i].text();
		}
		return s+"]";
	Object =>
		s := "{";
		for(l := r.mem; l != nil; l = tl l){
			if(l != r.mem)
				s += ", ";
			s += quote((hd l).t0)+": "+(hd l).t1.text();
		}
		return s+"}";
	* =>
		return nil;
	}
}

Maxreal: con 1.7976931348623157e308;

# A real as JSON has it, in the fewest digits that read back as the
# same real, or nil if it is no number.  It was %f: six places, so 1e-7
# was written as 0.000000, and 1e300 as three hundred digits.
realtext(r: real): string
{
	# an infinity is past the largest real, and a NaN compares with nothing
	if(!(r >= -Maxreal && r <= Maxreal))
		return nil;
	s: string;
	for(prec := 15; prec <= 17; prec++){
		s = sys->sprint("%.*g", prec, r);
		if(real s == r)
			break;
	}
	# still a real to whoever reads it: "5" would be an integer
	for(i := 0; i < len s; i++)
		if(s[i] == '.' || s[i] == 'e' || s[i] == 'E')
			return s;
	return s + ".0";
}

quote(s: string): string
{
	ns := "\"";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(needesc(c))
			ns += escout(c);
		else
			ns[len ns] = c;
	}
	return ns+"\"";
}

needesc(c: int): int
{
	return c == '"' || c == '\\' || c == '/' || c <= 16r1F;  # '/' is escaped to prevent "</xyz>" looking like an XML end tag(!)
}
