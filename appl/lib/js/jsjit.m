# jsjit.m - what the engine and its compiled code share (jsjit.b): a
# value, the state a compiled function runs on, and the module each
# compiled function is.  appl/lib/js/jsjitt.b is a module of the same
# type that limbo compiles, read for the signature a generated one needs.

V: adt {
	t:	int;
	x:	int;		# Tbool: 0 or 1; Tstr: string handle; Tsym: atom; Tobj: object handle; Tacc: getter or -1
	n:	real;		# Tnum; Tacc: the setter's handle, or -1
};

Jitst: adt {
	vs:	array of V;	# the engine's value stack
	base:	int;		# the running frame's registers start here
	consts:	array of V;	# its code's constants
};

# run the code from pc, an operation compiled; return the pc of the first
# one it leaves to the interpreter
Jitcode: module
{
	run:	fn(st: ref Jitst, pc: int): int;
};
