implement AppfsFake;

#
# appfs_fake - stand-in for a program serving its files (appfs(2)), for
# tests: appfs_fake spec file ... posts #s<spec>/fs serving the files,
# each read answered "<spec> <file>", each write accepted, and stays
# until killed.  tools9p_integration_test runs one each for shell,
# fractal and man.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "appfs.m";

AppfsFake: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	appfs := load Appfs Appfs->PATH;
	if(appfs == nil || appfs->init() != nil || len args < 3) {
		sys->fprint(sys->fildes(2), "usage: appfs_fake spec file ...\n");
		raise "fail:usage";
	}
	spec := hd tl args;
	n := len args - 2;
	files := array[n] of string;
	i := 0;
	for(a := tl tl args; a != nil; a = tl a)
		files[i++] = hd a;
	reqs := chan of ref Appfs->Req;
	(nil, tether, err) := appfs->serve(spec, files, reqs);
	if(err != nil) {
		sys->fprint(sys->fildes(2), "appfs_fake: %s\n", err);
		raise "fail:serve";
	}
	for(;;) {
		r := <-reqs;
		if(r.data == nil)
			r.reply <-= spec + " " + r.file + "\n";
		else
			r.reply <-= nil;
	}
	tether = nil;
}
