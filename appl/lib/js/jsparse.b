implement Jsparse;

#
# JavaScript's syntactic grammar (ECMAScript 2025 §13-16), by recursive
# descent, to an ESTree-shaped tree.
#
# Where the grammar is ambiguous for a while, the expression is parsed
# first and reinterpreted once it is known, as the specification's cover
# grammars do: (a, b) before => becomes parameters, [a] before = a
# pattern.  The lexer lexes / as division; where an operand is due and
# a / is found, it is lexed again as a regular expression.  Likewise a
# } that ends a template substitution is lexed again as the template's
# next part.
#
# Errors of the grammar and of context (yield in a generator, a reserved
# word as a name, octal in strict code) are raised here; errors of
# binding and scope (a let declared twice, a label, a break with nothing
# to break) belong to the checks over the finished tree.
#

include "sys.m";
	sys: Sys;

include "jslex.m";
	jslex: Jslex;
	Lex, Tok, Teof, Tident, Tprivate, Tpunct, Tnum, Tbigint, Tstr, Ttemplate, Tregex: import jslex;

include "jsparse.m";

include "jscheck.m";
	jscheck: Jscheck;

include "jsre.m";
	jsre: Jsre;

P: adt {
	l:	ref Lex;
	t:	ref Tok;	# the current token
	prevend:	int;	# where the previous token ended
	ismod:	int;
	strict:	int;
	gen:	int;		# in a generator's body or parameters: yield is an operator
	async:	int;		# in an async function's: await is
	infunc:	int;		# return is allowed
	inparams:	int;	# in parameters: yield and await expressions are not
	yieldat, awaitat:	int;	# the first yield or await expression since the mark, or -1
	toplevelawait:	int;	# module top level: await is an operator
	inclassfield:	int;
	instaticblock:	int;
	sawstrict:	int;	# the last directive prologue had "use strict"
};

init()
{
	sys = load Sys Sys->PATH;
	jslex = load Jslex Jslex->PATH;
	jslex->init();
}

parse(src: string, ismod, strict: int): (ref Node, string)
{
	return parseeval0(src, ismod, strict, 0, nil, 0);
}

parseeval(src: string, strict, ctx: int, privnames: list of string): (ref Node, string)
{
	return parseeval0(src, 0, strict, ctx, privnames, 1);
}

parseeval0(src: string, ismod, strict, ctx: int, privnames: list of string, iseval: int): (ref Node, string)
{
	if(sys == nil)
		init();
	p := ref P(Lex.new(src, ismod), nil, 0, ismod, strict || ismod, 0, 0, 0, 0, -1, -1, ismod, 0, 0, 0);
	{
		if(iseval && (ctx & Efield))
			p.inclassfield = 1;
		next(p);
		body := stmtlist(p, 1, 1);
		if(p.t.kind != Teof)
			fail(p, p.t.pos, "unexpected " + desc(p.t));
		prog := ref Node.Program(0, len src, body, ismod, p.strict);
		if(jscheck == nil) {
			jscheck = load Jscheck Jscheck->PATH;
			if(jscheck == nil)
				return (nil, sys->sprint("cannot load %s: %r", Jscheck->PATH));
			jscheck->init();
		}
		(at, msg) := jscheck->checkeval(prog, ctx, privnames);
		if(msg != nil)
			return (nil, where(src, at) + ": " + msg);
		return (prog, nil);
	} exception e {
	"parse:*" =>
		return (nil, e[6:]);
	}
}

# ---- errors ----

fail(p: ref P, at: int, msg: string)
{
	raise "parse:" + where(p.l.src, at) + ": " + msg;
}

where(s: string, at: int): string
{
	line := 1;
	col := 1;
	for(i := 0; i < at && i < len s; i++)
		if(s[i] == '\n') {
			line++;
			col = 1;
		} else
			col++;
	return sys->sprint("%d:%d", line, col);
}

desc(t: ref Tok): string
{
	case t.kind {
	Teof => return "end of input";
	Tident => return "'" + t.s + "'";
	Tpunct => return "'" + t.s + "'";
	Tnum or Tbigint => return "number";
	Tstr => return "string";
	Ttemplate => return "template";
	Tregex => return "regular expression";
	Tprivate => return "#" + t.s;
	}
	return "token";
}

# ---- tokens ----

next(p: ref P)
{
	if(p.t != nil)
		p.prevend = p.t.end;
	p.t = p.l.next(0);
	if(p.l.err != nil)
		fail(p, p.l.errpos, p.l.err);
}

# the token after the current one, without moving
peek(p: ref P): ref Tok
{
	save := p.l.pos;
	t := p.l.next(0);
	p.l.pos = save;
	if(p.l.err != nil) {
		p.l.err = nil;
		return ref Tok(Teof, save, save, nil, 0.0, nil, 0, 0, 0, 0, 0, nil);
	}
	return t;
}

is(p: ref P, s: string): int
{
	return p.t.kind == Tpunct && p.t.s == s;
}

# an unescaped word: a keyword or contextual keyword
iskw(p: ref P, w: string): int
{
	return p.t.kind == Tident && !p.t.esc && p.t.s == w;
}

eat(p: ref P, s: string): int
{
	if(is(p, s)) {
		next(p);
		return 1;
	}
	return 0;
}

eatkw(p: ref P, w: string): int
{
	if(iskw(p, w)) {
		next(p);
		return 1;
	}
	return 0;
}

expect(p: ref P, s: string)
{
	if(!eat(p, s))
		fail(p, p.t.pos, "expected '" + s + "', found " + desc(p.t));
}

expectkw(p: ref P, w: string)
{
	if(!eatkw(p, w))
		fail(p, p.t.pos, "expected '" + w + "', found " + desc(p.t));
}

# a statement's end: a ; or where one may be inserted (§12.10)
semi(p: ref P)
{
	if(eat(p, ";"))
		return;
	if(is(p, "}") || p.t.kind == Teof || p.t.nlb)
		return;
	fail(p, p.t.pos, "expected ';', found " + desc(p.t));
}

# ---- names ----

strictreserved(s: string): int
{
	case s {
	"implements" or "interface" or "let" or "package" or "private" or "protected" or "public" or "static" or "yield" =>
		return 1;
	}
	return 0;
}

# whether the current token may be an identifier here (not consuming)
isidentok(p: ref P): int
{
	t := p.t;
	if(t.kind != Tident)
		return 0;
	s := t.s;
	case s {
	"yield" =>
		return !p.gen && !p.strict;
	"await" =>
		return !p.async && !p.ismod && !p.instaticblock;
	"let" or "static" or "implements" or "interface" or "package" or "private" or "protected" or "public" =>
		return !p.strict;
	}
	return !jslex->reserved(s);
}

# an identifier, checked for where it is; binding: it names a binding
ident(p: ref P, binding: int): ref Node
{
	t := p.t;
	if(t.kind != Tident)
		fail(p, t.pos, "expected an identifier, found " + desc(t));
	s := t.s;
	if(jslex->reserved(s) && s != "yield" && s != "await")
		fail(p, t.pos, sys->sprint("'%s' is reserved", s));
	if(s == "yield" && (p.gen || p.strict))
		fail(p, t.pos, "'yield' is reserved here");
	if(s == "await" && (p.async || p.ismod || p.instaticblock))
		fail(p, t.pos, "'await' is reserved here");
	if(s == "await" && p.inparams && p.async)
		fail(p, t.pos, "'await' in async parameters");
	if(p.strict && strictreserved(s))
		fail(p, t.pos, sys->sprint("'%s' is reserved in strict code", s));
	if(binding && p.strict && (s == "eval" || s == "arguments"))
		fail(p, t.pos, sys->sprint("cannot bind '%s' in strict code", s));
	if(p.inclassfield && s == "arguments")
		fail(p, t.pos, "'arguments' in a class field");
	next(p);
	return ref Node.Ident(t.pos, t.end, s);
}

# a property name: any identifier name, a string, a number, [computed] or #private
# (key, computed)
propname(p: ref P, privok: int): (ref Node, int)
{
	t := p.t;
	case t.kind {
	Tident =>
		next(p);
		return (ref Node.Ident(t.pos, t.end, t.s), 0);
	Tstr =>
		next(p);
		if(p.strict && t.esc)
			fail(p, t.pos, "octal escape in strict code");
		return (ref Node.Str(t.pos, t.end, t.s), 0);
	Tnum =>
		next(p);
		if(p.strict && t.octal)
			fail(p, t.pos, "octal literal in strict code");
		return (ref Node.Num(t.pos, t.end, t.n), 0);
	Tbigint =>
		next(p);
		return (ref Node.BigInt(t.pos, t.end, t.s), 0);
	Tprivate =>
		if(!privok)
			fail(p, t.pos, "private name outside a class");
		next(p);
		return (ref Node.Private(t.pos, t.end, t.s), 0);
	Tpunct =>
		if(t.s == "[") {
			next(p);
			e := assign(p, 0);
			expect(p, "]");
			return (e, 1);
		}
	}
	fail(p, t.pos, "expected a property name, found " + desc(t));
	return (nil, 0);
}

# ---- statements ----

# statements to the end of a block (or the input); dirs: a directive prologue may begin it
stmtlist(p: ref P, top: int, dirs: int): array of ref Node
{
	l: list of ref Node;
	prologue := dirs;
	usestrict := 0;
	while(p.t.kind != Teof && !is(p, "}")) {
		if(prologue) {
			if(p.t.kind == Tstr) {
				st := p.t;
				s := stmtitem(p, top);
				pick x := s {
				Expr =>
					pick e := x.e {
					Str =>
						if(e.pos == st.pos && e.end == st.end) {
							raw := p.l.src[st.pos+1:st.end-1];
							x.directive = raw;
							if(raw == "use strict") {
								usestrict = 1;
								if(!p.strict)
									checkoctals(p, l);
								p.strict = 1;
							}
							l = s :: l;
							continue;
						}
					}
				}
				prologue = 0;
				l = s :: l;
				continue;
			}
			prologue = 0;
		}
		l = stmtitem(p, top) :: l;
	}
	if(dirs)
		p.sawstrict = usestrict;
	return rev(l);
}

