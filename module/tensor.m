#
# Tensor: the arithmetic of a convolutional network, natively, for
# vision(4) (#1086). Built in (libinterp/tensor.c), as $I420 and $Bayer
# are: functions over arrays, keeping nothing between calls. What a
# network is, what it means and what to do with its output are the
# caller's (appl/lib/visnet.b).
#
# A tensor is an array of byte holding 32-bit floats, little-endian:
# c planes of h rows of w, 4-byte aligned (an array, or a slice of one
# at a multiple of 4). A function refuses (array bounds error) any
# size that does not fit its arrays, so no call reads or writes outside
# them. Each releases the VM while it computes.
#
Tensor: module
{
	PATH:	con	"$Tensor";

	# activations, applied as a result is stored
	None, Relu, Sigmoid, Silu: con iota;

	# out (oc x oh x ow) = activation(conv(in, w) + bias), where
	# oh = (h + 2*pad - kh)/stride + 1 and ow likewise; w holds
	# oc x (c/group) x kh x kw weights, bias oc. group is 1 or c (a
	# depthwise convolution, oc = c).
	conv:	fn(in: array of byte, c, h, w: int,
		wt: array of byte, oc, kh, kw, stride, pad, group: int,
		bias: array of byte, act: int, out: array of byte);

	# out = a + b, element by element; all the same length
	add:	fn(a, b, out: array of byte);

	# out = activation(in); the same length
	act:	fn(in, out: array of byte, act: int);

	# max over k by k, padded with -infinity
	maxpool:	fn(in: array of byte, c, h, w, k, stride, pad: int, out: array of byte);

	# nearest neighbour, twice the rows and columns
	up2:	fn(in: array of byte, c, h, w: int, out: array of byte);

	# space to depth: the 2x2 cells' (0,0) (1,0) (0,1) (1,1) samples
	# as four times the channels at half the rows and columns
	s2d:	fn(in: array of byte, c, h, w: int, out: array of byte);

	# a picture into a network's input, 3 x oh x ow: pix is w by h
	# Draw->RGB24 pixels (blue, green, red in memory), scaled by scale
	# with bilinear interpolation into the top left corner, the rest
	# fill; channels red, green, blue, or blue, green, red if bgr.
	# Values are 0 to 255, as the pixels are.
	letterbox:	fn(pix: array of byte, w, h: int, scale: real,
		fill, bgr: int, out: array of byte, ow, oh: int);

	# the same from an I420 frame, w by h (both even): its Y plane w by
	# h, Cb and Cr w/2 by h/2, full range as $I420 takes them
	letterboxi420:	fn(y, cb, cr: array of byte, w, h: int, scale: real,
		fill, bgr: int, out: array of byte, ow, oh: int);

	# a tensor's floats to reals, and back; out as long as in
	toreal:	fn(t: array of byte, out: array of real);
	fromreal:	fn(r: array of real, out: array of byte);

	# "neon" or "c": what the arithmetic was compiled as
	kind:	fn(): string;
};
