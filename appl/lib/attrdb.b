implement Attrdb;

#
# Copyright © 2003 Vita Nuova Holdings Limited.  All rights reserved.
#

include "sys.m";
	sys: Sys;

include "bufio.m";

include "attrdb.m";

#
# A database file is read whole when it is opened or reopened, and
# searched in memory.  It used to be searched through one shared Iobuf
# under a lock (a buffered channel) held for the whole scan of a file:
# a Prog killed during a scan died holding it, and every later search
# of that file waited for ever.  ndb/cs kills a query's Prog whenever
# its client goes away, so one interrupted dial stopped name
# translation for the machine.  Now a search holds nothing: it takes
# the bytes as they were when it began, and a reopen replaces them
# with one assignment.
#
Maxfile:	con 16*1024*1024;	# a database is a small text file; more is refused
Maxerrs:	con 16;		# complaints kept for each file

init(): string
{
	sys = load Sys Sys->PATH;
	return nil;
}

parseentry(s: string, lno: int): (ref Dbentry, int, string)
{
	(nil, flds) := sys->tokenize(s, "\n");
	lines: list of ref Tuples;
	errs: string;
	for(; flds != nil; flds = tl flds){
		(ts, err) := parseline(hd flds, lno);
		if(ts != nil)
			lines = ts :: lines;
		else if(err != nil && errs == nil)
			errs = err;
		lno++;
	}
	return (ref Dbentry(0, rev(lines)), lno, errs);	# in the order written (they were reversed)
}

parseline(s: string, lno: int): (ref Tuples, string)
{
	attrs: list of ref Attr;
	quote := 0;
	word := "";
	lastword := "";
	name := "";

Line:
	for(i := 0; i < len s; i++) {
		if(quote) {
			if(s[i] == quote) {
				if(i+1 >= len s || s[i+1] != quote){
					quote = 0;
					continue;
				}
				i++;
			}
			word[len word] = s[i];
			continue;
		}
		case s[i] {
		'\'' or '\"' =>
			quote = s[i];
		'#' =>
			break Line;
		' ' or '\t' or '\n' =>
			if(word == nil)
				continue;
			if(lastword != nil) {
				# lastword space word space
				attrs = ref Attr(lastword, nil, 0) :: attrs;
			}
			lastword = word;
			word = nil;

			if(name != nil) {
				# name = lastword space
				attrs = ref Attr(name, lastword, 0) :: attrs;
				name = lastword = nil;
			}
		'=' =>
			if(lastword == nil) {
				# word=
				lastword = word;
				word = nil;
			}
			if(word != nil) {
				# lastword word=
				attrs = ref Attr(lastword, nil, 0) :: attrs;
				lastword = word;
				word = nil;
			}
			if(lastword == nil)
				return (nil, "empty name");
			name = lastword;
			lastword = nil;
		* =>
			word[len word] = s[i];
		}
	}
	if(quote)
		return (nil, "missing quote");

	if(lastword == nil) {
		lastword = word;
		word = nil;
	}

	if(name == nil) {
		name = lastword;
		lastword = nil;
	}

	if(name != nil)
		attrs = ref Attr(name, lastword, 0) :: attrs;

	if(attrs == nil)
		return (nil, nil);

	return (ref Tuples(lno, rev(attrs)), nil);

}

Tuples.hasattr(ts: self ref Tuples, attr: string): int
{
	for(pl := ts.pairs; pl != nil; pl = tl pl){
		a := hd pl;
		if(a.attr == attr)
			return 1;
	}
	return 0;
}

Tuples.haspair(ts: self ref Tuples, attr: string, value: string): int
{
	for(pl := ts.pairs; pl != nil; pl = tl pl){
		a := hd pl;
		if(a.attr == attr && a.val == value)
			return 1;
	}
	return 0;
}

