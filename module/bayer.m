#
# Bayer: raw sensor frames to I420, natively, for the pixel loop Limbo
# cannot keep up with at video rates. Built in (libinterp/bayer.c);
# the policy around it, the tone tables and what to do with the means,
# is the caller's. See camsrv(4).
#
Bayer: module
{
	PATH:	con	"$Bayer";

	# raw holds rw by rh samples of 16 bits, little-endian. Each pixel
	# out is the mean of a square of scale by scale samples, whole 2x2
	# Bayer cells, so scale is even, 2 or more. red says where red is
	# in the cell: 0 rggb, 1 grbg, 2 gbrg, 3 bggr.
	#
	# rot turns the picture clockwise as it is written, in quarter
	# turns, 0 to 3: with 1 or 3, y is h by w and cb and cr h/2 by w/2,
	# w and h being the picture's size before the turn.
	#
	# lr, lg and lb map a mean sample to a byte, red, green, blue; each
	# has an entry for every value a sample can have. y is w by h, cb
	# and cr w/2 by h/2, full range, as $I420 and remap24 take them.
	#
	# mean gets the mean samples before the tables: red, green, blue.
	merge:	fn(raw: array of byte, rw, rh, scale, red, rot: int,
		lr, lg, lb: array of byte,
		y, cb, cr: array of byte, mean: array of int);
};
