implement Registry;
include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "bufio.m";
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbf, Dbentry: import attrdb;
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
	Enotdir, Enotfound, Eperm, Ebadfid: import Styxservers;
include "arg.m";

# files:
# 'new'
#	write name of new service; (and possibly attribute column names)
#		entry appears in directory of that name
#	can then write attributes/values
# 'index'
#	read to get info on all services and their attributes.
# 'find'
#	write to set filter.
#	read to get info on all services with matching attributes
# 'event' (not needed initially)
#	read to block until changes happen.
# servicename
#	write to change attributes (only by owner)
#	remove to unregister service.

Registry: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot,
Qnew,
Qindex,
Qevent,
Qfind,
Qsvc:	con iota;


Shift:	con 4;
Mask:	con 2r1111;

Egreg: con "buggy program!";
Maxreplyidle: con 3;

#
# What the registry will hold.  Anyone who can attach may register, and
# there was no end to it: services, their descriptions, filters and
# event readers were each kept without count, and a service registered
# to persist stayed for good once its owner had gone, its name taken
# and its address given to whoever asked.
#
Maxservices:	con 1024;	# registered at once, by everyone
Maxperowner:	con 128;	# and by one user
Maxattrs:	con 64;		# attributes of one service
Maxsvcbytes:	con 4096;	# its name, attribute names and values together
Maxfilters:	con 256;
Maxevents:	con 256;
Etoomany: con "too many services registered";
Etoomanyown: con "too many services registered in your name";

# a persistent service whose creator has closed lasts this long after
# its owner last wrote it (-t; 0 for ever)
life := 24*60*60;
nextexpire := 0;

Service: adt {
	id:		int;
	slot:		int;
	owner:	string;
	name:	string;
	atime:	int;
	mtime:	int;
	vers:		int;
	fid:		int;		# fid that created it (NOFID if static)
	static:	int;		# from the -f file: counted against nobody, never expires
	attrs:		list of (string, string);

	new:		fn(owner: string): ref Service;
	find:		fn(id: int): ref Service;
	remove:	fn(svc: self ref Service);
	set:		fn(svc: self ref Service, attr, val: string);
	get:		fn(svc: self ref Service, attr: string): string;
};

Filter: adt {
	id:		int;	# filter ID (it's a fid)
	attrs:		array of (string, string);

	new:		fn(id: int): ref Filter;
	find:		fn(id: int): ref Filter;
	set:		fn(f: self ref Filter, a: array of (string, string));
	match:	fn(f: self ref Filter, attrs: list of (string, string)): int;
	remove:	fn(f: self ref Filter);
};

Event: adt {
	id:		int;					# fid reading from Qevents
	vers:		int;					# last change seen
	m:		ref Tmsg.Read;			# outstanding read request

	new:		fn(id: int): ref Event;
	find:		fn(id: int): ref Event;
	remove:	fn(e: self ref Event);
	queue:	fn(e: self ref Event, m: ref Tmsg.Read): string;
	post:		fn(vers: int);
	flush:	fn(tag: int);
};

filters: list of ref Filter;
events: list of ref Event;

services := array[9] of ref Service;
nservices := 0;
idseq := 0;
rootvers := 0;
now: int;
startdate: int;
dbfile: string;

srv: ref Styxserver;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		loaderr(String->PATH);
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		loaderr(Daytime->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		loaderr(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		loaderr(Styxservers->PATH);
	styxservers->init(styx);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		loaderr(Arg->PATH);
	arg->init(args);
	arg->setusage("ndb/registry [-f initdb] [-t seconds]");
	while((o := arg->opt()) != 0)
		case o {
		'f' =>	dbfile = arg->earg();
		't' =>
			ts := arg->earg();
			if(ts == nil || !alldigits(ts) || len ts > 9)
				arg->usage();
			life = int ts;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();
	arg = nil;

	sys->pctl(Sys->FORKNS|Sys->NEWFD, 0::1::2::nil);
	startdate = now = daytime->now();
	if(dbfile != nil){
		attrdb = load Attrdb Attrdb->PATH;
		if(attrdb == nil)
			loaderr(Attrdb->PATH);
		attrdb->init();
		db := Db.open(dbfile);
		if(db == nil)
			error(sys->sprint("can't open %s: %r", dbfile));
		dbload(db);
		db = nil;	# for now assume it's static
		attrdb = nil;
	}
	navops := chan of ref Navop;
	spawn navigator(navops);
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navops), big Qroot);
	# serve until the connection ends, as export does: styxlisten(1)
	# takes a command that returns to have finished, and stops listening
	serve(tchan, navops);
}

