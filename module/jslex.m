#
# jslex.m - JavaScript's tokens (ECMAScript 2025 §12).
#
# The parser drives: whether a / starts a regular expression or
# divides depends on what came before, and a } may close a template's
# substitution, so the parser says which it expects (next's regexok,
# template).  Positions are character offsets into the source.
#
Jslex: module
{
	PATH:	con "/dis/lib/js/jslex.dis";

	# token kinds
	Teof, Tident, Tprivate, Tpunct, Tnum, Tbigint, Tstr, Ttemplate, Tregex: con iota;

	Tok: adt {
		kind:	int;
		pos, end:	int;	# [pos, end) in the source
		s:	string;		# ident or #name (without #, escapes decoded); punctuator; string's value; bigint's digits; regex body
		n:	real;		# number
		flags:	string;		# regex flags
		nlb:	int;		# a line terminator came before it (for ASI and restricted productions)
		esc:	int;		# ident written with an escape (so not a keyword); string with a legacy octal or \8 \9 escape (an error in strict code)
		octal:	int;		# number: a legacy octal (017) or leading-zero decimal (08), an error in strict code
		# templates: tail is 1 if the part ended with `, 0 if with ${;
		# cooked is nil and bad set where an escape is not valid (an
		# error unless the template is tagged)
		tail:	int;
		bad:	int;
		raw:	string;
	};

	Lex: adt {
		src:	string;
		pos:	int;
		ismod:	int;	# module code: no HTML-like comments
		err:	string;	# the first error, with its position in errpos
		errpos:	int;

		new:	fn(src: string, ismod: int): ref Lex;
		# the next token; regexok: a / here begins a regular expression
		next:	fn(l: self ref Lex, regexok: int): ref Tok;
		# after the } that ends a template substitution: the rest of
		# the template, up to the next ${ or the closing `
		template:	fn(l: self ref Lex, at: int): ref Tok;
	};

	init:	fn();
	isidstart:	fn(c: int): int;
	isidpart:	fn(c: int): int;
	islt:	fn(c: int): int;
	# UTF-8 source to the UTF-16 JavaScript reads (Dis strings hold only 16-bit characters)
	utf16:	fn(b: array of byte): string;
	reserved:	fn(s: string): int;	# a reserved word in all code (§12.7.2)
};