Tuples.find(ts: self ref Tuples, attr: string): list of ref Attr
{
	ra: list of ref Attr;
	for(pl := ts.pairs; pl != nil; pl = tl pl){
		a := hd pl;
		if(a.attr == attr)
			ra = a :: ra;
	}
	return rev(ra);
}

Tuples.findbyattr(ts: self ref Tuples, attr: string, value: string, rattr: string): list of ref Attr
{
	if(ts.haspair(attr, value))
		return ts.find(rattr);
	return nil;
}

Dbentry.find(e: self ref Dbentry, attr: string): list of (ref Tuples, list of ref Attr)
{
	rrt: list of (ref Tuples, list of ref Attr);
	for(lines := e.lines; lines != nil; lines = tl lines){
		l := hd lines;
		if((ra := l.find(attr)) != nil)
			rrt = (l, ra) :: rrt;	# Tuples.find gives them in the line's order (they were reversed again here)
	}
	rt: list of (ref Tuples, list of ref Attr);
	for(; rrt != nil; rrt = tl rrt)
		rt = hd rrt :: rt;
	return rt;
}

Dbentry.findfirst(e: self ref Dbentry, attr: string): string
{
	for(lines := e.lines; lines != nil; lines = tl lines){
		l := hd lines;
		for(pl := l.pairs; pl != nil; pl = tl pl)
			if((hd pl).attr == attr)
				return (hd pl).val;
	}
	return nil;
}

Dbentry.findpair(e: self ref Dbentry, attr: string, value: string): list of ref Tuples
{
	rts: list of ref Tuples;
	for(lines := e.lines; lines != nil; lines = tl lines){
		l := hd lines;
		if(l.haspair(attr, value))
			rts = l :: rts;
	}
	for(; rts != nil; rts = tl rts)
		lines = hd rts :: lines;
	return lines;
}

Dbentry.findbyattr(e: self ref Dbentry, attr: string, value: string, rattr: string): list of (ref Tuples, list of ref Attr)
{
	rm: list of (ref Tuples, list of ref Attr);	# lines with attr=value and rattr
	rnm: list of (ref Tuples, list of ref Attr);	# lines with rattr alone
	for(lines := e.lines; lines != nil; lines = tl lines){
		l := hd lines;
		ra: list of ref Attr = nil;
		match := 0;
		for(pl := l.pairs; pl != nil; pl = tl pl){
			a := hd pl;
			if(a.attr == attr && a.val == value)
				match = 1;
			if(a.attr == rattr)
				ra = a :: ra;
		}
		if(ra != nil){
			if(match)
				rm = (l, rev(ra)) :: rm;
			else
				rnm = (l, rev(ra)) :: rnm;
		}
	}
	rt: list of (ref Tuples, list of ref Attr);
	for(; rnm != nil; rnm = tl rnm)
		rt = hd rnm :: rt;
	for(; rm != nil; rm = tl rm)
		rt = hd rm :: rt;
	return rt;
}

