#
# Pdfenc - the PostScript and PDF character encodings and glyph names
#
# The tables a PDF interpreter needs to find a glyph for a character
# code of a simple font: the encodings by name, and the Unicode value
# of a glyph name, for a font that has no glyph names (TrueType, or a
# substitute for a font not embedded).
#

Pdfenc: module {
	PATH: con "/dis/lib/pdfenc.dis";

	# The encoding named, a glyph name for each of the 256 codes (nil
	# where it has none): StandardEncoding, WinAnsiEncoding,
	# MacRomanEncoding, Symbol (the Symbol font's own) or
	# ZapfDingbats; nil for another name.
	encoding:	fn(name: string): array of string;

	# The Unicode value of a glyph name: the Adobe Glyph List for New
	# Fonts and every name the encodings use, uniXXXX, uXXXX[XX]; -1
	# if it has none.
	unicode:	fn(name: string): int;
};