# the strings of a directive prologue before "use strict" are strict too:
# an octal escape in one of them is an error (§12.9.4.1)
checkoctals(p: ref P, l: list of ref Node)
{
	src := p.l.src;
	for(; l != nil; l = tl l)
		pick x := hd l {
		Expr =>
			if(x.directive != nil) {
				lx := Lex.new(src[x.e.pos:x.e.end], 0);
				t := lx.next(0);
				if(t.kind == Tstr && t.esc)
					fail(p, x.e.pos, "octal escape in strict code");
			}
		}
}

# a statement or declaration
stmtitem(p: ref P, top: int): ref Node
{
	t := p.t;
	if(t.kind == Tident && !t.esc) {
		case t.s {
		"function" =>
			return function(p, 1, 0, t.pos);
		"class" =>
			return class(p, 1);
		"const" =>
			return vardecl(p, Kconst, 1);
		"let" =>
			if(letdecl(p))
				return vardecl(p, Klet, 1);
		"async" =>
			n := peek(p);
			if(n.kind == Tident && !n.esc && n.s == "function" && !n.nlb) {
				next(p);
				return function(p, 1, 1, t.pos);
			}
		"import" =>
			n := peek(p);
			if(!(n.kind == Tpunct && (n.s == "(" || n.s == "."))) {
				if(!p.ismod || top != 1)
					fail(p, t.pos, "import declaration outside a module's top level");
				return importdecl(p);
			}
		"export" =>
			if(!p.ismod || top != 1)
				fail(p, t.pos, "export declaration outside a module's top level");
			return exportdecl(p);
		"using" =>
			if(usingstart(p, 0)) {
				usingplace(p, top, t.pos);
				return vardecl(p, Kusing, 1);
			}
		"await" =>
			if(awaitusingstart(p, 0)) {
				usingplace(p, top, t.pos);
				pos := t.pos;
				next(p);
				d := vardecl(p, Kawaitusing, 1);
				d.pos = pos;
				return d;
			}
		}
	}
	return stmt(p, 1);
}

# whether using here begins a declaration: using x, on one line;
# forhead: in a for's head, where using of is the name using
usingstart(p: ref P, forhead: int): int
{
	n := peek(p);
	if(n.kind != Tident || n.nlb)
		return 0;
	if(!n.esc && (n.s == "in" || n.s == "instanceof"))
		return 0;
	if(forhead && !n.esc && n.s == "of") {
		# for (using of = e;;) declares of; for (using of e) iterates e
		save := p.l.pos;
		p.l.next(0);
		n2 := p.l.next(0);
		p.l.pos = save;
		p.l.err = nil;
		return n2.kind == Tpunct && (n2.s == "=" || n2.s == ";" || n2.s == ",");
	}
	return 1;
}

# whether await here begins await using x, on one line, where await is an operator
awaitusingstart(p: ref P, nil: int): int
{
	if(!p.async && !p.toplevelawait)
		return 0;
	save := p.l.pos;
	n1 := p.l.next(0);
	n2 := p.l.next(0);
	p.l.pos = save;
	if(p.l.err != nil) {
		p.l.err = nil;
		return 0;
	}
	if(n1.kind != Tident || n1.esc || n1.s != "using" || n1.nlb)
		return 0;
	if(n2.kind != Tident || n2.nlb)
		return 0;
	if(!n2.esc && (n2.s == "in" || n2.s == "instanceof"))
		return 0;
	return 1;
}

# using declarations are not at a script's top level, nor directly in a case
usingplace(p: ref P, top, at: int)
{
	if(top == 1 && !p.ismod)
		fail(p, at, "using declaration at a script's top level");
	if(top == 2)
		fail(p, at, "using declaration in a case clause");
}

# whether a let here begins a declaration (else it is an identifier)
letdecl(p: ref P): int
{
	n := peek(p);
	if(n.kind == Tpunct && (n.s == "[" || n.s == "{"))
		return 1;
	if(n.kind == Tident) {
		if(n.nlb && (n.s == "in" || n.s == "instanceof" || n.s == "of"))
			return 0;
		if(!n.esc && (n.s == "in" || n.s == "instanceof"))
			return 0;
		return 1;
	}
	return 0;
}

# a statement (not a declaration); labelled: the body of a label, where
# a function declaration is allowed in sloppy code
stmt(p: ref P, labelled: int): ref Node
{
	t := p.t;
	pos := t.pos;
	if(t.kind == Tpunct) {
		case t.s {
		"{" =>
			return block(p);
		";" =>
			next(p);
			return ref Node.Empty(pos, p.prevend);
		}
	}
	if(t.kind == Tident && !t.esc) {
		case t.s {
		"var" =>
			return vardecl(p, Kvar, 1);
		"if" =>
			next(p);
			expect(p, "(");
			test := expr(p, 0);
			expect(p, ")");
			cons := substmt(p);
			els: ref Node;
			if(eatkw(p, "else"))
				els = substmt(p);
			return ref Node.If(pos, p.prevend, test, cons, els);
		"for" =>
			return forstmt(p);
		"while" =>
			next(p);
			expect(p, "(");
			test := expr(p, 0);
			expect(p, ")");
			body := stmt(p, 0);
			return ref Node.While(pos, p.prevend, test, body);
		"do" =>
			next(p);
			body := stmt(p, 0);
			expectkw(p, "while");
			expect(p, "(");
			test := expr(p, 0);
			expect(p, ")");
			eat(p, ";");	# (always inserted after do-while, §12.10.1)
			return ref Node.DoWhile(pos, p.prevend, body, test);
		"continue" or "break" =>
			next(p);
			label: string;
			if(p.t.kind == Tident && !p.t.nlb && !(iskw(p, "yield") && p.gen) && !(iskw(p, "await") && (p.async || p.ismod))) {
				label = p.t.s;
				ident(p, 0);
			}
			semi(p);
			if(t.s == "break")
				return ref Node.Break(pos, p.prevend, label);
			return ref Node.Continue(pos, p.prevend, label);
		"return" =>
			if(!p.infunc)
				fail(p, pos, "return outside a function");
			next(p);
			arg: ref Node;
			if(!is(p, ";") && !is(p, "}") && p.t.kind != Teof && !p.t.nlb)
				arg = expr(p, 0);
			semi(p);
			return ref Node.Return(pos, p.prevend, arg);
		"with" =>
			if(p.strict)
				fail(p, pos, "with in strict code");
			next(p);
			expect(p, "(");
			obj := expr(p, 0);
			expect(p, ")");
			body := stmt(p, 0);
			return ref Node.With(pos, p.prevend, obj, body);
		"switch" =>
			return switchstmt(p);
		"throw" =>
			next(p);
			if(p.t.nlb)
				fail(p, p.t.pos, "line break after throw");
			arg := expr(p, 0);
			semi(p);
			return ref Node.Throw(pos, p.prevend, arg);
		"try" =>
			return trystmt(p);
		"debugger" =>
			next(p);
			semi(p);
			return ref Node.Debugger(pos, p.prevend);
		"function" =>
			if(!labelled || p.strict)
				fail(p, pos, "function declaration in statement position");
			n := peek(p);
			if(n.kind == Tpunct && n.s == "*")
				fail(p, pos, "labelled generator declaration");
			return function(p, 1, 0, pos);
		"class" or "const" =>
			fail(p, pos, "declaration in statement position");
		"let" =>
			n := peek(p);
			if(n.kind == Tpunct && n.s == "[")
				fail(p, pos, "let [ cannot begin a statement");
		"async" =>
			n := peek(p);
			if(n.kind == Tident && !n.esc && n.s == "function" && !n.nlb)
				fail(p, pos, "async function declaration in statement position");
		"import" =>
			n := peek(p);
			if(!(n.kind == Tpunct && (n.s == "(" || n.s == ".")))
				fail(p, pos, "import declaration in statement position");
		"export" =>
			fail(p, pos, "export declaration in statement position");
		}
	}
	# an expression statement, or a labelled statement
	if(is(p, "{") || iskw(p, "function") || iskw(p, "class"))
		fail(p, pos, "unexpected " + desc(t));
	e := expr(p, 0);
	pick id := e {
	Ident =>
		if(is(p, ":") && e.end == p.prevend && t.kind == Tident) {
			next(p);
			body := stmt(p, labelled);
			return ref Node.Labeled(pos, p.prevend, id.name, body);
		}
	}
	semi(p);
	return ref Node.Expr(pos, p.prevend, e, nil);
}

# the body of if, else, while, for, with: a statement; in sloppy code an
# if may have a function declaration (Annex B.3.3)
substmt(p: ref P): ref Node
{
	if(iskw(p, "function") && !p.strict) {
		n := peek(p);
		if(!(n.kind == Tpunct && n.s == "*"))
			return function(p, 1, 0, p.t.pos);
	}
	return stmt(p, 0);
}

block(p: ref P): ref Node
{
	pos := p.t.pos;
	expect(p, "{");
	body := stmtlist(p, 0, 0);
	expect(p, "}");
	return ref Node.Block(pos, p.prevend, body);
}

