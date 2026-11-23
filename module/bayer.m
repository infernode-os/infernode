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
	# mean gets the mean samples before the tables: red, green, blue;
	# and, if it has six or more entries, the same over the cells with
	# no sample at or above clip in 3 to 5 (each 0 if there are none),
	# for a white balance that a highlight clipped in one colour does
	# not pull: clip is in the samples' own units; 0 leaves none out.
	merge:	fn(raw: array of byte, rw, rh, scale, red, rot: int,
		lr, lg, lb: array of byte,
		y, cb, cr: array of byte, mean: array of int, clip: int);

	# Plant health, NDVI = (NIR-VIS)/(NIR+VIS), from the same blocks
	# merge averages, before any white balance: nir and vis say which
	# channel is which (0 red, 1 green, 2 blue; on a NoIR camera with
	# its blue filter, red and blue), black is taken from both, and a
	# pixel whose NIR+VIS is under floor is 0, no reading. Otherwise
	# 128 + round(127*NDVI): 1 is -1, 128 is 0, 255 is +1. out is the
	# picture's size, turned by rot as merge turns. stat, four or more
	# entries, gets the readings' mean and their tenth, fiftieth and
	# ninetieth percentiles, in thousandths (-1000 to 1000); all 0 and
	# a fifth entry of 0 if there were none, else the count there.
	ndvi:	fn(raw: array of byte, rw, rh, scale, red, rot, nir, vis, black, floor: int,
		out: array of byte, stat: array of int);

	# Lens shading, corrected in place: table holds a gain for each of
	# the cell's four samples (in the frame's own order: top left, top
	# right, bottom left, bottom right) at gw by gh points spread evenly
	# from corner to corner, 4*gw*gh entries, the four positions apart
	# (all of the first, then the second...), 1024 a gain of one. Each
	# sample above black is multiplied by its position's gain there,
	# found bilinearly, and held at max.
	shade:	fn(raw: array of byte, rw, rh, black, max: int, table: array of int, gw, gh: int);
};
