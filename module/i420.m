#
# I420: planar YCbCr 4:2:0 video frames converted natively.
# Built into the emulator; load returns nil where it is not
# (appl/mpeg/remap24.b then converts in Limbo, identically).
#
I420: module
{
	PATH:	con	"$I420";

	# convert a w by h frame (w and h even) from its Y, Cb and Cr planes
	# to Draw->RGB24 pixels, stored blue, green, red, in out
	rgb24:	fn(y, cb, cr: array of byte, w, h: int, out: array of byte);
};