# var, let or const and its declarators; full: the whole statement (with its ;)
vardecl(p: ref P, kind: int, full: int): ref Node
{
	pos := p.t.pos;
	next(p);
	decls := vardecls(p, kind, 0, full);
	if(full)
		semi(p);
	return ref Node.Var(pos, p.prevend, kind, decls);
}

vardecls(p: ref P, kind: int, noin: int, needinit: int): array of ref Node
{
	l: list of ref Node;
	for(;;) {
		pos := p.t.pos;
		id := bindingtarget(p);
		pick x := id {
		Ident =>
			if(kind != Kvar && x.name == "let")
				fail(p, pos, "let cannot name a lexical binding");
		* =>
			if(kind == Kusing || kind == Kawaitusing)
				fail(p, pos, "a using declaration binds names, not patterns");
		}
		init: ref Node;
		if(eat(p, "="))
			init = assign(p, noin);
		else if(needinit) {
			if(kind != Kvar && kind != Klet)
				fail(p, p.t.pos, "declaration without an initialiser");
			pick x := id {
			Ident =>
				;
			* =>
				fail(p, p.t.pos, "destructuring declaration without an initialiser");
			}
		}
		l = ref Node.Decl(pos, p.prevend, id, init) :: l;
		if(!eat(p, ","))
			break;
	}
	return rev(l);
}

# a binding name or pattern
bindingtarget(p: ref P): ref Node
{
	if(is(p, "[") || is(p, "{")) {
		pos := p.t.pos;
		e := primary(p);
		return topattern(p, e, 1, pos);
	}
	return ident(p, 1);
}

forstmt(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	await := 0;
	if(iskw(p, "await")) {
		if(!p.async && !p.toplevelawait)
			fail(p, p.t.pos, "for await outside an async function");
		next(p);
		await = 1;
	}
	expect(p, "(");
	init: ref Node;
	if(is(p, ";")) {
		if(await)
			fail(p, p.t.pos, "for await needs of");
	} else {
		ipos := p.t.pos;
		kind := -1;
		if(iskw(p, "var"))
			kind = Kvar;
		else if(iskw(p, "const"))
			kind = Kconst;
		else if(iskw(p, "let")) {
			n := peek(p);
			if(n.kind == Tpunct && (n.s == "[" || n.s == "{") || n.kind == Tident && !(n.s == "in" && !n.esc) && !(n.s == "of" && !n.esc))
				kind = Klet;
		} else if(iskw(p, "using") && usingstart(p, 1))
			kind = Kusing;
		else if(iskw(p, "await") && awaitusingstart(p, 1)) {
			kind = Kawaitusing;
			next(p);
		}
		if(kind >= 0) {
			next(p);
			decls := vardecls(p, kind, 1, 0);
			init = ref Node.Var(ipos, p.prevend, kind, decls);
			if(iskw(p, "of") || iskw(p, "in")) {
				isof := iskw(p, "of");
				if(len decls != 1)
					fail(p, ipos, "for-in/of with more than one binding");
				if(!isof && (kind == Kusing || kind == Kawaitusing))
					fail(p, ipos, "for-in with a using declaration");
				if(declinit(decls[0]) != nil) {
					# Annex B.3.5: for (var x = e in o) in sloppy code
					if(isof || p.strict || kind != Kvar || !simpleident(decls[0]))
						fail(p, ipos, "for-in/of binding with an initialiser");
				}
				return forinof(p, pos, init, isof, await);
			}
			if(await)
				fail(p, p.t.pos, "for await needs of");
			for(i := 0; i < len decls; i++)
				if(declinit(decls[i]) == nil) {
					if(kind != Kvar && kind != Klet)
						fail(p, decls[i].pos, "declaration without an initialiser");
					pick x := decls[i] {
					Decl =>
						pick y := x.id {
						Ident =>
							;
						* =>
							fail(p, decls[i].pos, "destructuring declaration without an initialiser");
						}
					}
				}
		} else {
			startsasync := iskw(p, "async");
			startslet := iskw(p, "let");
			e := expr(p, 1);
			if(iskw(p, "of") || iskw(p, "in")) {
				isof := iskw(p, "of");
				if(isof && startslet)
					fail(p, ipos, "for (let of ...)");
				if(isof && startsasync && !await) {
					pick x := e {
					Ident =>
						if(x.name == "async")
							fail(p, ipos, "for (async of ...)");
					}
				}
				target := toassigntarget(p, e, ipos);
				return forinof(p, pos, target, isof, await);
			}
			if(await)
				fail(p, p.t.pos, "for await needs of");
			init = e;
		}
	}
	expect(p, ";");
	test: ref Node;
	if(!is(p, ";"))
		test = expr(p, 0);
	expect(p, ";");
	update: ref Node;
	if(!is(p, ")"))
		update = expr(p, 0);
	expect(p, ")");
	body := stmt(p, 0);
	return ref Node.For(pos, p.prevend, init, test, update, body);
}

declinit(d: ref Node): ref Node
{
	pick x := d {
	Decl =>
		return x.init;
	}
	return nil;
}

simpleident(d: ref Node): int
{
	pick x := d {
	Decl =>
		pick y := x.id {
		Ident =>
			return 1;
		}
	}
	return 0;
}

forinof(p: ref P, pos: int, left: ref Node, isof, await: int): ref Node
{
	next(p);
	right: ref Node;
	if(isof)
		right = assign(p, 0);
	else
		right = expr(p, 0);
	expect(p, ")");
	body := stmt(p, 0);
	if(isof)
		return ref Node.ForOf(pos, p.prevend, left, right, body, await);
	return ref Node.ForIn(pos, p.prevend, left, right, body);
}

switchstmt(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	expect(p, "(");
	disc := expr(p, 0);
	expect(p, ")");
	expect(p, "{");
	cases: list of ref Node;
	seendefault := 0;
	while(!eat(p, "}")) {
		cpos := p.t.pos;
		test: ref Node;
		if(eatkw(p, "case"))
			test = expr(p, 0);
		else if(eatkw(p, "default")) {
			if(seendefault)
				fail(p, cpos, "two defaults in a switch");
			seendefault = 1;
		} else
			fail(p, p.t.pos, "expected case or default, found " + desc(p.t));
		expect(p, ":");
		body: list of ref Node;
		while(!iskw(p, "case") && !iskw(p, "default") && !is(p, "}") && p.t.kind != Teof)
			body = stmtitem(p, 2) :: body;
		cases = ref Node.Case(cpos, p.prevend, test, rev(body)) :: cases;
	}
	return ref Node.Switch(pos, p.prevend, disc, rev(cases));
}

trystmt(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	blk := block(p);
	param, handler, final: ref Node;
	if(eatkw(p, "catch")) {
		if(eat(p, "(")) {
			param = bindingtarget(p);
			expect(p, ")");
		}
		handler = block(p);
	}
	if(eatkw(p, "finally"))
		final = block(p);
	if(handler == nil && final == nil)
		fail(p, p.t.pos, "try without catch or finally");
	return ref Node.Try(pos, p.prevend, blk, param, handler, final);
}

# ---- functions ----

# function [*] [name] (params) { body }; at is where it began (async before it)
function(p: ref P, decl, async, at: int): ref Node
{
	next(p);	# function
	gen := eat(p, "*");
	id: ref Node;
	if(p.t.kind == Tident && !is(p, "(")) {
		# a declaration's name is bound in the enclosing scope, under
		# its rules; an expression's in its own, under the function's
		og := p.gen;
		oa := p.async;
		osb := p.instaticblock;
		if(!decl) {
			p.gen = gen;
			p.async = async;
			p.instaticblock = 0;
		}
		id = ident(p, 1);
		p.gen = og;
		p.async = oa;
		p.instaticblock = osb;
	} else if(decl)
		fail(p, p.t.pos, "function declaration without a name");
	flags := 0;
	if(gen)
		flags |= Fgen;
	if(async)
		flags |= Fasync;
	if(decl)
		flags |= Fdecl;
	return funcrest(p, at, id, flags);
}

# (params) { body }, in the function's own context
funcrest(p: ref P, at: int, id: ref Node, flags: int): ref Node
{
	saved := *p;
	p.gen = flags & Fgen;
	p.async = flags & Fasync;
	p.infunc = 1;
	p.toplevelawait = 0;
	p.inclassfield = 0;
	p.instaticblock = 0;
	(params, simple) := formals(p);
	if(simple)
		flags |= Fsimple;
	expect(p, "{");
	body := stmtlist(p, 0, 1);
	expect(p, "}");
	if(p.strict) {
		flags |= Fstrict;
		if(p.sawstrict && !simple)
			fail(p, at, "\"use strict\" in a function with non-simple parameters");
		strictparams(p, id, params);
	}
	if(p.strict || !simple || flags & (Fmethod | Farrow))
		dupparams(p, params);
	end := p.prevend;
	restore(p, saved);
	return ref Node.Func(at, end, id, params, body, flags);
}

# the context of an enclosing function, back (keeping the lexer's place)
restore(p: ref P, saved: P)
{
	p.strict = saved.strict;
	p.gen = saved.gen;
	p.async = saved.async;
	p.infunc = saved.infunc;
	p.inparams = saved.inparams;
	p.toplevelawait = saved.toplevelawait;
	p.inclassfield = saved.inclassfield;
	p.instaticblock = saved.instaticblock;
}

