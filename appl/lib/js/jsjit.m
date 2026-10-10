# jsjit.m - what the engine and its compiled code share (jsjit.b): a
# value, the state a compiled function runs on, and the module each
# compiled function is.  appl/lib/js/jsjitt.b is a module of the same
# type that limbo compiles, read for the signature a generated one needs.

V: adt {
	t:	int;
	x:	int;		# Tbool: 0 or 1; Tstr: string handle; Tsym: atom; Tobj: object handle; Tacc: getter or -1
	n:	real;		# Tnum; Tacc: the setter's handle, or -1
};

# an object's shape: its keys, in order, and where each is
Shape: adt {
	keys:	array of int;
	attrs:	array of int;
	n:	int;
	index:	array of list of (int, int);	# key to slot, when n is large
	trans:	list of (int, int, ref Shape);	# (key, attributes, shape)
	owned:	int;
	gen:	int;	# an owned shape's changes: an inline cache of one holds its gen too
};

Jitst: adt {
	vs:	array of V;	# the engine's value stack
	base:	int;		# the running frame's registers start here
	consts:	array of V;	# its code's constants
	oshape:	array of ref Shape;	# by object: its shape
	oslots:	array of array of V;	# by object: its properties' values
	ics:	array of ref Shape;	# the code's inline caches: the shape seen,
	icslot:	array of int;	# the slot it had the property in,
	icgen:	array of int;	# and the shape's gen then
};

# run the code from pc, an operation compiled; return the pc of the first
# one it leaves to the interpreter
Jitcode: module
{
	run:	fn(st: ref Jitst, pc: int): int;
};
