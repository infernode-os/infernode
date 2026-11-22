implement Hashtest;
include "sys.m"; sys: Sys;
include "draw.m";
Hashtest: module { init: fn(nil: ref Draw->Context, nil: list of string); };
include "dat.b";
include "hash.b";
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	buf := array[16384] of byte;
	for(i := 0; i < len buf; i++)
		buf[i] = byte (i*131+7);
	lens := array[] of {0,1,2,3,4,5,7,8,9,15,16,17,31,32,33,63,64,100,1000,16384};
	for(j := 0; j < len lens; j++)
		sys->print("%d %16.16bux\n", lens[j], metrohash64(buf, lens[j], 16r6765));
	sys->print("ihash %8.8ux %8.8ux\n", ihash(big 12345), ihash(big 16rdeadbeefcafe));
}
