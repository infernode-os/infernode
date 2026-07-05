#
# matrixlib.m — Matrix composition data types and parser
#
# Shared between the Matrix runtime (appl/wm/matrix.b), its tests,
# and any tool that manipulates compositions.  Callers must include
# sys.m, draw.m, and matrix.m before this file.
#
# A composition is a plain-text description of which modules to
# load, where they mount, and how display regions are arranged.
# See doc/matrix-architecture.md for the format.
#

MatrixLib: module
{
	PATH:	con "/dis/lib/matrixlib.dis";

	init:	fn();

	# Parse a composition file.  Returns (composition, nil) on
	# success or (nil, diagnostic) on the first error.
	parsecomposition:	fn(text: string): (ref Composition, string);
};

# Layout split orientations and the nesting cap (~16 leaf regions).
HSPLIT:	con 0;
VSPLIT:	con 1;
MAX_DEPTH:	con 4;

# Binary split tree.  Leaves are named by their path in the tree
# ("left/top", "right", ...); a leaf with modname != "" has a display
# module assigned.  Rects are filled in by the runtime's layout pass.
LayoutNode: adt
{
	pick {
	Split =>
		orient: int;
		ratio1: int;
		ratio2: int;
		child1: cyclic ref LayoutNode;
		child2: cyclic ref LayoutNode;
		r: Draw->Rect;
	Leaf =>
		name: string;
		modname: string;
		mount: string;
		mod: MatrixDisplay;
		r: Draw->Rect;
	}
};

# "region modname mount" line, before it is applied to the layout.
ModuleAssign: adt
{
	region: string;
	modname: string;
	mount: string;
};

# "service name mount" line.  outdir/mod/pid are runtime state.
ServiceEntry: adt
{
	name: string;
	mount: string;
	outdir: string;
	mod: MatrixService;
	pid: int;
};

# "watch <path>" block: arms are (pattern, action) pairs in file order.
WatchRule: adt
{
	path: string;
	arms: list of (string, string);
};

Composition: adt
{
	name: string;
	layout: ref LayoutNode;
	assigns: list of ref ModuleAssign;
	services: list of ref ServiceEntry;
	watches: list of ref WatchRule;
	text: string;
};
