#
# matrix.m — Matrix compositional module runtime interfaces
#
# Defines the two module interfaces Matrix loads: display and
# service.  The composition data types and parser live in
# matrixlib.m / lib/matrixlib, not here — this file is included
# by every module implementation and stays minimal.
#
# Display modules render live content into a region of the
# Matrix pane with Draw primitives; they run in-process and are
# trusted (loaded from the local library only).  Service modules
# run headless in their own process, confined by namespace to
# their mount (read-only) and output directory (read-write).
#
# See doc/matrix-architecture.md for the full specification.
#

MatrixDisplay: module
{
	# Initialise with the Draw display, font, and a root path
	# in the namespace that this module reads from.
	# Returns nil on success, error string on failure.
	init:	fn(display: ref Draw->Display,
		   font: ref Draw->Font,
		   mount: string): string;

	# Resize the module's drawing area.
	resize:	fn(r: Draw->Rect);

	# Update state by re-reading from the mount namespace.
	# Returns 1 if the display needs redrawing, 0 if unchanged.
	update:	fn(): int;

	# Draw the current state into the provided image.
	draw:	fn(dst: ref Draw->Image);

	# Route a pointer event to the module.
	# Returns 1 if consumed, 0 if not.
	pointer:	fn(p: ref Draw->Pointer): int;

	# Route a keyboard event to the module.
	# Returns 1 if consumed, 0 if not.
	key:	fn(k: int): int;

	# Reload colours after a theme change.
	retheme:	fn(display: ref Draw->Display);

	# Clean up resources.  Called before unload.
	shutdown:	fn();
};

MatrixService: module
{
	# Initialise with the mount point this module reads from
	# and a directory path where it writes its outputs.
	# Returns nil on success, error string on failure.
	init:	fn(mount: string, outdir: string): string;

	# Run the service.  Blocks until shutdown.
	# Typically spawned in its own goroutine by the Matrix runtime.
	run:	fn();

	# Signal the service to stop.  run() should return promptly.
	shutdown:	fn();
};