#
# read a file whole; the error is also left for %r
#
readfile(path: string): (array of byte, ref Sys->Dir, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("%r"));
	dir: ref Sys->Dir;
	(ok, d) := sys->fstat(fd);
	if(ok >= 0)
		dir = ref d;
	buf := array[8192] of byte;
	n := 0;
	for(;;){
		if(n == len buf){
			if(len buf >= Maxfile){
				sys->werrstr("database file too large");
				return (nil, nil, "database file too large");
			}
			nb := array[2*len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		r := sys->read(fd, buf[n:], len buf-n);
		if(r < 0)
			return (nil, nil, sys->sprint("%r"));	# a read error is not an empty file
		if(r == 0)
			break;
		n += r;
	}
	return (buf[0:n], dir, nil);
}

#
# the lines of a file that are not attribute lines: an entry is still
# made of its other lines, so say which were left out
#
complaints(name: string, data: array of byte): list of string
{
	errs: list of string;
	nerr := 0;
	lno := 1;
	for(o := 0; o < len data; lno++){
		l: string;
		(l, o) = getline(data, o);
		(nil, err) := parseline(l, lno);
		if(err != nil && nerr++ < Maxerrs)
			errs = sys->sprint("%s:%d: %s", name, lno, err) :: errs;
	}
	return rev(errs);
}

getline(data: array of byte, o: int): (string, int)
{
	if(o >= len data)
		return (nil, o);
	for(e := o; e < len data; e++)
		if(data[e] == byte '\n'){
			e++;
			break;
		}
	return (string data[o:e], e);
}

Dbf.open(path: string): ref Dbf
{
	(data, dir, nil) := readfile(path);
	if(data == nil)
		return nil;
	df := ref Dbf;
	df.name = path;
	df.data = data;
	df.dir = dir;
	df.errs = complaints(path, data);
	# TO DO: indices
	return df;
}

#
# a file a database names that cannot be read: it has no entries, says
# why, and is looked for again at each reopen
#
missing(path: string, err: string): ref Dbf
{
	df := ref Dbf;
	df.name = path;
	df.errs = sys->sprint("%s: %s", path, err) :: nil;
	return df;
}

Dbf.sopen(data: string): ref Dbf
{
	df := ref Dbf;
	df.data = array of byte data;
	if(df.data == nil)
		df.data = array[0] of byte;
	df.name = nil;
	df.dir = nil;
	df.errs = complaints("<string>", df.data);
	return df;
}

Dbf.reopen(df: self ref Dbf): int
{
	if(df.name == nil)
		return 0;
	(data, dir, err) := readfile(df.name);
	if(data == nil){
		# the file has gone or cannot be read: it has no entries
		# now (the entries last read used to go on being found)
		df.data = nil;
		df.dir = nil;
		df.errs = sys->sprint("%s: %s", df.name, err) :: nil;
		return -1;
	}
	df.data = data;
	df.dir = dir;
	df.errs = complaints(df.name, data);
	# TO DO: cache, hash tables
	return 0;
}

Dbf.changed(df: self ref Dbf): int
{
	if(df.name == nil)
		return 0;
	(ok, d) := sys->stat(df.name);
	if(ok < 0)
		return df.data != nil;	# it was there when last read
	return df.dir == nil || !samefile(*df.dir, d);
}

samefile(d1, d2: Sys->Dir): int
{
	# ``it was black ... it was white!  it was dark ...  it was light! ah yes, i remember it well...''
	return d1.dev==d2.dev && d1.dtype==d2.dtype &&
			d1.qid.path==d2.qid.path && d1.qid.vers==d2.qid.vers &&
			d1.mtime == d2.mtime;
}

flatten(ts: list of (ref Tuples, list of ref Attr), attr: string): list of ref Attr
{
	l: list of ref Attr;
	for(; ts != nil; ts = tl ts){
		(line, nil) := hd ts;
		t := line.find(attr);
		for(; t != nil; t = tl t)
			l = hd t :: l;
	}
	return rev(l);
}

Db.open(path: string): ref Db
{
	df := Dbf.open(path);
	if(df == nil)
		return nil;
	db := ref Db(df :: nil);
	(e, nil) := db.findpair(nil, "database", "");
	if(e != nil){
		files := flatten(e.find("file"), "file");
		if(files != nil){
			dbs: list of ref Dbf;
			for(; files != nil; files = tl files){
				name := (hd files).val;
				if(name == path && df != nil){
					dbs = df :: dbs;
					df = nil;
				}else{
					# a file that cannot be read was left out
					# without a word, for good
					tf := Dbf.open(name);
					if(tf == nil)
						tf = missing(name, sys->sprint("%r"));
					dbs = tf :: dbs;
				}
			}
			db.dbs = rev(dbs);
			if(df != nil)
				db.dbs = df :: db.dbs;
		}
	}
	return db;
}

Db.sopen(data: string): ref Db
{
	df := Dbf.sopen(data);
	if(df == nil)
		return nil;
	return ref Db(df :: nil);
}

Db.append(db1: self ref Db, db2: ref Db): ref Db
{
	if(db1 == nil)
		return db2;
	if(db2 == nil)
		return db1;
	dbs := db2.dbs;
	for(rl := rev(db1.dbs); rl != nil; rl = tl rl)
		dbs = hd rl :: dbs;
	return ref Db(dbs);
}

Db.reopen(db: self ref Db): int
{
	f := 0;
	for(dbs := db.dbs; dbs != nil; dbs = tl dbs)
		if((hd dbs).reopen() < 0)
			f = -1;
	return f;
}

Db.changed(db: self ref Db): int
{
	f := 0;
	for(dbs := db.dbs; dbs != nil; dbs = tl dbs)
		f |= (hd dbs).changed();
	return f;
}

isentry(l: string): int
{
	return l!=nil && l[0]!='\t' && l[0]!='\n' && l[0]!=' ' && l[0]!='#';
}

Dbf.readentry(dbf: self ref Dbf, offset: int, attr: string, value: string, useval: int): (ref Dbentry, int, int)
{
	data := dbf.data;	# the file as it is now; a reopen does not change these bytes
	if(data == nil || offset < 0)
		return (nil, 0, offset);
	# an offset kept from before a reopen need not start a line
	# in the file as it is now: go on from the next that does
	if(offset > 0 && offset <= len data && data[offset-1] != byte '\n')
		(nil, offset) = getline(data, offset);
	lines: list of ref Tuples;
	match := attr == nil;
	l: string;
	o := offset;
	(l, o) = getline(data, o);
	while(l != nil){
		if(!isentry(l)){
			(l, o) = getline(data, o);
			continue;
		}
		lines = nil;
		do{
			offset = o;
			(t, nil) := parseline(l, 0);
			if(t != nil){
				lines = t :: lines;
				if(!match){
					if(useval)
						match = t.haspair(attr, value);
					else
						match = t.hasattr(attr);
				}
			}
			(l, o) = getline(data, o);
		}while(l != nil && !isentry(l));
		if(match && lines != nil)
			return (ref Dbentry(0, rev(lines)), 1, offset);
	}
	return (nil, 0, len data);
}

nextentry(db: ref Db, ptr: ref Dbptr, attr: string, value: string, useval: int): (ref Dbentry, ref Dbptr)
{
	if(ptr == nil){
		ptr = ref Dbptr.Direct(db.dbs, nil, 0);
		# TO DO: index
	}
	while(ptr.dbs != nil){
		offset: int;
		dbf := hd ptr.dbs;
		pick p := ptr {
		Direct =>
			offset = p.offset;
		Hash =>
			raise "not done yet";
		}
		(e, match, next) := dbf.readentry(offset, attr, value, useval);
		if(match)
			return (e, ref Dbptr.Direct(ptr.dbs, nil, next));
		if(e == nil)
			ptr = ref Dbptr.Direct(tl ptr.dbs, nil, 0);
		else
			ptr = ref Dbptr.Direct(ptr.dbs, nil, next);
	}
	return (nil, ptr);
}

Db.find(db: self ref Db, ptr: ref Dbptr, attr: string): (ref Dbentry, ref Dbptr)
{
	return nextentry(db, ptr, attr, nil, 0);
}

Db.findpair(db: self ref Db, ptr: ref Dbptr, attr: string, value: string): (ref Dbentry, ref Dbptr)
{
	return nextentry(db, ptr, attr, value, 1);
}

Db.findbyattr(db: self ref Db, ptr: ref Dbptr, attr: string, value: string, rattr: string): (ref Dbentry, ref Dbptr)
{
	for(;;){
		e: ref Dbentry;
		(e, ptr) = nextentry(db, ptr, attr, value, 1);
		if(e == nil || e.find(rattr) != nil)
			return (e, ptr);
	}
}

rev[T](l: list of T): list of T
{
	rl: list of T;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return rl;
}