# (a, b = 1, [c], ...d): (params, whether all are plain names)
formals(p: ref P): (array of ref Node, int)
{
	expect(p, "(");
	op := p.inparams;
	p.inparams = 1;
	l: list of ref Node;
	simple := 1;
	while(!is(p, ")")) {
		pos := p.t.pos;
		if(eat(p, "...")) {
			arg := bindingtarget(p);
			l = ref Node.Rest(pos, p.prevend, arg) :: l;
			simple = 0;
			if(!is(p, ")"))
				fail(p, p.t.pos, "a rest parameter must be last");
			break;
		}
		t := bindingtarget(p);
		pick x := t {
		Ident =>
			;
		* =>
			simple = 0;
		}
		if(eat(p, "=")) {
			d := assign(p, 0);
			t = ref Node.AssignPat(pos, p.prevend, t, d);
			simple = 0;
		}
		l = t :: l;
		if(!eat(p, ","))
			break;
	}
	expect(p, ")");
	p.inparams = op;
	return (rev(l), simple);
}

# in strict code no parameter or function name is eval or arguments, or a strict reserved word
strictparams(p: ref P, id: ref Node, params: array of ref Node)
{
	if(id != nil)
		pick x := id {
		Ident =>
			strictname(p, x.name, x.pos);
		}
	for(l := boundnames(params, nil); l != nil; l = tl l)
		strictname(p, (hd l).t0, (hd l).t1);
}

strictname(p: ref P, s: string, at: int)
{
	if(s == "eval" || s == "arguments")
		fail(p, at, sys->sprint("cannot bind '%s' in strict code", s));
	if(strictreserved(s))
		fail(p, at, sys->sprint("'%s' is reserved in strict code", s));
}

dupparams(p: ref P, params: array of ref Node)
{
	names := boundnames(params, nil);
	for(l := names; l != nil; l = tl l)
		for(m := tl l; m != nil; m = tl m)
			if((hd l).t0 == (hd m).t0)
				fail(p, (hd l).t1, sys->sprint("duplicate parameter '%s'", (hd l).t0));
}

# the names a pattern binds, with where
boundnames(a: array of ref Node, acc: list of (string, int)): list of (string, int)
{
	for(i := 0; i < len a; i++)
		acc = bound(a[i], acc);
	return acc;
}

bound(n: ref Node, acc: list of (string, int)): list of (string, int)
{
	if(n == nil)
		return acc;
	pick x := n {
	Ident =>
		return (x.name, x.pos) :: acc;
	AssignPat =>
		return bound(x.target, acc);
	Rest =>
		return bound(x.arg, acc);
	ArrayPat =>
		return boundnames(x.elems, acc);
	ObjectPat =>
		for(i := 0; i < len x.props; i++) {
			pick pr := x.props[i] {
			Prop =>
				acc = bound(pr.value, acc);
			Rest =>
				acc = bound(pr.arg, acc);
			}
		}
		return acc;
	}
	return acc;
}

# an arrow function from its parameters' cover (already parsed) to its body
arrow(p: ref P, at: int, params: array of ref Node, async, noin: int): ref Node
{
	if(p.t.nlb)
		fail(p, p.t.pos, "line break before =>");
	expect(p, "=>");
	saved := *p;
	p.async = async;
	p.gen = 0;
	p.infunc = 1;
	p.toplevelawait = 0;
	p.instaticblock = 0;
	simple := 1;
	for(i := 0; i < len params; i++)
		pick x := params[i] {
		Ident =>
			;
		* =>
			simple = 0;
		}
	flags := Farrow;
	if(async)
		flags |= Fasync;
	if(simple)
		flags |= Fsimple;
	body: array of ref Node;
	if(is(p, "{")) {
		next(p);
		body = stmtlist(p, 0, 1);
		expect(p, "}");
	} else {
		bpos := p.t.pos;
		e := assign(p, noin);
		body = array[1] of ref Node;
		body[0] = ref Node.Return(bpos, p.prevend, e);
		flags |= Fexpr;
		p.sawstrict = 0;
	}
	if(p.strict) {
		flags |= Fstrict;
		if(p.sawstrict && !simple)
			fail(p, at, "\"use strict\" in a function with non-simple parameters");
		strictparams(p, nil, params);
	}
	dupparams(p, params);
	end := p.prevend;
	restore(p, saved);
	return ref Node.Func(at, end, nil, params, body, flags);
}

# ---- classes ----

class(p: ref P, decl: int): ref Node
{
	pos := p.t.pos;
	next(p);
	outerstrict := p.strict;
	p.strict = 1;	# all of a class is strict, its name too
	id: ref Node;
	if(p.t.kind == Tident && !iskw(p, "extends") && !is(p, "{"))
		id = ident(p, 1);
	else if(decl)
		fail(p, p.t.pos, "class declaration without a name");
	super: ref Node;
	if(eatkw(p, "extends"))
		super = lhs(p);
	expect(p, "{");
	members: list of ref Node;
	seenctor := 0;
	while(!eat(p, "}")) {
		if(eat(p, ";"))
			continue;
		m := member(p);
		pick x := m {
		Method =>
			if(x.kind == Pctor) {
				if(seenctor)
					fail(p, m.pos, "two constructors in a class");
				seenctor = 1;
			}
		}
		members = m :: members;
	}
	p.strict = outerstrict;
	return ref Node.Class(pos, p.prevend, id, super, rev(members), decl);
}

member(p: ref P): ref Node
{
	pos := p.t.pos;
	static := 0;
	if(iskw(p, "static")) {
		n := peek(p);
		if(!(n.kind == Tpunct && (n.s == "(" || n.s == "=" || n.s == ";" || n.s == "}")) && !(n.nlb && !(n.kind == Tpunct && (n.s == "[" || n.s == "{" || n.s == "*")) && n.kind != Tident && n.kind != Tstr && n.kind != Tnum && n.kind != Tprivate)) {
			next(p);
			static = 1;
			if(is(p, "{")) {
				# static { ... }: a block run when the class is made
				saved := *p;
				p.instaticblock = 1;
				p.async = 0;
				p.gen = 0;
				p.infunc = 0;
				p.inclassfield = 1;
				blk := block(p);
				restore(p, saved);
				return ref Node.Method(pos, p.prevend, nil, blk, Pblock, 0, 1);
			}
		}
	}
	kind := Pmethod;
	async := 0;
	gen := 0;
	if(iskw(p, "async")) {
		n := peek(p);
		if(!(n.kind == Tpunct && (n.s == "(" || n.s == "=" || n.s == ";" || n.s == "}")) && !n.nlb) {
			next(p);
			async = 1;
		}
	}
	if(eat(p, "*"))
		gen = 1;
	if(!async && !gen && (iskw(p, "get") || iskw(p, "set"))) {
		n := peek(p);
		if(!(n.kind == Tpunct && (n.s == "(" || n.s == "=" || n.s == ";" || n.s == "}" || n.s == "*" && n.nlb))) {
			if(p.t.s == "get")
				kind = Pget;
			else
				kind = Pset;
			next(p);
		}
	}
	kpos := p.t.pos;
	(key, computed) := propname(p, 1);
	keyname := "";
	if(!computed)
		pick k := key {
		Ident => keyname = k.name;
		Str => keyname = k.s;
		}
	isprivate := 0;
	pick k := key {
	Private =>
		isprivate = 1;
		if(k.name == "constructor")
			fail(p, kpos, "#constructor");
	}
	if(is(p, "(")) {
		if(!static && !computed && !isprivate && keyname == "constructor") {
			if(kind != Pmethod || async || gen)
				fail(p, kpos, "constructor that is a getter, setter, generator or async");
			kind = Pctor;
		}
		if(static && !computed && keyname == "prototype")
			fail(p, kpos, "static method named prototype");
		flags := Fmethod;
		if(gen)
			flags |= Fgen;
		if(async)
			flags |= Fasync;
		f := funcrest(p, kpos, nil, flags);
		accessorparams(p, kind, f, kpos);
		return ref Node.Method(pos, p.prevend, key, f, kind, computed, static);
	}
	# a field
	if(kind != Pmethod || async || gen)
		fail(p, p.t.pos, "expected '(' in a method");
	if(!computed && !isprivate && (keyname == "constructor" || static && keyname == "prototype"))
		fail(p, kpos, "field named " + keyname);
	init: ref Node;
	if(eat(p, "=")) {
		saved := *p;
		p.inclassfield = 1;
		p.async = 0;
		p.gen = 0;
		p.infunc = 0;
		p.toplevelawait = 0;
		init = assign(p, 0);
		restore(p, saved);
	}
	semi(p);
	return ref Node.Method(pos, p.prevend, key, init, Pfield, computed, static);
}

# a getter has no parameters, a setter exactly one (not a rest)
accessorparams(p: ref P, kind: int, f: ref Node, at: int)
{
	pick x := f {
	Func =>
		if(kind == Pget && len x.params != 0)
			fail(p, at, "getter with parameters");
		if(kind == Pset) {
			if(len x.params != 1)
				fail(p, at, "setter without exactly one parameter");
			pick r := x.params[0] {
			Rest =>
				fail(p, at, "setter with a rest parameter");
			}
		}
	}
}

# ---- modules ----

modname(p: ref P): string
{
	t := p.t;
	if(t.kind == Tstr) {
		next(p);
		if(!wellformed(t.s))
			fail(p, t.pos, "module export name is not well-formed Unicode");
		return t.s;
	}
	if(t.kind != Tident)
		fail(p, t.pos, "expected a name, found " + desc(t));
	next(p);
	return t.s;
}

# no lone surrogates
wellformed(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 16rD800 && s[i] <= 16rDFFF)
			return 0;
	return 1;
}

fromclause(p: ref P): string
{
	expectkw(p, "from");
	t := p.t;
	if(t.kind != Tstr)
		fail(p, t.pos, "expected a module specifier");
	next(p);
	withclause(p);
	return t.s;
}

