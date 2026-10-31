implement ViewRemoveHelper;

#
# For tests/tools9p/view.sh: speaks 9P to tools9p's /mnt/toolctl/view
# itself.  A remove there is refused, and a remove clunks its fid
# whether it succeeds or not: the same fid walked again at once must
# work.  The relay refused the remove without telling the export, which
# kept the fid, so the walk was refused "fid in use".  Prints one line:
# "remove: <reply>" then "walk again: <reply>".
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

ViewRemoveHelper: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

fd: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	path := "/mnt/toolctl/view";
	names := array[] of {"usr", "inferno", "README"};
	if(args != nil && tl args != nil)
		path = hd tl args;
	fd = sys->open(path, Sys->ORDWR);
	if(fd == nil) {
		sys->print("open %s: %r\n", path);
		return;
	}
	rpc(ref Tmsg.Version(Styx->NOTAG, Styx->MAXRPC, "9P2000"));
	rpc(ref Tmsg.Attach(1, 1, Styx->NOFID, "none", ""));
	rpc(ref Tmsg.Walk(2, 1, 2, names));
	sys->print("remove: %s\n", rpc(ref Tmsg.Remove(3, 2)));
	sys->print("walk again: %s\n", rpc(ref Tmsg.Walk(4, 1, 2, names)));
}

# one message and its reply, as text
rpc(t: ref Tmsg): string
{
	b := t.pack();
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write: %r");
	r := Rmsg.read(fd, Styx->MAXRPC);
	if(r == nil)
		return "no reply";
	pick m := r {
	Error =>
		return "error " + m.ename;
	Walk =>
		return sys->sprint("walk %d", len m.qids);
	Remove =>
		return "removed";
	}
	return "ok";
}
