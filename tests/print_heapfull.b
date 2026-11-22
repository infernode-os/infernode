implement PrintHeapfull;

#
# sys->aprint and sys->sprint with the Dis heap full
# (tests/host/print_heapfull_test.sh runs this in an emulator of its
# own, with a small heap: it fills the heap, and the kernel says so).
#
# aprint destroyed the array its result replaces before it made the new
# one, and making the new one raises when the heap is full: after
#	a = sys->aprint(...)
# had raised, a still named the block that had been freed. The program
# read it, wrote it (into whatever was allocated there next) and freed
# it again. And the buffer aprint and sprint format long text into was
# malloc'd from the kernel's main pool and lost whenever that raise came.
#

include "sys.m";
	sys: Sys;
include "draw.m";

PrintHeapfull: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

fill: list of array of byte;

# bytes in use in a kernel pool, from /dev/memory
used(pool: string): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 8 && hd tl tl tl tl tl tl tl f == pool)
			return int hd f;
	}
	return -1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	a := array[1] of {byte 11};
	s := "kept";

	# fill the heap until less than 4MB is left in one piece
	{
		for(;;)
			fill = array[4*1024*1024] of byte :: fill;
	} exception {
	"out of memory*" =>
		;
	}
	sys->print("FILLED %d\n", len fill);

	main0 := used("main");
	raised := 0;
	for(i := 0; i < 12; i++){
		{
			# 20MB of text: more than the heap has left
			a = sys->aprint("%20000000d", 0);
		} exception {
		"*" =>
			raised++;
		}
		{
			s = sys->sprint("%20000000d", 0);
		} exception {
		"*" =>
			raised++;
		}
	}
	sys->print("RAISED %d\n", raised);

	# a is still the array it was: a block allocated now is another one
	x := array[1] of {byte 77};
	sys->print("A %d %d X %d S %s\n", len a, int a[0], int x[0], s);
	a[0] = byte 5;
	sys->print("AFTERWRITE X %d\n", int x[0]);
	main1 := used("main");
	sys->print("MAIN %d\n", main1 - main0);
	fill = nil;
	a = nil;
	x = nil;

	# and with room again both give their text
	a = sys->aprint("%300d", 7);
	s = sys->sprint("%300d", 7);
	sys->print("ROOM %d %d %d\n", len a, len s, int a[299]);
	sys->print("DONE\n");
}
