implement PoolNomemHelper;

#
# Driven by tests/host/pool_nomem_test.sh, under a main pool too small for
# what it asks: Keyring->aesgcmencrypt copies its plaintext into a buffer
# from the main pool, so a plaintext larger than the pool is refused there.
# Not a _test: under the suite's 1GB pool the allocation succeeds.
#
#	pool_nomem_helper n size
#
# asks n times for size bytes and prints what each attempt raised.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

PoolNomemHelper: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(len args != 3){
		sys->fprint(sys->fildes(2), "usage: pool_nomem_helper n size\n");
		raise "fail:usage";
	}
	n := int hd tl args;
	size := int hd tl tl args;
	st := kr->aesgcmsetup(array[16] of {* => byte 1}, array[12] of {* => byte 2});
	for(i := 0; i < n; i++){
		{
			kr->aesgcmencrypt(st, array[size] of byte, nil);
			sys->print("ATTEMPT %d: allocated\n", i);
		} exception e {
		"*" =>
			sys->print("ATTEMPT %d: raised %s\n", i, e);
		}
	}
	sys->print("HELPER DONE\n");
}