# with { type: "json" }: import attributes
withclause(p: ref P)
{
	if(!iskw(p, "with") || p.t.nlb && 0)
		return;
	next(p);
	expect(p, "{");
	keys: list of string;
	while(!eat(p, "}")) {
		k: string;
		if(p.t.kind == Tstr || p.t.kind == Tident) {
			k = p.t.s;
			next(p);
		} else
			fail(p, p.t.pos, "expected an attribute key");
		for(l := keys; l != nil; l = tl l)
			if(hd l == k)
				fail(p, p.t.pos, "duplicate import attribute " + k);
		keys = k :: keys;
		expect(p, ":");
		if(p.t.kind != Tstr)
			fail(p, p.t.pos, "an import attribute's value is a string");
		next(p);
		if(!eat(p, ",")) {
			expect(p, "}");
			break;
		}
	}
}

importdecl(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	specs: list of ref Node;
	if(p.t.kind == Tstr) {
		src := p.t.s;
		next(p);
		withclause(p);
		semi(p);
		return ref Node.Import(pos, p.prevend, nil, src);
	}
	if(p.t.kind == Tident && !is(p, "{") && !is(p, "*")) {
		spos := p.t.pos;
		id := ident(p, 1);
		pick x := id {
		Ident =>
			specs = ref Node.ImportSpec(spos, p.prevend, Idefault, "default", x.name) :: specs;
		}
		if(!eat(p, ",")) {
			src := fromclause(p);
			semi(p);
			return ref Node.Import(pos, p.prevend, rev(specs), src);
		}
	}
	if(is(p, "*")) {
		spos := p.t.pos;
		next(p);
		expectkw(p, "as");
		id := ident(p, 1);
		pick x := id {
		Ident =>
			specs = ref Node.ImportSpec(spos, p.prevend, Inamespace, "*", x.name) :: specs;
		}
	} else if(eat(p, "{")) {
		while(!eat(p, "}")) {
			spos := p.t.pos;
			isstr := p.t.kind == Tstr;
			wordpos := p.t.pos;
			word := p.t;
			imported := modname(p);
			local := imported;
			if(eatkw(p, "as")) {
				id := ident(p, 1);
				pick x := id {
				Ident =>
					local = x.name;
				}
			} else {
				if(isstr)
					fail(p, wordpos, "a string import name needs as");
				# the name binds as written: it must be a valid binding identifier
				if(jslex->reserved(word.s) || strictreserved(word.s) || word.s == "eval" || word.s == "arguments" || word.s == "await")
					fail(p, wordpos, sys->sprint("cannot import '%s' as a binding", word.s));
			}
			specs = ref Node.ImportSpec(spos, p.prevend, Inamed, imported, local) :: specs;
			if(!eat(p, ",")) {
				expect(p, "}");
				break;
			}
		}
	} else
		fail(p, p.t.pos, "unexpected " + desc(p.t) + " in import");
	src := fromclause(p);
	semi(p);
	return ref Node.Import(pos, p.prevend, rev(specs), src);
}

exportdecl(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	if(eatkw(p, "default")) {
		d: ref Node;
		t := p.t;
		if(iskw(p, "function"))
			d = functionmaybeanon(p, 0, t.pos);
		else if(iskw(p, "class"))
			d = classmaybeanon(p);
		else if(iskw(p, "async") && (n := peek(p)).kind == Tident && !n.esc && n.s == "function" && !n.nlb) {
			next(p);
			d = functionmaybeanon(p, 1, t.pos);
		} else {
			d = assign(p, 0);
			semi(p);
		}
		return ref Node.Export(pos, p.prevend, d, nil, nil, 1, 0, nil);
	}
	if(eat(p, "*")) {
		as: string;
		if(eatkw(p, "as"))
			as = modname(p);
		src := fromclause(p);
		semi(p);
		return ref Node.Export(pos, p.prevend, nil, nil, src, 0, 1, as);
	}
	if(eat(p, "{")) {
		specs: list of ref Node;
		locals: list of (int, int, string);	# (where, is a string, local), to check if there is no from
		while(!eat(p, "}")) {
			spos := p.t.pos;
			isstr := p.t.kind == Tstr;
			word := p.t.s;
			local := modname(p);
			exported := local;
			if(eatkw(p, "as"))
				exported = modname(p);
			locals = (spos, isstr, word) :: locals;
			specs = ref Node.ExportSpec(spos, p.prevend, local, exported) :: specs;
			if(!eat(p, ",")) {
				expect(p, "}");
				break;
			}
		}
		src: string;
		if(iskw(p, "from"))
			src = fromclause(p);
		else
			for(l := locals; l != nil; l = tl l) {
				(at, isstr, w) := hd l;
				if(isstr)
					fail(p, at, "export of a string name without from");
				if(jslex->reserved(w) || strictreserved(w))
					fail(p, at, sys->sprint("cannot export '%s' without from", w));
			}
		semi(p);
		return ref Node.Export(pos, p.prevend, nil, rev(specs), src, 0, 0, nil);
	}
	d: ref Node;
	t := p.t;
	if(iskw(p, "var"))
		d = vardecl(p, Kvar, 1);
	else if(iskw(p, "let"))
		d = vardecl(p, Klet, 1);
	else if(iskw(p, "const"))
		d = vardecl(p, Kconst, 1);
	else if(iskw(p, "function"))
		d = function(p, 1, 0, t.pos);
	else if(iskw(p, "class"))
		d = class(p, 1);
	else if(iskw(p, "async")) {
		next(p);
		if(!iskw(p, "function") || p.t.nlb)
			fail(p, p.t.pos, "expected function after async");
		d = function(p, 1, 1, t.pos);
	} else
		fail(p, p.t.pos, "unexpected " + desc(p.t) + " after export");
	return ref Node.Export(pos, p.prevend, d, nil, nil, 0, 0, nil);
}

# export default function [name]: a declaration that may lack a name
functionmaybeanon(p: ref P, async, at: int): ref Node
{
	n := peek(p);
	gen := n.kind == Tpunct && n.s == "*";
	named := n.kind == Tident;
	if(gen) {
		save := p.l.pos;
		lx := p.l;
		lx.next(0);
		n2 := lx.next(0);
		lx.pos = save;
		named = n2.kind == Tident;
	}
	if(named)
		return function(p, 1, async, at);
	f := function(p, 0, async, at);
	pick x := f {
	Func =>
		x.flags |= Fdecl;
	}
	return f;
}

classmaybeanon(p: ref P): ref Node
{
	n := peek(p);
	if(n.kind == Tident && !(n.s == "extends" && !n.esc))
		return class(p, 1);
	c := class(p, 0);
	pick x := c {
	Class =>
		x.decl = 1;
	}
	return c;
}

# ---- expressions ----

# a comma expression; noin: no `in` operator (a for header's init)
expr(p: ref P, noin: int): ref Node
{
	pos := p.t.pos;
	e := assign(p, noin);
	if(!is(p, ","))
		return e;
	l := e :: nil;
	while(eat(p, ","))
		l = assign(p, noin) :: l;
	return ref Node.Seq(pos, p.prevend, rev(l));
}

isassignop(s: string): int
{
	case s {
	"=" or "+=" or "-=" or "*=" or "/=" or "%=" or "**=" or "<<=" or ">>=" or ">>>=" or "&=" or "|=" or "^=" or "&&=" or "||=" or "??=" =>
		return 1;
	}
	return 0;
}

assign(p: ref P, noin: int): ref Node
{
	t := p.t;
	pos := t.pos;
	if(iskw(p, "yield") && p.gen) {
		if(p.inparams)
			fail(p, pos, "yield in parameters");
		return yieldexpr(p, noin);
	}
	# x => ..., async x => ..., async (...) => ...
	if(t.kind == Tident && !is(p, "(")) {
		n := peek(p);
		if(n.kind == Tpunct && n.s == "=>" && !t.esc || n.kind == Tpunct && n.s == "=>" && isidentok(p)) {
			if(isidentok(p) || t.s == "await" || t.s == "yield") {
				id := ident(p, 1);
				return arrow(p, pos, array[] of {id}, 0, noin);
			}
		}
		if(!t.esc && t.s == "async" && !n.nlb && n.kind == Tident) {
			save := p.l.pos;
			p.l.next(0);
			n2 := p.l.next(0);
			p.l.pos = save;
			if(n2.kind == Tpunct && n2.s == "=>") {
				next(p);	# async
				oa := p.async;
				p.async = 1;
				p.inparams = 1;
				id := ident(p, 1);
				p.inparams = 0;
				p.async = oa;
				return arrow(p, pos, array[] of {id}, 1, noin);
			}
		}
	}
	oy := p.yieldat;
	oaw := p.awaitat;
	p.yieldat = -1;
	p.awaitat = -1;
	e := cond(p, noin);
	if(p.t.kind == Tpunct && p.t.s == "=>") {
		# the parameters of an arrow function, from their cover
		pick c := e {
		Paren =>
			;
		Call =>
			;
		* =>
			fail(p, p.t.pos, "unexpected =>");
		}
		(params, async) := arrowparams(p, e);
		if(p.yieldat >= 0)
			fail(p, p.yieldat, "yield in arrow parameters");
		if(p.awaitat >= 0)
			fail(p, p.awaitat, "await in arrow parameters");
		p.yieldat = oy;
		p.awaitat = oaw;
		return arrow(p, pos, params, async, noin);
	}
	if(p.yieldat < 0)
		p.yieldat = oy;
	if(p.awaitat < 0)
		p.awaitat = oaw;
	if(p.t.kind == Tpunct && isassignop(p.t.s)) {
		op := p.t.s;
		target: ref Node;
		if(op == "=")
			target = toassigntarget(p, e, pos);
		else {
			target = e;
			if(!simpletarget(p, e, op == "&&=" || op == "||=" || op == "??="))
				fail(p, pos, "invalid assignment target");
		}
		next(p);
		v := assign(p, noin);
		return ref Node.Assign(pos, p.prevend, op, target, v);
	}
	return e;
}

