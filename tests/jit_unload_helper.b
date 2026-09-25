implement JitUnloadHelper;

# Loaded by jit_unload_test.b: a module whose one function sleeps, so
# that its caller can drop the last reference to it before it returns.
#
# It must be compiled for the test to mean anything, and comp-amd64.c
# declines a module of fewer than 128 instructions (its compile()'s
# overflow check compares a size it has already rounded up), so pad()
# is there to make it longer than that. Nothing calls it.

include "sys.m";
	sys: Sys;

JitUnloadHelper: module
{
	PATH:	con "/dis/tests/jit_unload_helper.dis";
	hold:	fn(ms: int): int;
	pad:	fn(a: int): int;
};

hold(ms: int): int
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	sys->sleep(ms);
	return ms + 1;
}

pad(a: int): int
{
	b := a;
	b = b*3 + (a ^ 1);
	b = b*4 + (a ^ 14);
	b = b*5 + (a ^ 27);
	b = b*6 + (a ^ 40);
	b = b*7 + (a ^ 53);
	b = b*8 + (a ^ 66);
	b = b*9 + (a ^ 79);
	b = b*3 + (a ^ 92);
	b = b*4 + (a ^ 105);
	b = b*5 + (a ^ 118);
	b = b*6 + (a ^ 131);
	b = b*7 + (a ^ 144);
	b = b*8 + (a ^ 157);
	b = b*9 + (a ^ 170);
	b = b*3 + (a ^ 183);
	b = b*4 + (a ^ 196);
	b = b*5 + (a ^ 209);
	b = b*6 + (a ^ 222);
	b = b*7 + (a ^ 235);
	b = b*8 + (a ^ 248);
	b = b*9 + (a ^ 261);
	b = b*3 + (a ^ 274);
	b = b*4 + (a ^ 287);
	b = b*5 + (a ^ 300);
	b = b*6 + (a ^ 313);
	b = b*7 + (a ^ 326);
	b = b*8 + (a ^ 339);
	b = b*9 + (a ^ 352);
	b = b*3 + (a ^ 365);
	b = b*4 + (a ^ 378);
	b = b*5 + (a ^ 391);
	b = b*6 + (a ^ 404);
	b = b*7 + (a ^ 417);
	b = b*8 + (a ^ 430);
	b = b*9 + (a ^ 443);
	b = b*3 + (a ^ 456);
	b = b*4 + (a ^ 469);
	b = b*5 + (a ^ 482);
	b = b*6 + (a ^ 495);
	b = b*7 + (a ^ 508);
	b = b*8 + (a ^ 521);
	b = b*9 + (a ^ 534);
	b = b*3 + (a ^ 547);
	b = b*4 + (a ^ 560);
	b = b*5 + (a ^ 573);
	b = b*6 + (a ^ 586);
	b = b*7 + (a ^ 599);
	b = b*8 + (a ^ 612);
	b = b*9 + (a ^ 625);
	b = b*3 + (a ^ 638);
	b = b*4 + (a ^ 651);
	b = b*5 + (a ^ 664);
	b = b*6 + (a ^ 677);
	b = b*7 + (a ^ 690);
	b = b*8 + (a ^ 703);
	b = b*9 + (a ^ 716);
	b = b*3 + (a ^ 729);
	b = b*4 + (a ^ 742);
	b = b*5 + (a ^ 755);
	b = b*6 + (a ^ 768);
	return b;
}