loaderr(p: string)
{
	error(sys->sprint("can't load %s: %r", p));
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "registry: %s\n", s);
	raise "fail:error";
}

serve(tchan: chan of ref Tmsg, navops: chan of ref Navop)
{
Serve:
	while((gm := <-tchan) != nil){
		now = daytime->now();
		if(life > 0 && now >= nextexpire)
			expire();
		err := "";
		pick m := gm {
		Readerror =>
			sys->fprint(sys->fildes(2), "registry: styx read error: %s\n", m.error);
			break Serve;
		Open =>
			(fid, nil, nil, e) := srv.canopen(m);
			if((err = e) != nil)
				break;
			if(fid.qtype & Sys->QTDIR)
				srv.default(m);
			else
				open(m, fid);
		Read =>
			(fid, e) := srv.canread(m);
			if((err = e) != nil)
				break;
			if(fid.qtype & Sys->QTDIR)
				srv.read(m);
			else
				err = read(m, fid);
		Write =>
			(fid, e) := srv.canwrite(m);
			if((err = e) != nil)
				break;
			err = write(m, fid);
			if(err == nil)
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Clunk =>
			clunk(srv.clunk(m));
		Remove =>
			# canremove gives no fid when it refuses (the root, a
			# fid not in use): what it gave was clunked whatever
			# it was, and a remove of the registry's root, from
			# a mount or through an export of one, ended the
			# registry on a nil fid.
			fid := srv.getfid(m.fid);
			if(fid == nil){
				err = Ebadfid;
				break;
			}
			(nil, nil, e) := srv.canremove(m);
			srv.delfid(fid);	# always clunked even on error
			if(e == nil)
				e = remove(fid);
			if((err = e) != nil){
				clunk(fid);	# the fid has gone all the same
				break;
			}
			srv.reply(ref Rmsg.Remove(m.tag));
		Flush =>
			Event.flush(m.oldtag);
			srv.default(gm);
		* =>
			srv.default(gm);
		}
		if(err != "")
			srv.reply(ref Rmsg.Error(gm.tag, err));
	}
	navops <-= nil;
}

