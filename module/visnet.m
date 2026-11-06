#
# Visnet: a vision(4) model run on $Tensor (#1086). A model is a directory
# that tools/vision/onnx2vis.py made: graph, weights, classes, info and
# sha256. This module reads it, checks it, and runs it: all of what a
# network is and what its output means is here, in Limbo; $Tensor does
# only the arithmetic.
#
Visnet: module
{
	PATH:	con	"/dis/lib/visnet.dis";

	# something found: its class (an index in Net.classes), its score,
	# and its box in the picture's pixels, x0 y0 inclusive, x1 y1 not
	Det: adt {
		class:	int;
		score:	real;
		x0, y0, x1, y1:	real;
	};

	# a detection head's output: c planes of h by w, stride pixels a cell
	Head: adt {
		name:	string;
		t:	array of byte;
		c, h, w, stride:	int;
	};

	Op: adt {
		op:	int;
		out:	int;			# the tensor it makes
		ins:	array of int;		# the tensors it reads
		p:	array of int;		# its numbers, by op
		name:	string;			# an output's name
	};

	Net: adt {
		dir:	string;
		kind, decode, order:	string;	# info's
		inw, inh, nclass, fill:	int;
		classes:	array of string;
		sha256:	string;
		nweights:	int;
		nops:	int;

		ops:	array of ref Op;
		shapes:	array of (int, int, int);	# each tensor's c h w
		last:	array of int;			# the op that last reads each
		wts:	array of byte;

		# read and check a model directory: the weights' hash, every
		# operation's numbers, every tensor's shape
		open:	fn(dir: string): (ref Net, string);
		# the network on an input tensor (3 x inh x inw floats)
		run:	fn(n: self ref Net, input: array of byte): (array of ref Head, string);
		# a picture (w by h Draw->RGB24 pixels: blue, green, red in
		# memory) through the network: what is found with a score of
		# thresh or more, overlaps of iou or more of one class kept
		# once, best first
		detect:	fn(n: self ref Net, pix: array of byte, w, h: int, thresh, iou: real): (array of ref Det, string);
		scale:	fn(n: self ref Net, w, h: int): real;
		found:	fn(n: self ref Net, input: array of byte, w, h: int, scale, thresh, iou: real): (array of ref Det, string);
		# the same from an I420 frame's planes (w and h even)
		detecti420:	fn(n: self ref Net, y, cb, cr: array of byte, w, h: int, thresh, iou: real): (array of ref Det, string);
	};

	init:	fn(): string;

	# a picture file's pixels, as detect takes them: (pixels, w, h, error)
	readpixels:	fn(path: string): (array of byte, int, int, string);
	readpixelsdata:	fn(data: array of byte, hint: string): (array of byte, int, int, string);
};