yieldexpr(p: ref P, noin: int): ref Node
{
	pos := p.t.pos;
	next(p);
	if(p.yieldat < 0)
		p.yieldat = pos;
	delegate := 0;
	arg: ref Node;
	if(!p.t.nlb) {
		if(eat(p, "*")) {
			delegate = 1;
			arg = assign(p, noin);
		} else if(!(is(p, ")") || is(p, "]") || is(p, "}") || is(p, ",") || is(p, ";") || is(p, ":") || p.t.kind == Teof || iskw(p, "in") && noin) && startsexpr(p))
			arg = assign(p, noin);
	}
	return ref Node.Yield(pos, p.prevend, arg, delegate);
}

# whether the current token can begin an expression (after yield)
startsexpr(p: ref P): int
{
	t := p.t;
	case t.kind {
	Tpunct =>
		case t.s {
		"(" or "[" or "{" or "+" or "-" or "!" or "~" or "++" or "--" or "/" or "/=" or "..." or "#" or "<" =>
			return 1;
		}
		return 0;
	Tident =>
		return !(t.s == "in" || t.s == "of" || t.s == "instanceof") || t.esc;
	}
	return 1;
}

cond(p: ref P, noin: int): ref Node
{
	pos := p.t.pos;
	e := binary(p, 0, noin);
	if(!eat(p, "?"))
		return e;
	cons := assign(p, 0);
	expect(p, ":");
	els := assign(p, noin);
	return ref Node.Cond(pos, p.prevend, e, cons, els);
}

prec(s: string, noin: int): int
{
	case s {
	"??" => return 1;
	"||" => return 2;
	"&&" => return 3;
	"|" => return 4;
	"^" => return 5;
	"&" => return 6;
	"==" or "!=" or "===" or "!==" => return 7;
	"<" or ">" or "<=" or ">=" or "instanceof" => return 8;
	"in" =>
		if(noin)
			return 0;
		return 8;
	"<<" or ">>" or ">>>" => return 9;
	"+" or "-" => return 10;
	"*" or "/" or "%" => return 11;
	"**" => return 12;
	}
	return 0;
}

binop(p: ref P): string
{
	t := p.t;
	if(t.kind == Tpunct)
		return t.s;
	if(t.kind == Tident && !t.esc && (t.s == "in" || t.s == "instanceof"))
		return t.s;
	return nil;
}

binary(p: ref P, minprec, noin: int): ref Node
{
	pos := p.t.pos;
	left: ref Node;
	if(p.t.kind == Tprivate) {
		# #x in obj: a private name only as in's left operand
		t := p.t;
		next(p);
		if(!iskw(p, "in") || noin)
			fail(p, t.pos, "private name outside in");
		left = ref Node.Private(t.pos, t.end, t.s);
	} else
		left = unary(p);
	for(;;) {
		op := binop(p);
		pr := prec(op, noin);
		if(pr == 0 || pr <= minprec && !(op == "**" && pr == minprec && 0))
			break;
		if(op == "**") {
			# the left operand of ** may not be a unary expression (-a ** b)
			pick u := left {
			Unary =>
				fail(p, pos, "unary expression before **");
			Await =>
				fail(p, pos, "await expression before **");
			}
		}
		next(p);
		right: ref Node;
		if(op == "**")
			right = binary(p, pr - 1, noin);	# right-associative
		else
			right = binary(p, pr, noin);
		if(op == "??" || op == "||" || op == "&&") {
			# ?? does not mix with || or && without parentheses
			if(op == "??" && (islogical(left, "||") || islogical(left, "&&") || islogical(right, "||") || islogical(right, "&&")) ||
			   op != "??" && (islogical(left, "??") || islogical(right, "??")))
				fail(p, pos, "?? mixed with || or && without parentheses");
			left = ref Node.Logical(pos, p.prevend, op, left, right);
		} else
			left = ref Node.Binary(pos, p.prevend, op, left, right);
		pick pv := left {
		Binary =>
			pick pl := pv.l {
			Private =>
				if(op != "in")
					fail(p, pl.pos, "private name outside in");
			}
		}
	}
	pick pv := left {
	Private =>
		fail(p, pv.pos, "private name outside in");
	}
	return left;
}

islogical(n: ref Node, op: string): int
{
	pick x := n {
	Logical =>
		return x.op == op;
	}
	return 0;
}

unary(p: ref P): ref Node
{
	t := p.t;
	pos := t.pos;
	if(t.kind == Tpunct) {
		case t.s {
		"!" or "~" or "+" or "-" =>
			next(p);
			arg := unary(p);
			return ref Node.Unary(pos, p.prevend, t.s, arg);
		"++" or "--" =>
			next(p);
			arg := unary(p);
			if(!simpletarget(p, arg, 0))
				fail(p, pos, "invalid update target");
			return ref Node.Update(pos, p.prevend, t.s, 1, arg);
		}
	}
	if(t.kind == Tident && !t.esc) {
		case t.s {
		"delete" or "void" or "typeof" =>
			next(p);
			arg := unary(p);
			darg := arg;
			for(;;) {
				pick pa := darg {
				Paren =>
					darg = pa.e;
					continue;
				}
				break;
			}
			if(t.s == "delete" && p.strict)
				pick a := darg {
				Ident =>
					fail(p, pos, "delete of a name in strict code");
				}
			if(t.s == "delete")
				pick a := darg {
				Member =>
					pick pr := a.prop {
					Private =>
						fail(p, pos, "delete of a private field");
					}
				Chain =>
					if(chainendsprivate(a.e))
						fail(p, pos, "delete of a private field");
				}
			return ref Node.Unary(pos, p.prevend, t.s, arg);
		"await" =>
			if(p.async || p.toplevelawait) {
				if(p.inparams)
					fail(p, pos, "await in parameters");
				if(p.instaticblock)
					fail(p, pos, "await in a class static block");
				next(p);
				if(p.awaitat < 0)
					p.awaitat = pos;
				arg := unary(p);
				return ref Node.Await(pos, p.prevend, arg);
			}
		}
	}
	e := postfix(p);
	return e;
}

chainendsprivate(n: ref Node): int
{
	pick x := n {
	Member =>
		pick pr := x.prop {
		Private =>
			return 1;
		}
	}
	return 0;
}

postfix(p: ref P): ref Node
{
	pos := p.t.pos;
	e := lhs(p);
	if(p.t.kind == Tpunct && (p.t.s == "++" || p.t.s == "--") && !p.t.nlb) {
		if(!simpletarget(p, e, 0))
			fail(p, pos, "invalid update target");
		op := p.t.s;
		next(p);
		return ref Node.Update(pos, p.prevend, op, 0, e);
	}
	return e;
}

# whether e may be assigned to by a compound assignment or update: a
# name (not eval or arguments in strict code) or a property (not in an
# optional chain).  In sloppy code a call is allowed, to fail when run
# (Annex B web compatibility), but not for logical assignment.
simpletarget(p: ref P, e: ref Node, logical: int): int
{
	pick x := e {
	Ident =>
		if(p.strict && (x.name == "eval" || x.name == "arguments"))
			return 0;
		return 1;
	Member =>
		return 1;
	Paren =>
		return simpletarget(p, x.e, logical);
	Call =>
		return !p.strict && !logical;
	}
	return 0;
}

# the left of a plain =: a name, a property or a pattern (from its literal's cover)
toassigntarget(p: ref P, e: ref Node, pos: int): ref Node
{
	if(tagof e == tagof Node.Array || tagof e == tagof Node.Object)
		return topattern(p, e, 0, pos);
	if(!simpletarget(p, e, 0))
		fail(p, pos, "invalid assignment target");
	return e;
}

# an expression cover reinterpreted as a pattern; binding: a declaration's
# or a parameter's (names only), else an assignment's (properties too)
topattern(p: ref P, e: ref Node, binding: int, pos: int): ref Node
{
	pick x := e {
	Ident =>
		if(binding) {
			if(jslex->reserved(x.name) && x.name != "yield" && x.name != "await")
				fail(p, x.pos, sys->sprint("'%s' is reserved", x.name));
			if(p.strict && (x.name == "eval" || x.name == "arguments"))
				fail(p, x.pos, sys->sprint("cannot bind '%s' in strict code", x.name));
		} else if(p.strict && (x.name == "eval" || x.name == "arguments"))
			fail(p, x.pos, sys->sprint("cannot assign to '%s' in strict code", x.name));
		return e;
	Member =>
		if(binding)
			fail(p, x.pos, "a property cannot be bound");
		return e;
	Paren =>
		# ((a)) = 1 is fine; ([a]) = 1 and ({a}) = 1 are not; nothing is in a binding
		if(binding)
			fail(p, x.pos, "parenthesised binding");
		tg := tagof x.e;
		if(tg == tagof Node.Ident || tg == tagof Node.Member || tg == tagof Node.Paren)
			return topattern(p, x.e, 0, pos);
		fail(p, x.pos, "invalid assignment target");
	Assign =>
		if(x.op != "=")
			fail(p, x.pos, "invalid destructuring default");
		t := topattern(p, x.target, binding, pos);
		return ref Node.AssignPat(x.pos, x.end, t, x.value);
	AssignPat =>
		t := topattern(p, x.target, binding, pos);
		return ref Node.AssignPat(x.pos, x.end, t, x.dflt);
	Array =>
		el := array[len x.elems] of ref Node;
		for(i := 0; i < len x.elems; i++) {
			if(x.elems[i] == nil)
				continue;
			pick s := x.elems[i] {
			Spread =>
				if(i != len x.elems - 1 || x.end > 0 && trailingcomma(p, x.elems[i].end, x.end))
					fail(p, s.pos, "a rest element must be last");
				a := topattern(p, s.arg, binding, pos);
				pick ap := a {
				AssignPat =>
					fail(p, s.pos, "a rest element with a default");
				}
				el[i] = ref Node.Rest(s.pos, s.end, a);
				continue;
			}
			el[i] = topattern(p, x.elems[i], binding, pos);
		}
		return ref Node.ArrayPat(x.pos, x.end, el);
	Object =>
		pr := array[len x.props] of ref Node;
		for(i := 0; i < len x.props; i++) {
			pick q := x.props[i] {
			Prop =>
				if(q.kind != Pinit)
					fail(p, q.pos, "a method in a pattern");
				v := topattern(p, q.value, binding, pos);
				pr[i] = ref Node.Prop(q.pos, q.end, q.key, v, Pinit, q.computed, q.shorthand);
			Spread =>
				if(i != len x.props - 1 || trailingcomma(p, q.end, x.end))
					fail(p, q.pos, "a rest property must be last");
				a := topattern(p, q.arg, binding, pos);
				if(tagof a != tagof Node.Ident && tagof a != tagof Node.Member)
					fail(p, q.pos, "a rest property must be a name");
				pr[i] = ref Node.Rest(q.pos, q.end, a);
			}
		}
		return ref Node.ObjectPat(x.pos, x.end, pr);
	ArrayPat =>
		return e;
	ObjectPat =>
		return e;
	}
	fail(p, e.pos, "invalid destructuring target");
	return nil;
}

