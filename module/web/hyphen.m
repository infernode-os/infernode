#
# hyphen.m - where a word may be hyphenated (hyphens: auto), by Liang's
# algorithm over TeX's patterns (lib/web/hyphen: American English, the
# patterns Android's, and so Chromium's, are), as a browser's limits
# have it: words of five letters or more, two letters at least before a
# break and three after it, and none of a capitalized word.
#
Hyphen: module
{
	PATH:	con "/dis/lib/web/hyphen.dis";
	DIR:	con "/lib/web/hyphen/";

	# whether there are patterns for lang (a language tag: en, en-GB...)
	known:	fn(lang: string): int;

	# s with a soft hyphen (U+00AD) wherever one of its words may be
	# hyphenated in lang; s itself where there are no patterns for it
	hyphenate:	fn(s: string, lang: string): string;

	# the places word w (letters) may be hyphenated: brk[i] is 1 where a
	# break may come before w[i]; nil for none
	points:	fn(w: string, lang: string): array of byte;
};
