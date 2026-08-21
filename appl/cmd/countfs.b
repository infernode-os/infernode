implement Countfs;

#
# countfs -- a minimal 9P counter service, written as the worked
# example for docs/TUTORIAL-9P-SERVICE.md.  Read this file and the
# tutorial side by side.
#
# The namespace IS the interface:
#
#	ctl	write-only (222):  'add n' | 'set n' | 'reset'
#	value	read-only  (444):  current count, decimal text, one line
#	log	read-only  (444):  one line per change, oldest first:
#				   <rfc3339-utc> <verb> <old> <new>
#
# Serve and mount it in one step:
#
#	mount {countfs} /mnt/count
#
# Design notes (the reasoning lives in docs/DESIGN-PRINCIPLES.md):
#   - /mnt/count, not /n/count: this program authors the schema.
#   - access control is the file modes: ctl cannot be read, value and
#     log cannot be written.  No policy code.
#   - all data is text lines; the log is greppable and awkable.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Countfs: module {
	PATH: con "/dis/countfs.dis";
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# One small-integer Qid path per file: the case labels of the serve loop.
Qdir, Qctl, Qvalue, Qlog: con iota;

MAXLOG: con 64;			# changes kept in the log

tc: chan of ref Tmsg;
srv: ref Styxserver;

count := 0;
lg := "";			# rendered log, one line per change
nlg := 0;

user := "inferno";

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

badmod(path: string)
{
	sys->fprint(sys->fildes(2), "countfs: cannot load %s: %r\n", path);
	raise "fail:load";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		badmod(Daytime->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		badmod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		badmod(Styxservers->PATH);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		badmod(Nametree->PATH);
	styx->init();
	styxservers->init(styx);
	nametree->init();

	# The namespace sketch, verbatim: modes are the access policy.
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, dir("ctl", 8r222, Qctl));
	tree.create(big Qdir, dir("value", 8r444, Qvalue));
	tree.create(big Qdir, dir("log", 8r444, Qlog));

	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
	serve(tree);
}

serve(tree: ref Tree)
{
	while((tmsg := <-tc) != nil){
		pick tm := tmsg {
		Readerror =>
			break;
		Flush =>
			# no blocking reads are held, so nothing to cancel
			srv.reply(ref Rmsg.Flush(tm.tag));
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);	# navigator answers directory reads
			Qvalue =>
				srv.reply(styxservers->readstr(tm, sys->sprint("%d\n", count)));
			Qlog =>
				srv.reply(styxservers->readstr(tm, lg));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			if(int c.path != Qctl){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
				continue;
			}
			err := ctlwrite(string tm.data);
			if(err != nil)
				srv.reply(ref Rmsg.Error(tm.tag, err));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Clunk =>
			srv.clunk(tm);
		* =>
			srv.default(tmsg);
		}
	}
	tree.quit();
}

# One text verb per write; the write format matches what a person
# would type: echo add 5 > /mnt/count/ctl
ctlwrite(s: string): string
{
	(n, flds) := sys->tokenize(s, " \t\n");
	if(n < 1)
		return "usage: add n | set n | reset";
	old := count;
	verb := hd flds;
	case verb {
	"add" =>
		if(n != 2)
			return "usage: add n";
		count += int hd tl flds;
	"set" =>
		if(n != 2)
			return "usage: set n";
		count = int hd tl flds;
	"reset" =>
		if(n != 1)
			return "usage: reset";
		count = 0;
	* =>
		return "unknown control request";
	}
	logchange(verb, old, count);
	return nil;
}

logchange(verb: string, old, new: int)
{
	if(nlg >= MAXLOG){
		# drop the oldest line
		for(i := 0; i < len lg; i++)
			if(lg[i] == '\n'){
				lg = lg[i+1:];
				break;
			}
	}else
		nlg++;
	lg += sys->sprint("%s %s %d %d\n", rfc3339(), verb, old, new);
}

# RFC 3339 UTC, per docs/9p-data-conventions.md: text, sorts
# lexicographically, no embedded spaces.
rfc3339(): string
{
	tm := daytime->gmt(daytime->now());
	return sys->sprint("%.4d-%.2d-%.2dT%.2d:%.2d:%.2dZ",
		tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
}