open(m: ref Tmsg.Open, fid: ref Fid)
{
	path := int fid.path;
	case path & Mask {
	Qsvc =>
		# closing a file opened ORCLOSE removes it, and removing a
		# service is its owner's to do
		svc := Service.find(path >> Shift);
		if(svc == nil){
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		if(m.mode & Sys->ORCLOSE && fid.uname != svc.owner){
			srv.reply(ref Rmsg.Error(m.tag, Eperm));
			return;
		}
		fid.open(m.mode, (fid.path, 0, fid.qtype));
	Qnew =>
		if(ndynamic() >= Maxservices){
			srv.reply(ref Rmsg.Error(m.tag, Etoomany));
			return;
		}
		if(nowned(fid.uname) >= Maxperowner){
			srv.reply(ref Rmsg.Error(m.tag, Etoomanyown));
			return;
		}
		svc := Service.new(fid.uname);
		svc.fid = fid.fid;
		fid.open(m.mode, (big ((svc.id << Shift)|Qsvc), 0, Sys->QTFILE));
	Qevent =>
		if(len events >= Maxevents){
			srv.reply(ref Rmsg.Error(m.tag, "too many readers of event"));
			return;
		}
		Event.new(fid.fid);
		fid.open(m.mode, (fid.path, 0, Sys->QTFILE));
	* =>
		fid.open(m.mode, (fid.path, 0, fid.qtype));
	}
	srv.reply(ref Rmsg.Open(m.tag, (fid.path, 0, fid.qtype), 0));
}

read(m: ref Tmsg.Read, fid: ref Fid): string
{
	path := int fid.path;
	case path & Mask {
	Qindex =>
		if(fid.data == nil || m.offset == big 0)
			fid.data = getindexdata(-1, Styx->NOFID);
		srv.reply(styxservers->readbytes(m, fid.data));
	Qfind =>
		if(fid.data == nil || m.offset == big 0)
			fid.data = getindexdata(-1, fid.fid);
		srv.reply(styxservers->readbytes(m, fid.data));
	Qsvc =>
		if(fid.data == nil || m.offset == big 0){
			svc := Service.find(path >> Shift);
			if(svc != nil)
				svc.atime = now;
			fid.data = getindexdata(path >> Shift, Styx->NOFID);
		}
		srv.reply(styxservers->readbytes(m, fid.data));
	Qevent =>
		e := Event.find(fid.fid);
		if(e == nil)
			return "event file not open";
		if(e.vers == rootvers)
			return e.queue(m);
		else{
			s := sys->sprint("%8.8d\n", rootvers);
			e.vers = rootvers;
			m.offset = big 0;
			srv.reply(styxservers->readstr(m, s));
			return nil;
		}
	* =>
		return Egreg;
	}
	return nil;
}

write(m: ref Tmsg.Write, fid: ref Fid): string
{
	path := int fid.path;
	case path & Mask {
	Qsvc =>
		svc := Service.find(path >> Shift);
		if(svc == nil)
			return "service has been removed";	# it said "buggy program!"
		s := string m.data;
		toks := str->unquoted(s);
		if(toks == nil)
			return "bad syntax";
		# first write names the service (possibly with attributes).
		# Nothing of a write is taken unless all of it is: a name
		# followed by an odd number of words was refused and the
		# service listed under the name all the same.
		name: string;
		if(svc.name == nil){
			name = hd toks;
			err := svcnameok(name);
			if(err != nil)
				return err;
			toks = tl toks;
		}
		if(len toks % 2 != 0)
			return "odd attribute/value pairs";
		for(tk := toks; tk != nil; tk = tl tl tk)
			if(hd tk == nil || !textok(hd tk) || !textok(hd tl tk))
				return "bad character in attribute";
		# what the service would be with this write, counted before
		# any of it is taken
		nm := svc.name;
		if(name != nil)
			nm = name;
		na := 0;
		nb := len array of byte nm;
		for(al := svc.attrs; al != nil; al = tl al){
			(an, av) := hd al;
			for(tk = toks; tk != nil; tk = tl tl tk)
				if(hd tk == an)
					break;
			if(tk == nil){	# one this write does not replace
				na++;
				nb += len array of byte an + len array of byte av;
			}
		}
		seen: list of string;
		for(tk = toks; tk != nil; tk = tl tl tk){
			for(sl := seen; sl != nil; sl = tl sl)
				if(hd sl == hd tk)
					break;
			if(sl == nil){
				seen = hd tk :: seen;
				na++;
			}
			nb += len array of byte hd tk + len array of byte hd tl tk;
		}
		if(na > Maxattrs)
			return "too many attributes";
		if(nb > Maxsvcbytes)
			return "service description too long";
		if(name != nil)
			svc.name = name;
		svc.mtime = now;
		svc.vers++;
		for(; toks != nil; toks = tl tl toks)
			svc.set(hd toks, hd tl toks);
		rootvers++;
		Event.post(rootvers);
	Qfind =>
		s := string m.data;
		toks := str->unquoted(s);
		n := len toks;
		if(n % 2 != 0)
			return "odd attribute/value pairs";
		f := Filter.find(fid.fid);
		if(n/2 > Maxattrs)
			return "too many attributes";
		if(f == nil && n != 0 && len filters >= Maxfilters)
			return "too many filters";
		if(n != 0){
			a := array[n/2] of (string, string);
			for(n=0; toks != nil; n++){
				a[n] = (hd toks, hd tl toks);
				toks = tl tl toks;
			}
			if(f == nil)
				f = Filter.new(fid.fid);
			f.set(a);
		}else{
			if(f != nil)
				f.remove();
		}
	* =>
		return "not a file that is written";
	}
	return nil;
}

alldigits(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

ndynamic(): int
{
	n := 0;
	for(i := 0; i < nservices; i++)
		if(!services[i].static)
			n++;
	return n;
}

nowned(owner: string): int
{
	n := 0;
	for(i := 0; i < nservices; i++)
		if(!services[i].static && services[i].owner == owner)
			n++;
	return n;
}

# Persistent services whose creators have closed and whose owners have
# not written them for life seconds are removed.  Looked at once a
# minute at most, when a request comes.
expire()
{
	nextexpire = now + 60;
	if(nextexpire > now + life)
		nextexpire = now + life;
	changed := 0;
	for(i := 0; i < nservices; ){
		svc := services[i];
		if(!svc.static && svc.fid == Styx->NOFID && now - svc.mtime >= life){
			svc.remove();	# another takes its slot: look at slot i again
			if(svc.name != nil)
				changed = 1;
		}else
			i++;
	}
	if(changed){
		rootvers++;
		Event.post(rootvers);
	}
}

#
# A service is its owner's: the user name its creator attached with.
# It goes when the fid that made it is closed (unless it is to persist),
# when its owner closes a fid opened ORCLOSE on it, and when its owner
# removes it.  The fid that made it was known by its number alone, and
# a client uses a number again as soon as it is free: after the creator
# had closed, any fid of that number opened ORCLOSE on the file, by
# anyone and for reading, removed a persistent service when it closed.
#
clunk(fid: ref Fid)
{
	if(fid == nil)
		return;	# not a fid in use: srv.clunk has said so
	path := int fid.path;
	case path & Mask {
	Qsvc =>
		svc := Service.find(path >> Shift);
		if(svc == nil)
			break;
		creator := svc.fid == fid.fid;
		if(creator)
			svc.fid = Styx->NOFID;	# the number is free for another fid now
		if(fid.uname == svc.owner &&
		   (fid.isopen && fid.mode & Sys->ORCLOSE || creator && int svc.get("persist") == 0)){
			svc.remove();
			if(svc.name != nil){	# otherwise there's no visible change
				rootvers++;
				Event.post(rootvers);
			}
		}
	Qevent =>
		if((e := Event.find(fid.fid)) != nil)
			e.remove();
	Qfind =>
		if((f := Filter.find(fid.fid)) != nil)
			f.remove();
	}
}

remove(fid: ref Fid): string
{
	path := int fid.path;
	if((path & Mask) == Qsvc){
		# it may have gone since the fid was walked to it (its
		# creator closed it): the owner of nothing was asked for
		svc := Service.find(path >> Shift);
		if(svc == nil)
			return Enotfound;
		if(fid.uname == svc.owner){
			svc.remove();
			if(svc.name != nil){
				rootvers++;
				Event.post(rootvers);
			}
			return nil;
		}
	}
	return Eperm;
}

# no control characters: a newline in a name or a value was another
# service's line to a reader of index
textok(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < 32 || s[i] == 16r7f)
			return 0;
	return 1;
}

svcnameok(s: string): string
{
	# could require that a service name contains at least one (or two) '!' characters.
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c <= 32 || c == '/' || c == 16r7f)
			return "bad character in service name";
	}
	case s {
	"new" or
	"event" or
	"find" or
	"index" or
	"." or
	".." or
	"" =>
		return "bad service name";
	}
	for(i = 0; i < nservices; i++)
		if(services[i].name == s)
			return "duplicate service name";
	return nil;
}

