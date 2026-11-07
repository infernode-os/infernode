#
# Layers: what is drawn over a video, as text files stacked by the name
# space (#1095).
#
# A feed's layer/ directory holds its layers, a file each, in the order
# its union lists them (bind -b underneath, bind -a on top; ls -n shows
# it). A layer is records, one a line, attr=value:
#
#	frame=1234 box x0=320 y0=180 x1=384 y1=320 label=person
#	frame=1234 line x0=10 y0=400 x1=630 y1=400 colour=accent
#	frame=1234 text x=10 y=10 label="3 people"
#	frame=1234 point x=200 y=150
#	frame=* box x0=100 y0=80 x1=500 y1=400 label=door	every frame
#	frame=1235						nothing on this frame
#
# A record with x0 y0 x1 y1 and no kind is a box, named by label=, or
# else by class= and score=: vision(4)'s detections are a layer as they
# are. On frame F each layer shows its records for the newest frame up
# to F, and its frame=* records. Attributes it does not know it ignores.
#
# A Stack follows one layer directory in the name space of whoever
# watches it: each viewer's stack is its own.
#
Layers: module
{
	PATH:	con	"/dis/lib/layers.dis";

	Box, Line, Text, Point: con iota;

	Mark: adt {
		kind:	int;
		x0, y0, x1, y1:	int;	# a point or text at x0 y0
		label:	string;
		colour:	string;		# a theme's name or rrggbb; nil: the accent
	};

	Layer: adt {
		name:	string;
		all:	list of ref Mark;			# frame=*
		frames:	array of (int, list of ref Mark);	# the newest frames', oldest first
	};

	Stack: adt {
		dir:	string;
		layers:	array of ref Layer;	# bottom first; replaced whole
		pids:	list of (string, int);
		ctl:	chan of int;

		watch:	fn(dir: string): ref Stack;
		# the marks due on frame, bottom layer first
		due:	fn(s: self ref Stack, frame: int): list of ref Mark;
		stop:	fn(s: self ref Stack);
	};

	init:	fn(): string;

	# a line as a mark: (frame, mark); frame -1 for frame=*, and -2 for
	# a line that is no mark; mark nil for a frame's key alone
	parse:	fn(line: string): (int, ref Mark);
};
