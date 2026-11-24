implement Rimport;

#
# rimport(1): a 9front machine's tree mounted here, as 9front's rimport
# does it: rcpu's connection (rconnect(2)), 9front's exportfs at the far
# end serving the tree over it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "factotum.m";

include "rconnect.m";
	rc: Rconnect;

Rimport: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

fail(s: string)
{
	sys->fprint(sys->fildes(2), "rimport: %s\n", s);
	raise "fail:"+s;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("rimport [-abc] [-k keypattern] [-u user] host tree mountpoint");
	flags := Sys->MREPL;
	keyspec := "";
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	flags = Sys->MAFTER | (flags & Sys->MCREATE);
		'b' =>	flags = Sys->MBEFORE | (flags & Sys->MCREATE);
		'c' =>	flags |= Sys->MCREATE;
		'k' =>	keyspec += " "+arg->earg();
		'u' =>	keyspec += " user="+arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 3)
		arg->usage();
	host := hd args;
	tree := hd tl args;
	mtpt := hd tl tl args;

	rc = load Rconnect Rconnect->PATH;
	if(rc == nil)
		fail(sys->sprint("cannot load %s: %r", Rconnect->PATH));
	if((e := rc->init()) != nil)
		fail(e);
	script := "tree="+rc->rcquote(tree)+"\nexec /bin/exportfs -r $tree\n";
	(fd, nil, err) := rc->connect(host, keyspec, script);
	if(fd == nil)
		fail(err);
	if(sys->mount(fd, nil, mtpt, flags, nil) < 0)
		fail(sys->sprint("mount %s: %r", mtpt));
}