getindexdata(id: int, filterid: int): array of byte
{
	f: ref Filter;
	if(filterid != Styx->NOFID)
		f = Filter.find(filterid);
	s := "";
	for(i := 0; i < nservices; i++){
		svc := services[i];
		if(svc == nil || svc.name == nil)
			continue;
		if(id == -1){
			if(f != nil && !f.match(svc.attrs))
				continue;
		}else if(svc.id != id)
			continue;
		s += sys->sprint("%q", services[i].name);
		for(a := svc.attrs; a != nil; a = tl a){
			(attr, val) := hd a;
			s += sys->sprint(" %q %q", attr, val);
		}
		s[len s] = '\n';
	}
	return array of byte s;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		path := int m.path;
		pick n := m {
		Stat =>
			n.reply <-= dirgen(int n.path);
		Walk =>
			name := n.name;
			case path & Mask {
			Qroot =>
				case name{
				".." =>
					;	# nop
				"new" =>
					path = Qnew;
				"index" =>
					path = Qindex;
				"event" =>
					path = Qevent;
				"find" =>
					path = Qfind;
				* =>
					for(i := 0; i < nservices; i++)
						if(services[i].name == name){
							path = (services[i].id << Shift) | Qsvc;
							break;
						}
					if(i == nservices){
						n.reply <-= (nil, Enotfound);
						continue;
					}
				}
			* =>
				if(name == ".."){
					path = Qroot;
					break;
				}
				n.reply <-= (nil, Enotdir);
				continue;
			}
			n.reply <-= dirgen(path);
		Readdir =>
			d: array of int;
			case path & Mask {
			Qroot =>
				Nstatic:	con 4;
				d = array[Nstatic + nservices] of int;
				d[0] = Qnew;
				d[1] = Qindex;
				d[2] = Qfind;
				d[3] = Qevent;
				nd := 0;
				for(i := 0; i < nservices; i++)
					if(services[i].name != nil){
						d[nd + Nstatic] = (services[i].id<<Shift) | Qsvc;
						nd++;
					}
				d = d[0:Nstatic + nd];
			}
			if(d == nil){
				n.reply <-= (nil, Enotdir);
				break;
			}
			for(i := n.offset; i < len d; i++){
				(dir, err) := dirgen(d[i]);
				if(dir == nil)
					sys->fprint(sys->fildes(2), "registry: bad qid %#ux: %s\n", d[i], err);
				else
					n.reply <-= (dir, err);
			}
			n.reply <-= (nil, nil);
		}
	}
}

