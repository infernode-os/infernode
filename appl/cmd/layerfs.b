implement Layerfs;

#
# layerfs - a directory where any file written is a layer (#1095).
#
#	mount -ac {layerfs} /mnt/video/0/layer
#	echo 'frame=* box x0=100 y0=80 x1=500 y1=400 label=door' > /mnt/video/0/layer/roi
#	vision/watch /mnt/video/0 | grep 'class=person' > /mnt/video/0/layer/people
#	rm /mnt/video/0/layer/people
#
# Union-mounted with create over a feed's layer/ directory, it makes
# whatever is written into the stack a layer: a file written once, or
# one written to continuously, a stream. Each file keeps only what is
# due now: its records for the newest frame written, and its frame=*
# records, never the history. A reader gets those at its open, in one
# read, and then the records written after, as they are written, a
# read waiting while there are none; so layers(2) reads a file written
# once as it reads a session's detections.
#
# Opening a file to write with truncation (> in the shell) rewrites
# it: what it held is gone, and its version and time change, which is
# how a viewer (layers(2)) knows to read it again. Writing on does not
# change them: a stream is read as it comes. A line that is no record
# (layers(2)'s parse) is not kept. A file removed ends its readers.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "layers.m";
	layers: Layers;

Layerfs: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot: con 0;
Keep: con 512;		# the lines kept for readers that have not had them

File: adt {
	path:	big;
	name:	string;
	vers:	int;
	star:	list of string;		# frame=* records, newest first
	frame:	int;			# the newest frame written, -1 none
	flines:	list of string;		# its records, newest first
	seq:	int;			# lines written since the last rewrite
	log:	array of (int, string);	# the last Keep of them, by seq
	gone:	int;
};

Rd: adt {
	fid:	int;
	f:	ref File;
	pos:	int;		# the next line it has not had
	fresh:	int;		# its next read is what is due now
	part:	string;		# a writer's line not yet ended
	writer:	int;
};

files: list of ref File;
rds: list of ref Rd;
parked: list of ref Tmsg.Read;
nextpath := big 1;
srv: ref Styxserver;
tree: ref Tree;
user := "inferno";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	layers = load Layers Layers->PATH;
	if(styx == nil || styxservers == nil || nametree == nil || layers == nil){
		sys->fprint(sys->fildes(2), "layerfs: cannot load a module: %r\n");
		raise "fail:load";
	}
	if((e := layers->init()) != nil){
		sys->fprint(sys->fildes(2), "layerfs: %s\n", e);
		raise "fail:init";
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();
	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";

	treeop: chan of ref Styxservers->Navop;
	(tree, treeop) = nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r777, big Qroot, 0));
	tc: chan of ref Tmsg;
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	serve(tc);
	tree.quit();
}

