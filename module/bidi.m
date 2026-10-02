#
# bidi.m - the Unicode Bidirectional Algorithm (UAX #9).
#
# Text is stored in logical order; a line of it is displayed with its
# right-to-left runs reversed.  levels() resolves each character of a
# paragraph to an embedding level (even: left to right, odd: right to
# left) from the characters' classes and any explicit embeddings,
# overrides and isolates among them; reorder() gives the visual order
# of a line's characters from their levels; mirror() gives the glyph a
# character takes when displayed right to left.
#
# The tables (Bidi_Class, Bidi_Mirroring_Glyph, Bidi_Paired_Bracket)
# are read from /lib/bidi at init, generated from the Unicode Character
# Database by tools/bidi/gen.py.
#
Bidi: module
{
	PATH:	con "/dis/lib/bidi.dis";
	DIR:	con "/lib/bidi";

	init:	fn(): string;

	# Bidi_Class
	L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON,
	LRE, LRO, RLE, RLO, PDF, LRI, RLI, FSI, PDI: con iota;

	class:	fn(c: int): int;
	mirror:	fn(c: int): int;	# the mirrored character, or c

	# Joining_Type (Unicode chapter 9, ArabicShaping.txt): how a cursive
	# letter connects to its neighbours
	JU, JC, JD, JR, JL, JT: con iota;	# none, join-causing, dual, right, left, transparent
	joining:	fn(c: int): int;

	# punctuation (General_Category P*), which ::first-letter takes along
	punct:	fn(c: int): int;

	# Line_Break class (UAX #14, LineBreak.txt), AL for the unlisted
	LBAL, LBID, LBOP, LBCL, LBCP, LBQU, LBGL, LBNS, LBEX, LBIS, LBBA, LBBB, LBHY,
	LBZW, LBWJ, LBCM, LBZWJ, LBH2, LBH3, LBJL, LBJV, LBJT, LBEB, LBEM, LBPO, LBPR,
	LBSY, LBIN, LBNU, LBCJ, LBSP, LBBK, LBCR, LBLF, LBNL: con iota;
	lbclass:	fn(c: int): int;

	# the paragraph's base direction from its first strong character
	# (P2, P3): 0 left to right, 1 right to left, -1 none found
	basedir:	fn(s: array of int): int;

	# The embedding level of each character of a paragraph (X1-X10,
	# W1-W7, N0-N2, I1-I2, and L1 for separators and the paragraph's
	# trailing white space).  dir: 0 or 1 for the paragraph level,
	# -1 to take it from the first strong character (else 0).
	levels:	fn(s: array of int, dir: int): array of int;

	# L1 for a line: the levels of the characters s[from:end] with
	# trailing white space (and isolate controls, and what X9 removed)
	# reset to the paragraph level.
	linelevels:	fn(s: array of int, levels: array of int, from, end, paralevel: int): array of int;

	# L2: the visual order of a line's characters from their levels:
	# r[i] is the logical index of the character shown i-th from the left.
	reorder:	fn(levels: array of int): array of int;
};
