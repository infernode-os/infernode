#
# matrixtk.m — Tk-hosted Matrix display module interface
#
# A third module kind alongside MatrixDisplay/MatrixService
# (matrix.m): the region is a real Tk frame — a canvas window item
# positioned by the runtime — and the module builds widgets under
# <prefix>.* and owns their behaviour.  Tk routes the region's
# pointer/keyboard events itself, so there are no pointer/key
# functions here; modules receive semantic events on channels they
# register with tk->namechan (derive a unique channel name from the
# prefix).  Hosted widgets inherit the live theme from the Tk
# engine palette.
#
# Separate from matrix.m so the many pixel-rendering modules that
# include matrix.m need not pull in tk.m.  Callers must include
# sys.m, draw.m, and tk.m before this file.
#
# Trust domain: same as MatrixDisplay — in-process, loaded from the
# local library only.
#

MatrixTkDisplay: module
{
	# Build widgets under prefix (a frame that already exists).
	# Returns nil on success, error string on failure.
	init:	fn(top: ref Tk->Toplevel, prefix, mount: string): string;

	# The region rect changed.  The frame geometry is already
	# applied by the runtime; repack/adjust internals if needed.
	resize:	fn(r: Draw->Rect);

	# Re-read the mount; return 1 if widgets changed (the runtime
	# runs a Tk update pass).
	update:	fn(): int;

	# Theme changed.  The engine palette is already re-themed;
	# adjust any module-set colours.
	retheme:	fn();

	# Clean up (stop procs, drop refs).  The runtime destroys the
	# prefix widget subtree after this returns.
	shutdown:	fn();
};
