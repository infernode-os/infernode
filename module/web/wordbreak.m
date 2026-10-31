#
# wordbreak.m - where a line may break inside text written without
# spaces between its words (Thai), found from a dictionary as ICU's
# ThaiBreakEngine finds them, so that lines break where a browser's do.
#
Wordbreak: module
{
	PATH:	con "/dis/lib/web/wordbreak.dis";
	DICT:	con "/lib/web/thaidict";

	# s's break opportunities: brk[i] is 1 where a line may break
	# before s[i] between two words; nil if s has no such text (or
	# the dictionary cannot be read)
	breaks:	fn(s: string): array of byte;

	# whether c is a letter of such text
	needs:	fn(c: int): int;
};