dirgen(path: int): (ref Sys->Dir, string)
{
	name: string;
	perm: int;
	svc: ref Service;
	case path & Mask {
	Qroot =>
		name = ".";
		perm = 8r777|Sys->DMDIR;
	Qnew =>
		name = "new";
		perm = 8r666;
	Qindex =>
		name = "index";
		perm = 8r444;
	Qevent =>
		name = "event";
		perm = 8r444;
	Qfind =>
		name = "find";
		perm = 8r666;
	Qsvc =>
		id := path >> Shift;
		for(i := 0; i < nservices; i++)
			if(services[i].id == id)
				break;
		if(i >= nservices)
			return (nil, Enotfound);
		svc = services[i];
		name = svc.name;
		perm = 8r644;
	* =>
		return (nil, Enotfound);
	}
	return (dir(path, name, perm, svc), nil);
}

dir(path: int, name: string, perm: int, svc: ref Service): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	d.name = name;
	if(svc != nil){
		d.uid = svc.owner;
		d.gid = svc.owner;
		d.atime = svc.atime;
		d.mtime = svc.mtime;
		d.qid.vers = svc.vers;
	}else{
		d.uid = "registry";
		d.gid = "registry";
		d.atime = startdate;
		d.mtime = startdate;
		if(path == Qroot)
			d.qid.vers = rootvers;
	}
	return d;
}

blanksvc: Service;
Service.new(owner: string): ref Service
{
	if(nservices == len services){
		s := array[nservices * 3 / 2] of ref Service;
		s[0:] = services;
		services = s;
	}
	svc := ref blanksvc;
	svc.id = idseq++;
	svc.owner = owner;
	svc.atime = now;
	svc.mtime = now;

	services[nservices] = svc;
	svc.slot = nservices;
	nservices++;
	return svc;
}

Service.find(id: int): ref Service
{
	for(i := 0; i < nservices; i++)
		if(services[i].id == id)
			return services[i];
	return nil;
}

Service.remove(svc: self ref Service)
{
	slot := svc.slot;
	services[slot] = nil;
	nservices--;
	if(slot != nservices){
		services[slot] = services[nservices];
		services[slot].slot = slot;
		services[nservices] = nil;
	}
}