# whether a comma follows from in the source before end (a trailing comma after a spread)
trailingcomma(p: ref P, from, end: int): int
{
	s := p.l.src;
	lx := Lex.new(s, p.ismod);
	lx.pos = from;
	t := lx.next(0);
	return t.kind == Tpunct && t.s == "," && t.end <= end;
}

# an arrow's parameters from its cover: (a, b) parsed as a Paren, or async(a, b) as a Call
arrowparams(p: ref P, e: ref Node): (array of ref Node, int)
{
	async := 0;
	items: array of ref Node;
	pick x := e {
	Paren =>
		if(x.e == nil)
			items = array[0] of ref Node;
		else
			pick s := x.e {
			Seq =>
				items = s.exprs;
			* =>
				items = array[] of {x.e};
			}
	Call =>
		pick c := x.callee {
		Ident =>
			if(c.name != "async" || x.optional || p.l.src[c.pos:c.end] != "async")
				fail(p, e.pos, "unexpected =>");
			for(k := c.end; k < x.end && p.l.src[k] != '('; k++)
				if(jslex->islt(p.l.src[k]))
					fail(p, k, "line break after async");
			if(len x.args > 0 && tagof x.args[len x.args - 1] == tagof Node.Spread && trailingcomma(p, x.args[len x.args - 1].end, x.end))
				fail(p, x.args[len x.args - 1].pos, "a rest parameter must be last");
		* =>
			fail(p, e.pos, "unexpected =>");
		}
		async = 1;
		items = x.args;
	}
	params := array[len items] of ref Node;
	os := p.async;
	if(async)
		p.async = 1;
	for(i := 0; i < len items; i++) {
		pick s := items[i] {
		Spread =>
			if(i != len items - 1)
				fail(p, s.pos, "a rest parameter must be last");
			params[i] = ref Node.Rest(s.pos, s.end, topattern(p, s.arg, 1, s.pos));
			pick ap := params[i] {
			Rest =>
				pick aa := ap.arg {
				AssignPat =>
					fail(p, s.pos, "a rest parameter with a default");
				}
			}
			continue;
		}
		params[i] = topattern(p, items[i], 1, items[i].pos);
	}
	# a name may not be await in async arrow parameters, nor yield where it is reserved
	for(l := boundnames(params, nil); l != nil; l = tl l) {
		(nm, at) := hd l;
		if(nm == "await" && (async || p.ismod))
			fail(p, at, "'await' as a parameter");
		if(nm == "yield" && (p.strict || p.gen))
			fail(p, at, "'yield' as a parameter");
		if(p.strict && strictreserved(nm))
			fail(p, at, sys->sprint("'%s' is reserved in strict code", nm));
	}
	p.async = os;
	if(async)
		for(i = 0; i < len items; i++)
			noawait(p, items[i]);
	return (params, async);
}

# no await as a name in an async arrow's parameters, nor in the
# parameters of arrows within them (parsed before they were known to be async)
noawait(p: ref P, n: ref Node)
{
	if(n == nil)
		return;
	pick x := n {
	Ident =>
		if(x.name == "await")
			fail(p, x.pos, "'await' in async arrow parameters");
	Func =>
		if(x.flags & Farrow)
			for(i := 0; i < len x.params; i++)
				noawait(p, x.params[i]);
	Paren => noawait(p, x.e);
	Seq => for(i := 0; i < len x.exprs; i++) noawait(p, x.exprs[i]);
	Assign => noawait(p, x.target); noawait(p, x.value);
	AssignPat => noawait(p, x.target); noawait(p, x.dflt);
	Spread => noawait(p, x.arg);
	Rest => noawait(p, x.arg);
	Array => for(i := 0; i < len x.elems; i++) noawait(p, x.elems[i]);
	ArrayPat => for(i := 0; i < len x.elems; i++) noawait(p, x.elems[i]);
	Object => for(i := 0; i < len x.props; i++) noawait(p, x.props[i]);
	ObjectPat => for(i := 0; i < len x.props; i++) noawait(p, x.props[i]);
	Prop =>
		if(x.computed)
			noawait(p, x.key);
		noawait(p, x.value);
	Binary => noawait(p, x.l); noawait(p, x.r);
	Logical => noawait(p, x.l); noawait(p, x.r);
	Unary => noawait(p, x.arg);
	Cond => noawait(p, x.test); noawait(p, x.cons); noawait(p, x.els);
	Call => noawait(p, x.callee); for(i := 0; i < len x.args; i++) noawait(p, x.args[i]);
	Member =>
		noawait(p, x.obj);
		if(x.computed)
			noawait(p, x.prop);
	}
}

# ---- left-hand side: member, call, new, optional chains ----

lhs(p: ref P): ref Node
{
	pos := p.t.pos;
	e: ref Node;
	if(iskw(p, "new"))
		e = newexpr(p);
	else if(iskw(p, "super"))
		e = superexpr(p);
	else if(iskw(p, "import"))
		e = importexpr(p);
	else
		e = primary(p);
	return calltail(p, pos, e, 0);
}

# member accesses, calls, templates and optional chains after e; nonew:
# in new's callee, where calls stop
calltail(p: ref P, pos: int, e: ref Node, nonew: int): ref Node
{
	chain := 0;
	for(;;) {
		t := p.t;
		if(t.kind == Tpunct) {
			case t.s {
			"." =>
				next(p);
				e = ref Node.Member(pos, 0, e, dotname(p), 0, 0);
				e.end = p.prevend;
				continue;
			"?." =>
				if(nonew)
					fail(p, t.pos, "optional chain in new's callee");
				next(p);
				chain = 1;
				if(is(p, "(")) {
					args := arguments(p);
					e = ref Node.Call(pos, p.prevend, e, args, 1);
				} else if(eat(p, "[")) {
					prop := expr(p, 0);
					expect(p, "]");
					e = ref Node.Member(pos, p.prevend, e, prop, 1, 1);
				} else if(p.t.kind == Ttemplate)
					fail(p, p.t.pos, "template after ?.");
				else
					e = ref Node.Member(pos, 0, e, dotname(p), 0, 1);
				e.end = p.prevend;
				continue;
			"[" =>
				next(p);
				prop := expr(p, 0);
				expect(p, "]");
				e = ref Node.Member(pos, p.prevend, e, prop, 1, 0);
				continue;
			"(" =>
				if(nonew)
					break;
				args := arguments(p);
				e = ref Node.Call(pos, p.prevend, e, args, 0);
				continue;
			}
		}
		if(t.kind == Ttemplate) {
			if(chain)
				fail(p, t.pos, "tagged template in an optional chain");
			q := template(p, 1);
			e = ref Node.Tagged(pos, p.prevend, e, q);
			continue;
		}
		break;
	}
	if(chain)
		e = ref Node.Chain(pos, p.prevend, e);
	return e;
}

# after a dot: a name or #private
dotname(p: ref P): ref Node
{
	t := p.t;
	if(t.kind == Tident) {
		next(p);
		return ref Node.Ident(t.pos, t.end, t.s);
	}
	if(t.kind == Tprivate) {
		next(p);
		return ref Node.Private(t.pos, t.end, t.s);
	}
	fail(p, t.pos, "expected a property name after ., found " + desc(t));
	return nil;
}

arguments(p: ref P): array of ref Node
{
	expect(p, "(");
	l: list of ref Node;
	while(!is(p, ")")) {
		pos := p.t.pos;
		if(eat(p, "...")) {
			arg := assign(p, 0);
			l = ref Node.Spread(pos, p.prevend, arg) :: l;
		} else
			l = assign(p, 0) :: l;
		if(!eat(p, ","))
			break;
	}
	expect(p, ")");
	return rev(l);
}

