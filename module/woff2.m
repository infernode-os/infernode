Woff2: module
{
	PATH:	con "/dis/lib/woff2.dis";

	# A WOFF2 font (W3C WOFF 2.0) as the TrueType/OpenType file it packs,
	# its glyf, loca and hmtx tables rebuilt from their transformed forms.
	# Font collections are not supported.
	decode:	fn(data: array of byte): (array of byte, string);
};