Service.get(svc: self ref Service, attr: string): string
{
	for(a := svc.attrs; a != nil; a = tl a)
		if((hd a).t0 == attr)
			return (hd a).t1;
	return nil;
}

Service.set(svc: self ref Service, attr, val: string)
{
	for(a := svc.attrs; a != nil; a = tl a)
		if((hd a).t0 == attr)
			break;
	if(a == nil){
		svc.attrs = (attr, val) :: svc.attrs;
		return;
	}
	attrs := (attr, val) :: tl a;
	for(a = svc.attrs; a != nil; a = tl a){
		if((hd a).t0 == attr)
			break;
		attrs = hd a :: attrs;
	}
	svc.attrs = attrs;
}

Filter.new(id: int): ref Filter
{
	f := ref Filter(id, nil);
	filters = f :: filters;
	return f;
}

Filter.find(id: int): ref Filter
{
	if(id != Styx->NOFID)
		for(fl := filters; fl != nil; fl = tl fl)
			if((hd fl).id == id)
				return hd fl;
	return nil;
}

Filter.set(f: self ref Filter, a: array of (string, string))
{
	f.attrs = a;
}

Filter.remove(f: self ref Filter)
{
	rl: list of ref Filter;
	for(l := filters; l != nil; l = tl l)
		if((hd l).id != f.id)
			rl = hd l :: rl;
	filters = rl;
}

Filter.match(f: self ref Filter, attrs: list of (string, string)): int
{
	for(i := 0; i < len f.attrs; i++){
		(qn, qv) := f.attrs[i];
		for(al := attrs; al != nil; al = tl al){
			(n, v) := hd al;
			if(n == qn && (qv == "*" || v == qv))
				break;
		}
		if(al == nil)
			break;
	}
	return i == len f.attrs;
}

Event.new(id: int): ref Event
{
	e := ref Event(id, rootvers, nil);
	events = e::events;
	return e;
}

Event.find(id: int): ref Event
{
	for(l := events; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

Event.remove(e: self ref Event)
{
	rl: list of ref Event;
	for(l := events; l != nil; l = tl l)
		if((hd l).id != e.id)
			rl = hd l :: rl;
	events = rl;
}

Event.queue(e: self ref Event, m: ref Tmsg.Read): string
{
	if(e.m != nil)
		return "concurrent read for event fid";
	m.offset = big 0;
	e.m = m;
	return nil;
}

Event.post(vers: int)
{
	s := sys->sprint("%8.8d\n", vers);
	for(l := events; l != nil; l = tl l){
		e := hd l;
		if(e.vers < vers && e.m != nil){
			srv.reply(styxservers->readstr(e.m, s));
			e.vers = vers;
			e.m = nil;
		}
	}
}

Event.flush(tag: int)
{
	for(l := events; l != nil; l = tl l){
		e := hd l;
		if(e.m != nil && e.m.tag == tag){
			e.m = nil;
			break;
		}
	}
}

dbload(db: ref Db)
{
	ptr: ref Attrdb->Dbptr;
	for(;;){
		e: ref Dbentry;
		(e, ptr) = db.find(ptr, "service");
		if(e == nil)
			break;
		svcname := e.findfirst("service");
		if(svcname == nil || svcnameok(svcname) != nil)
			continue;
		svc := Service.new("registry");	 # TO DO: read user's name
		svc.name = svcname;
		svc.fid = Styx->NOFID;
		svc.static = 1;
		for(l := e.lines; l != nil; l = tl l){
			for(al := (hd l).pairs; al != nil; al = tl al){
				a := hd al;
				if(a.attr != "service")
					svc.set(a.attr, a.val);
			}
		}
	}
}

# return index i >= start such that
# s[i-1] == eoc, or len s if no such index exists.
# eoc shouldn't be '
qsplit(s: string, start: int, eoc: int): int
{
	inq := 0;
	for(i := start; i < len s;){
		c := s[i++];
		if(inq){
			if(c == '\'' && i < len s){
				if(s[i] == '\'')
					i++;
				else
					inq = 0;
			}
		}else{
			if(c == eoc)
				return i;
			if(c == '\'')
				inq = 1;
		}
	}
	return i;
}
