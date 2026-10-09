#
# css.m - CSS syntax: tokens, rules, declarations, selectors.
#
# This module knows the grammar and nothing about documents: it turns
# style sheet text into rules whose values are component values (tokens,
# with functions and blocks holding their contents) and whose selectors
# are compiled.  Matching, the cascade and value computation are in
# style.m.  CSS Syntax 3, Selectors 4, CSS Nesting 1.
#
# Nested style rules are flattened as they are parsed: a nested rule's
# selector has its '&' (explicit or implied) replaced by :is(parent), so
# every Style rule in a Sheet is a plain selector list and declarations.
#
Css: module
{
	PATH:	con "/dis/lib/web/css.dis";

	init:	fn();

	# token kinds (CSS Syntax 3 §4)
	Kident, Kfunction, Katkeyword, Khash, Kstring, Kbadstring, Kurl, Kbadurl,
	Kdelim, Knumber, Kpercent, Kdimension, Kws, Kcdo, Kcdc, Kcolon,
	Ksemicolon, Kcomma, Klbracket, Krbracket, Klparen, Krparen, Klbrace,
	Krbrace, Keof,
	# component-value blocks: [...], (...), {...}; contents in kids
	Kblock: con iota;

	Tok: adt {
		kind:	int;
		s:	string;		# ident, function or at-keyword name, hash, string,
					# url, delim character, dimension unit (lower case);
					# for Kblock the opening bracket
		n:	real;		# Knumber, Kpercent, Kdimension
		flag:	int;		# number: 1 integer-valued, 2 written with "+"; hash: valid as an id
		kids:	cyclic array of ref Tok;	# Kfunction arguments, Kblock contents
	};

	Decl: adt {
		name:	string;		# lower case, except custom properties (--x)
		val:	array of ref Tok;	# component values, whitespace trimmed
		important:	int;
	};

	# simple selector kinds
	Stype, Suniversal, Sid, Sclass, Sattr, Spseudo, Spseudoel: con iota;
	# attribute operators
	Aexists, Aequals, Aword, Adash, Aprefix, Asuffix, Asubstr: con iota;

	Simple: adt {
		kind:	int;
		name:	string;		# type, id, class, attribute or pseudo name
		op:	int;		# attribute operator
		val:	string;		# attribute value; pseudo: argument text
		icase:	int;		# attribute: [... i]
		a, b:	int;		# :nth-*(an+b)
		sub:	cyclic array of ref Sel;	# :is :where :not :has, :nth-*(... of S)
	};

	# A complex selector: compounds left to right, with the combinator
	# before each (' ', '>', '+', '~'; combs[0] is the leading combinator
	# of a relative selector, as in :has(> p), else 0).
	Sel: adt {
		parts:	array of array of ref Simple;
		combs:	array of int;
		spec:	int;		# specificity, (a<<20)|(b<<10)|c
		pseudo:	string;		# pseudo-element of the subject ("before"), or nil
	};

	Rule: adt {
		pick {
		Style =>
			sels:	array of ref Sel;
			decls:	array of ref Decl;
		Media =>
			cond:	array of ref Tok;	# the query list, unevaluated
			rules:	cyclic array of ref Rule;
		Supports =>
			cond:	array of ref Tok;
			rules:	cyclic array of ref Rule;
		Layer =>
			names:	list of string;	# @layer a, b; (rules nil) or @layer a {...}
			rules:	cyclic array of ref Rule;
		Container =>
			cond:	array of ref Tok;
			rules:	cyclic array of ref Rule;
		Import =>
			url:	string;
			cond:	array of ref Tok;	# media
			layer:	string;		# nil, or the layer (possibly "" for anonymous)
		Fontface =>
			decls:	array of ref Decl;
		Other =>
			name:	string;		# @keyframes, @page, ...: kept, not used
			prelude:	array of ref Tok;
			block:	array of ref Tok;
		}
	};

	Sheet: adt {
		rules:	array of ref Rule;
	};

	parse:	fn(s: string): ref Sheet;
	parsedecls:	fn(s: string): array of ref Decl;	# a style="" attribute
	validvars:	fn(v: array of ref Tok): int;	# the var() references in a value are well formed
	parsesels:	fn(s: string): array of ref Sel;	# nil if invalid
	tokenize:	fn(s: string): array of ref Tok;	# component values
	tostring:	fn(v: array of ref Tok): string;
	seltostring:	fn(s: ref Sel): string;
};