newexpr(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	if(eat(p, ".")) {
		if(!iskw(p, "target"))
			fail(p, p.t.pos, "expected new.target");
		next(p);
		return ref Node.Meta(pos, p.prevend, "new", "target");
	}
	cpos := p.t.pos;
	callee: ref Node;
	if(iskw(p, "new"))
		callee = newexpr(p);
	else if(iskw(p, "super"))
		callee = superexpr(p);
	else if(iskw(p, "import")) {
		n := peek(p);
		if(n.kind == Tpunct && n.s == "(")
			fail(p, cpos, "new import(...)");
		callee = importexpr(p);
	} else
		callee = primary(p);
	callee = calltail(p, cpos, callee, 1);
	args: array of ref Node;
	if(is(p, "("))
		args = arguments(p);
	return ref Node.New(pos, p.prevend, callee, args);
}

superexpr(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	if(!is(p, "(") && !is(p, ".") && !is(p, "["))
		fail(p, p.t.pos, "super must be called or have a property taken");
	return ref Node.Super(pos, p.prevend);
}

importexpr(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	if(eat(p, ".")) {
		if(!iskw(p, "meta"))
			fail(p, p.t.pos, "expected import.meta");
		if(!p.ismod)
			fail(p, pos, "import.meta outside a module");
		next(p);
		return ref Node.Meta(pos, p.prevend, "import", "meta");
	}
	expect(p, "(");
	if(is(p, ")"))
		fail(p, p.t.pos, "import() needs a specifier");
	src := assign(p, 0);
	opts: ref Node;
	if(eat(p, ",") && !is(p, ")")) {
		opts = assign(p, 0);
		eat(p, ",");
	}
	expect(p, ")");
	return ref Node.ImportCall(pos, p.prevend, src, opts);
}

# ---- primary expressions ----

primary(p: ref P): ref Node
{
	t := p.t;
	pos := t.pos;
	case t.kind {
	Tnum =>
		if(p.strict && t.octal)
			fail(p, pos, "octal literal in strict code");
		next(p);
		return ref Node.Num(pos, t.end, t.n);
	Tbigint =>
		next(p);
		return ref Node.BigInt(pos, t.end, t.s);
	Tstr =>
		if(p.strict && t.esc)
			fail(p, pos, "octal escape in strict code");
		next(p);
		return ref Node.Str(pos, t.end, t.s);
	Ttemplate =>
		return template(p, 0);
	Tprivate =>
		fail(p, pos, "unexpected private name");
	Tpunct =>
		case t.s {
		"(" =>
			return paren(p);
		"[" =>
			return arrayliteral(p);
		"{" =>
			return objectliteral(p);
		"/" or "/=" =>
			# an operand is due: this / begins a regular expression
			p.l.pos = t.pos;
			r := p.l.next(1);
			if(p.l.err != nil)
				fail(p, p.l.errpos, p.l.err);
			r.nlb = t.nlb;
			p.t = r;
			# a pattern's errors are early errors
			if(jsre == nil) {
				jsre = load Jsre Jsre->PATH;
				if(jsre == nil)
					fail(p, pos, sys->sprint("cannot load %s: %r", Jsre->PATH));
				jsre->init();
			}
			(rf, ferr) := jsre->parseflags(r.flags);
			if(ferr == nil)
				(nil, ferr) = jsre->parse(r.s, rf);
			if(ferr != nil)
				fail(p, pos, ferr);
			next(p);
			return ref Node.Regex(pos, r.end, r.s, r.flags);
		}
	Tident =>
		if(!t.esc)
			case t.s {
			"this" =>
				next(p);
				return ref Node.This(pos, t.end);
			"null" =>
				next(p);
				return ref Node.Null(pos, t.end);
			"true" or "false" =>
				next(p);
				return ref Node.Bool(pos, t.end, t.s == "true");
			"function" =>
				return function(p, 0, 0, pos);
			"class" =>
				return class(p, 0);
			"async" =>
				n := peek(p);
				if(n.kind == Tident && !n.esc && n.s == "function" && !n.nlb) {
					next(p);
					return function(p, 0, 1, pos);
				}
			"new" =>
				return newexpr(p);
			}
		return ident(p, 0);
	}
	fail(p, pos, "unexpected " + desc(t));
	return nil;
}

# ( ... ): a parenthesised expression, or an arrow's parameters (which
# may be empty, end in a comma or have a rest)
paren(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	if(eat(p, ")")) {
		if(!is(p, "=>"))
			fail(p, p.t.pos, "empty parentheses");
		return ref Node.Paren(pos, p.prevend, nil);
	}
	l: list of ref Node;
	needarrow := 0;
	epos := p.t.pos;
	for(;;) {
		spos := p.t.pos;
		if(eat(p, "...")) {
			arg := bindingtarget(p);
			l = ref Node.Spread(spos, p.prevend, arg) :: l;
			needarrow = 1;
			break;
		}
		l = assign(p, 0) :: l;
		if(!eat(p, ","))
			break;
		if(is(p, ")")) {
			needarrow = 1;	# (a, ) only as parameters
			break;
		}
	}
	expect(p, ")");
	if(needarrow && !is(p, "=>"))
		fail(p, pos, "parameters without =>");
	items := rev(l);
	e: ref Node;
	if(len items == 1 && !needarrow)
		e = items[0];
	else
		e = ref Node.Seq(epos, p.prevend - 1, items);
	return ref Node.Paren(pos, p.prevend, e);
}

arrayliteral(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	l: list of ref Node;
	while(!is(p, "]")) {
		if(is(p, ",")) {
			next(p);
			l = nil :: l;
			continue;
		}
		spos := p.t.pos;
		if(eat(p, "...")) {
			arg := assign(p, 0);
			l = ref Node.Spread(spos, p.prevend, arg) :: l;
		} else
			l = assign(p, 0) :: l;
		if(!is(p, "]"))
			expect(p, ",");
	}
	expect(p, "]");
	return ref Node.Array(pos, p.prevend, rev(l));
}

objectliteral(p: ref P): ref Node
{
	pos := p.t.pos;
	next(p);
	l: list of ref Node;
	while(!is(p, "}")) {
		l = property(p) :: l;
		if(!is(p, "}"))
			expect(p, ",");
	}
	expect(p, "}");
	return ref Node.Object(pos, p.prevend, rev(l));
}

property(p: ref P): ref Node
{
	pos := p.t.pos;
	if(eat(p, "...")) {
		arg := assign(p, 0);
		return ref Node.Spread(pos, p.prevend, arg);
	}
	async := 0;
	gen := 0;
	kind := Pinit;
	if(iskw(p, "async")) {
		n := peek(p);
		if(!(n.kind == Tpunct && (n.s == "," || n.s == ":" || n.s == "(" || n.s == "}" || n.s == "=")) && !n.nlb) {
			next(p);
			async = 1;
		}
	}
	if(eat(p, "*"))
		gen = 1;
	if(!async && !gen && (iskw(p, "get") || iskw(p, "set"))) {
		n := peek(p);
		if(!(n.kind == Tpunct && (n.s == "," || n.s == ":" || n.s == "(" || n.s == "}" || n.s == "="))) {
			if(p.t.s == "get")
				kind = Pget;
			else
				kind = Pset;
			next(p);
		}
	}
	kt := p.t;
	(key, computed) := propname(p, 0);
	if(is(p, "(")) {
		flags := Fmethod;
		if(gen)
			flags |= Fgen;
		if(async)
			flags |= Fasync;
		f := funcrest(p, kt.pos, nil, flags);
		accessorparams(p, kind, f, kt.pos);
		k := kind;
		if(k == Pinit)
			k = Pmethod;
		return ref Node.Prop(pos, p.prevend, key, f, k, computed, 0);
	}
	if(async || gen || kind != Pinit)
		fail(p, p.t.pos, "expected '(' in a method");
	if(eat(p, ":")) {
		v := assign(p, 0);
		return ref Node.Prop(pos, p.prevend, key, v, Pinit, computed, 0);
	}
	# shorthand: a, or a = 1 (a CoverInitializedName: only in a pattern)
	if(kt.kind != Tident || computed)
		fail(p, kt.pos, "expected ':' after a property name");
	p.t = kt;	# the name, as a reference this time
	p.l.pos = kt.end;
	id := ident(p, 0);
	if(eat(p, "=")) {
		d := assign(p, 0);
		v := ref Node.AssignPat(id.pos, p.prevend, id, d);
		return ref Node.Prop(pos, p.prevend, key, v, Pinit, 0, 1);
	}
	return ref Node.Prop(pos, p.prevend, key, id, Pinit, 0, 1);
}

# a template; tagged: invalid escapes are allowed (their cooked value undefined)
template(p: ref P, tagged: int): ref Node
{
	pos := p.t.pos;
	quasis: list of string;
	raws: list of string;
	exprs: list of ref Node;
	bad := 0;
	for(;;) {
		t := p.t;
		if(t.kind != Ttemplate)
			fail(p, t.pos, "expected the rest of a template");
		if(t.bad) {
			if(!tagged)
				fail(p, t.pos, "invalid escape in a template");
			bad = 1;
			quasis = nil :: quasis;
		} else
			quasis = t.s :: quasis;
		raws = t.raw :: raws;
		if(t.tail) {
			next(p);
			break;
		}
		next(p);
		exprs = expr(p, 0) :: exprs;
		if(!is(p, "}"))
			fail(p, p.t.pos, "expected } in a template");
		# the } continues the template
		r := p.l.template(p.t.pos);
		if(p.l.err != nil)
			fail(p, p.l.errpos, p.l.err);
		p.t = r;
	}
	return ref Node.Template(pos, p.prevend, revs(quasis), revs(raws), rev(exprs), bad);
}

# ---- lists ----

rev(l: list of ref Node): array of ref Node
{
	n := len l;
	a := array[n] of ref Node;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

revs(l: list of string): array of string
{
	n := len l;
	a := array[n] of string;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}
