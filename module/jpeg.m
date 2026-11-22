#
# JPEG to and from I420 planes, for video: no RGB on either side.
#
Jpegenc: module
{
	PATH:	con "/dis/lib/jpegenc.dis";

	# A baseline JPEG (JFIF, 4:2:0, Huffman tables of ITU T.81 Annex K)
	# of an I420 frame: y is w*h samples, u and v (w+1)/2 by (h+1)/2.
	# quality 1-100 scales Annex K's tables as libjpeg does.  nil and
	# a reason if the planes are short or the size or quality is not.
	encode:	fn(w, h: int, y, u, v: array of byte, quality: int): (array of byte, string);
};

Jpegplanes: module
{
	PATH:	con "/dis/lib/readjpg.dis";	# readjpg(2) implements this too

	# A 4:2:0 JPEG (three components, the first sampled 2x2 and the
	# others 1x1) as I420 planes, without the colour conversion or
	# upsampling an RGB image needs: (w, h, y, u, v, nil), or the reason
	# it is not one.
	planes:	fn(d: array of byte): (int, int, array of byte, array of byte, array of byte, string);
};