serve(tc: chan of ref Tmsg)
{
	while((tmsg := <-tc) != nil){
		pick tm := tmsg {
		Readerror =>
			return;
		Create =>
			(c, mode, d, e) := srv.cancreate(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			if(d.mode & Sys->DMDIR){
				srv.reply(ref Rmsg.Error(tm.tag, "layerfs: a layer is a file"));
				break;
			}
			d.qid.path = nextpath++;
			d.mtime = d.atime = now();
			if((e = tree.create(c.path, *d)) != nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			f := ref File(d.qid.path, d.name, 0, nil, -1, nil, 0, array[Keep] of (int, string), 0);
			files = f :: files;
			c.open(mode, d.qid);
			opened(c, f, mode);
			srv.reply(ref Rmsg.Create(tm.tag, d.qid, srv.iounit()));
		Open =>
			(c, mode, d, e) := srv.canopen(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			f := findfile(d.qid.path);
			if(f != nil && (tm.mode & Sys->OTRUNC) && (mode & 3) != Sys->OREAD){
				rewrite(f);
				(d, nil) = srv.t.stat(f.path);
			}
			c.open(mode, d.qid);
			if(f != nil)
				opened(c, f, mode);
			srv.reply(ref Rmsg.Open(tm.tag, d.qid, srv.iounit()));
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.read(tm);
				break;
			}
			r := findrd(tm.fid);
			if(r == nil){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			if(!answer(tm, r))
				parked = tm :: parked;
		Write =>
			(c, e) := srv.canwrite(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			r := findrd(tm.fid);
			if(r == nil || r.f.gone){
				srv.reply(ref Rmsg.Error(tm.tag, "layerfs: removed"));
				break;
			}
			written(r, string tm.data);
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			wake(r.f);
		Remove =>
			(c, nil, e) := srv.canremove(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			f := findfile(c.path);
			if((e = tree.remove(c.path)) != nil){
				srv.reply(ref Rmsg.Error(tm.tag, e));
				break;
			}
			if(f != nil)
				removed(f);
			dropfid(tm.fid);
			srv.delfid(c);
			srv.reply(ref Rmsg.Remove(tm.tag));
		Clunk =>
			dropfid(tm.fid);
			srv.default(tmsg);
		Flush =>
			np: list of ref Tmsg.Read;
			for(p := parked; p != nil; p = tl p)
				if((hd p).tag != tm.oldtag)
					np = hd p :: np;
			parked = np;
			srv.default(tmsg);
		* =>
			srv.default(tmsg);
		}
	}
}

opened(c: ref Fid, f: ref File, mode: int)
{
	r := ref Rd(c.fid, f, f.seq, 1, "", (mode & 3) != Sys->OREAD);
	rds = r :: rds;
}

# what it held gone, its version and time new: read it again
rewrite(f: ref File)
{
	f.star = nil;
	f.frame = -1;
	f.flines = nil;
	f.seq = 0;
	f.vers++;
	d := sys->nulldir;
	d.qid.vers = f.vers;
	d.mtime = now();
	tree.wstat(f.path, d);
	for(l := rds; l != nil; l = tl l)
		if((hd l).f == f){
			(hd l).pos = 0;
			(hd l).fresh = 1;
		}
}

written(r: ref Rd, s: string)
{
	s = r.part + s;
	r.part = "";
	for(;;){
		i := 0;
		while(i < len s && s[i] != '\n')
			i++;
		if(i == len s){
			r.part = s;
			return;
		}
		addline(r.f, s[0:i]);
		s = s[i+1:];
	}
}

addline(f: ref File, line: string)
{
	(fr, nil) := layers->parse(line);
	if(fr == -2)
		return;		# no record
	if(fr == -1)
		f.star = line :: f.star;
	else if(fr != f.frame){
		f.frame = fr;
		f.flines = line :: nil;
	} else
		f.flines = line :: f.flines;
	f.log[f.seq % Keep] = (f.seq, line);
	f.seq++;
}

# 1 if answered
answer(tm: ref Tmsg.Read, r: ref Rd): int
{
	f := r.f;
	if(f.gone){
		srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
		return 1;
	}
	text := "";
	if(r.fresh || r.pos < f.seq - Keep){
		# what is due now: the frame=* records and the newest frame's
		for(l := rev(f.star); l != nil; l = tl l)
			text += hd l + "\n";
		for(l = rev(f.flines); l != nil; l = tl l)
			text += hd l + "\n";
		r.fresh = 0;
		r.pos = f.seq;
	} else {
		while(r.pos < f.seq){
			(n, line) := f.log[r.pos % Keep];
			if(n != r.pos)
				break;
			if(text != nil && len array of byte (text + line) >= tm.count)
				break;
			text += line + "\n";
			r.pos++;
		}
	}
	if(text == nil)
		return 0;
	b := array of byte text;
	if(len b > tm.count)
		b = b[0:tm.count];
	srv.reply(ref Rmsg.Read(tm.tag, b));
	return 1;
}

wake(f: ref File)
{
	np: list of ref Tmsg.Read;
	for(p := parked; p != nil; p = tl p){
		tm := hd p;
		r := findrd(tm.fid);
		if(r == nil || r.f != f || !answer(tm, r))
			np = tm :: np;
	}
	parked = np;
}

removed(f: ref File)
{
	f.gone = 1;
	nf: list of ref File;
	for(l := files; l != nil; l = tl l)
		if(hd l != f)
			nf = hd l :: nf;
	files = nf;
	wake(f);
}

dropfid(fid: int)
{
	nr: list of ref Rd;
	for(l := rds; l != nil; l = tl l){
		r := hd l;
		if(r.fid != fid){
			nr = r :: nr;
			continue;
		}
		# a line the writer did not end is the file's when it closes
		if(r.writer && r.part != nil && !r.f.gone){
			addline(r.f, r.part);
			wake(r.f);
		}
	}
	rds = nr;
	np: list of ref Tmsg.Read;
	for(p := parked; p != nil; p = tl p)
		if((hd p).fid != fid)
			np = hd p :: np;
	parked = np;
}

findfile(path: big): ref File
{
	for(l := files; l != nil; l = tl l)
		if((hd l).path == path)
			return hd l;
	return nil;
}

findrd(fid: int): ref Rd
{
	for(l := rds; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

now(): int
{
	s := readfile("/dev/time");
	if(s == nil)
		return 0;
	return int (big s / big 1000000);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

dir(name: string, perm: int, path: big, mtime: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	d.mtime = d.atime = mtime;
	return d;
}
