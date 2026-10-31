# Sam's regular expressions over a rune string.
#
# The engine from Plan 9 sam (by way of acme's regx.b), with sam's
# semantics: ^ and $ match at every line boundary, \n is a newline,
# matches are leftmost-longest, and a search can run backwards.
# lib/regex's anchors only match at the ends of the searched range,
# which is wrong for a multi-line buffer.

Samrx: module
{
	PATH:	con "/dis/wm/samrx.dis";

	NRange:	con 10;		# whole match + \1..\9
	Infinity:	con 16r7fffffff;

	init:	fn();

	# compile re, making it the current program.  Returns nil or an
	# error string.
	compile:	fn(re: string): string;

	# search s forwards from startp.  With eof == Infinity the search
	# wraps to the start of s; otherwise the match must end by eof.
	# Returns nil or NRange (q0, q1) pairs, [0] the whole match; a
	# subexpression that took no part is empty.
	execute:	fn(s: string, startp, eof: int): array of (int, int);

	# search s backwards for a match ending at or before startp,
	# wrapping to the end.
	bexecute:	fn(s: string, startp: int): array of (int, int);
};
