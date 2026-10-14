implement Dict;

# Dict word: look word up with dict(1) in a new window.
# The OED when /lib/dict/oed2 is in the namespace (see dict(7)).
#
# The editor binds its command directory before /dis.  On a
# case-insensitive host Dict and dict.dis are then the same name,
# both ways: a script named Dict hides /dis/dict, and adict's own
# dict(1) would load this module again.  So Dict is a module (the
# editor looks for Dict.dis first), and it takes the editors'
# directories back out of /dis in its own name space.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";

Dict: module {
	init: fn(ctxt: ref Draw->Context, argl: list of string);
};

ADICT: con "/dis/dict/adict.dis";

init(ctxt: ref Draw->Context, argl: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKNS, nil);
	sys->unmount("/acme/dis", "/dis");
	sys->unmount("/xenith/dis", "/dis");
	adict := load Command ADICT;
	if(adict == nil){
		sys->fprint(sys->fildes(2), "Dict: can't load %s: %r\n", ADICT);
		raise "fail:load";
	}
	if(argl != nil)
		argl = tl argl;
	adict->init(ctxt, "adict" :: argl);
}
