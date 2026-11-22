implement MemFS;

include "sys.m";
	sys: Sys;
	OTRUNC, ORCLOSE, OREAD, OWRITE: import Sys;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxlib.m";
	styxlib: Styxlib;
	Styxserver: import styxlib;
include "draw.m";
include "arg.m";

MemFS: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};


blksz : con 512;
Efull : con "filesystem full";
Ebadoff : con "offset out of range";
Eremoved : con "file has been removed";
Maxname : con 255;	# bytes in a file's name
OEXEC : con 3;	# open to execute: to search, of a directory
Maxoff : con 16r3FFFFFFF;	# the most a file may hold; an offset plus a count stays an int

Memfile : adt {
	name : string;
	owner : string;
	qid : Sys->Qid;
	perm : int;
	atime : int;
	mtime : int;
	nopen : int;
	data : array of array of byte;			# allocated in blks, no holes
	nblks : int;			# blocks charged to freeblks; len data is capacity
	length : int;
	parent : cyclic ref Memfile;	# Dir entry linkage
	kids : cyclic ref Memfile;
	prev : cyclic ref Memfile;
	next : cyclic ref Memfile;
	hashnext : cyclic ref Memfile;	# Qid hash linkage
};

Qidhash : adt {
	buckets : array of ref Memfile;
	nextqid : int;
	new : fn () : ref Qidhash;
	add : fn (h : self ref Qidhash, mf : ref Memfile);
	remove : fn (h : self ref Qidhash, mf : ref Memfile);
	lookup : fn (h : self ref Qidhash, qid : Sys->Qid) : ref Memfile;
};

timefd: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = checkload(load Styx Styx->PATH, Styx->PATH);
	styxlib = checkload(load Styxlib Styxlib->PATH, Styxlib->PATH);
	arg := checkload(load Arg Arg->PATH, Arg->PATH);

	amode := Sys->MREPL;
	maxsz := 16r7fffffff;
	srv := 0;
	mntpt := "/tmp";

	arg->init(argv);
	arg->setusage("memfs [-s] [-rab] [-m size] [mountpoint]");
	while((opt := arg->opt()) != 0) {
		case opt{
		's' =>
			srv = 1;
		'r' =>
			amode = Sys->MREPL;
		'a' =>
			amode = Sys->MAFTER;
		'b' =>
			amode = Sys->MBEFORE;
		'm' =>
			maxsz = int arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	arg = nil;
	if (argv != nil)
		mntpt = hd argv;

	srvfd: ref Sys->FD;
	mntfd: ref Sys->FD;
	if (srv)
		srvfd = sys->fildes(0);
	else {
		p := array [2] of ref Sys->FD;
		if (sys->pipe(p) == -1)
			error(sys->sprint("cannot create pipe: %r"));
		mntfd = p[0];
		srvfd = p[1];
	}
	styx->init();
	styxlib->init(styx);
	timefd = sys->open("/dev/time", sys->OREAD);

	(tc, styxsrv) := Styxserver.new(srvfd);
	if (srv)
		memfs(maxsz, tc, styxsrv, nil);
	else {
		sync := chan of int;
		spawn memfs(maxsz, tc, styxsrv, sync);
		<-sync;
		if (sys->mount(mntfd, nil, mntpt, amode | Sys->MCREATE, nil) == -1)
			error(sys->sprint("failed to mount onto %s: %r", mntpt));
	}
}

checkload[T](x: T, p: string): T
{
	if(x == nil)
		error(sys->sprint("cannot load %s: %r", p));
	return x;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

error(e: string)
{
	sys->fprint(stderr(), "memfs: %s\n", e);
	raise "fail:error";
}

freeblks: int;

memfs(maxsz : int, tc : chan of ref Tmsg, srv : ref Styxserver, sync: chan of int)
{
	sys->pctl(Sys->NEWNS, nil);
	if (sync != nil)
		sync <-= 1;
	freeblks = (maxsz / blksz);
	qhash := Qidhash.new();

	# init root
	root := newmf(qhash, nil, "memfs", srv.uname, 8r755 | Sys->DMDIR);
	root.parent = root;

Serve:
	while((tmsg := <-tc) != nil) {
#		sys->print("%s\n", tmsg.text());
	Msg:
		pick tm := tmsg {
		Readerror =>
			# the reader has gone: nothing more will come on tc. A
			# break here left the pick and waited on tc for ever,
			# every client of the mount hung with it.
			sys->fprint(stderr(), "memfs: %s\n", tm.error);
			break Serve;
		Version =>
			srv.devversion(tm);
		Auth =>
			srv.devauth(tm);
		Flush =>
			srv.reply(ref Rmsg.Flush(tm.tag));
		Walk =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			if (err != "") {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			# A fid that is open is not walked (walk(5)): it took the
			# open with it to another file, whose count of opens then
			# went down at the clunk while the first file's never did,
			# and that file was kept, and charged for, for ever.
			if (c.open) {
				srv.reply(ref Rmsg.Error(tm.tag, Styxlib->Eopen));
				continue;
			}
			nc: ref styxlib->Chan;
			if (tm.newfid != tm.fid) {
				nc = srv.clone(c, tm.newfid);
				if (nc == nil) {
					srv.reply(ref Rmsg.Error(tm.tag, "fid in use"));
					continue;
				}
				c = nc;
			}
			qids: array of Sys->Qid;
			if (len tm.names > 0) {
				oqid := c.qid;
				opath := c.path;
				qids = array[len tm.names] of Sys->Qid;
				wmf := mf;
				for (i := 0; i < len tm.names; i++) {
					# a name is looked for in a directory, and in one
					# the user may search: a directory of mode 0700 kept
					# its listing from others and gave them its files
					werr := Styxlib->Enotfound;
					if (!(wmf.perm & Sys->DMDIR)) {
						werr = Styxlib->Enotdir;
						wmf = nil;
					} else if (!modeok(OEXEC, wmf.perm, c.uname, wmf.owner)) {
						werr = Styxlib->Eperm;
						wmf = nil;
					} else
						wmf = dirlookup(wmf, tm.names[i]);
					if (wmf == nil) {
						if (nc == nil) {
							c.qid = oqid;
							c.path = opath;
						} else
							srv.chanfree(nc);
						if (i == 0)
							srv.reply(ref Rmsg.Error(tm.tag, werr));
						else
							srv.reply(ref Rmsg.Walk(tm.tag, qids[0:i]));
						break Msg;
					}
					c.qid = wmf.qid;
					qids[i] = wmf.qid;
				}
			}
			srv.reply(ref Rmsg.Walk(tm.tag, qids));
		Open =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			if (err == "" && c.open)
				err = Styxlib->Eopen;
			if (err == "" && !modeok(tm.mode, mf.perm, c.uname, mf.owner))
				err = Styxlib->Eperm;
			if (err == "" && (mf.perm & Sys->DMDIR) && (writes(tm.mode) || (tm.mode & (OTRUNC|ORCLOSE))))
				err = Styxlib->Eperm;
			if (err == "" && (tm.mode & ORCLOSE)) {
				p := mf.parent;
				if (p == nil || !modeok(OWRITE, p.perm, c.uname, p.owner))
					err = Styxlib->Eperm;
			}

			if (err != "") {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}

			c.open = 1;
			c.mode = tm.mode;
			c.qid.vers = mf.qid.vers;
			mf.nopen++;
			if ((tm.mode & OTRUNC) && !(mf.perm & Sys->DMAPPEND)) {
				# OTRUNC cannot be set for a directory
				# always at least one blk so don't need to check fs limit
				freeblks += mf.nblks;
				mf.data = nil;
				freeblks--;
				mf.data = array[1] of {* => array [blksz] of byte};
				mf.nblks = 1;
				mf.length = 0;
				mf.mtime = now();
			}
			srv.reply(ref Rmsg.Open(tm.tag, mf.qid, Styx->DEFIOUNIT));
		Create =>
			(err, c, parent) := fidtomf(srv, qhash, tm.fid);
			if (err == "" && c.open)
				err = Styxlib->Eopen;
			if (err == "" && !(parent.qid.qtype & Sys->QTDIR))
				err = Styxlib->Enotdir;
			if (err == "" && !modeok(OWRITE, parent.perm, c.uname, parent.owner))
				err = Styxlib->Eperm;
			# A directory that has been removed is on no path: files
			# made in it could never be reached again, or freed.
			if (err == "" && parent.parent == nil)
				err = Eremoved;
			if (err == "" && (tm.perm & Sys->DMDIR) && (writes(tm.mode) || (tm.mode & (OTRUNC|ORCLOSE))))
				err = Styxlib->Eperm;
			if (err == "")
				err = badname(tm.name);
			if (err == "" && dirlookup(parent, tm.name) != nil)
				err = Styxlib->Eexists;

			if (err != "") {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}

			# a directory is charged a block as a file is, though it has
			# none: they cost nothing, and there was no end to them
			isdir := tm.perm & Sys->DMDIR;
			if (freeblks <= 0) {
				srv.reply(ref Rmsg.Error(tm.tag, Efull));
				continue;
			}

			# modify perms as per Styx specification...
			perm : int;
			if (isdir)
				perm = (tm.perm&~8r777) | (parent.perm&tm.perm&8r777);
			else
				perm = (tm.perm&(~8r777|8r111)) | (parent.perm&tm.perm& 8r666);

			nmf := newmf(qhash, parent, tm.name, c.uname, perm);
			freeblks--;
			nmf.nblks = 1;
			if (!isdir)
				nmf.data = array[1] of {* => array [blksz] of byte};

			# link in the new MemFile
			nmf.next = parent.kids;
			if (parent.kids != nil)
				parent.kids.prev = nmf;
			parent.kids = nmf;

			c.open = 1;
			c.mode = tm.mode;
			c.qid = nmf.qid;
			nmf.nopen = 1;
			srv.reply(ref Rmsg.Create(tm.tag, nmf.qid, Styx->DEFIOUNIT));
		Read =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			if (err == "" && !c.open)
				err = Styxlib->Ebadfid;
			# as it was opened: the mode was checked at the open and not
			# looked at again, so a file opened to write was read
			if (err == "" && (c.mode & 3) == OWRITE)
				err = Styxlib->Eperm;
			# an offset is 64 bits and the files here are int-sized:
			# one past an int was cut to a negative one, and indexed
			# the block table with it (array bounds error, the server
			# gone; tools/nativefuzz)
			if (err == "" && (tm.offset < big 0 || tm.offset > big Maxoff || tm.count < 0))
				err = Ebadoff;

			if (err != "") {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			data: array of byte = nil;
			# no more than one message holds: a raw client's count
			# was the size of the array filedata made
			count := tm.count;
			if (count > Styx->DEFIOUNIT)
				count = Styx->DEFIOUNIT;
			if (mf.perm & Sys->DMDIR)
				data = dirdata(mf, int tm.offset, count);
			else
				data = filedata(mf, int tm.offset, count);
			mf.atime = now();
			srv.reply(ref Rmsg.Read(tm.tag, data));
		Write =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			if (c != nil && !c.open)
				err = Styxlib->Ebadfid;
			# and one opened to read was written
			if (err == nil && !writes(c.mode))
				err = Styxlib->Eperm;
			if (err == nil && (mf.perm & Sys->DMDIR))
				err = Styxlib->Eperm;
			# compared so as not to overflow: 2^63-1 plus a count was negative
			if (err == nil && (tm.offset < big 0 || tm.offset > big (Maxoff - len tm.data)))
				err = Ebadoff;
			if (err == nil)
				err = writefile(mf, int tm.offset, tm.data);
			if (err != nil) {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Clunk =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			if (c != nil)
				srv.chanfree(c);
			if (err != nil) {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			if (c.open) {
				if (c.mode & ORCLOSE)
					unlink(mf);
				mf.nopen--;
				freeblks += delfile(qhash, mf);
			}
			srv.reply(ref Rmsg.Clunk(tm.tag));
		Stat =>
			(err, nil, mf) := fidtomf(srv, qhash, tm.fid);
			if (err != nil) {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			srv.reply(ref Rmsg.Stat(tm.tag, fileinfo(mf)));
		Remove =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			# a remove clunks the fid even when it fails: the fid of a
			# file someone else removed first was kept here, and the
			# kernel, which counts it clunked, got "fid in use" on reuse
			if (c != nil)
				srv.chanfree(c);
			if (err != nil) {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			# a file another fid has removed, still open on this one,
			# is in no directory (the server died here, on nil)
			parent := mf.parent;
			if (parent == nil)
				err = Eremoved;
			else if (!modeok(OWRITE, parent.perm, c.uname, parent.owner))
				err = Styxlib->Eperm;
			if (err == "" && (mf.perm & Sys->DMDIR) && mf.kids != nil)
				err = "directory not empty";
			if (err == "" && mf == root)
				err = "root directory";
			if (err != nil) {
				# the fid is clunked all the same, and its open with it
				if (c.open) {
					if (c.mode & ORCLOSE)
						unlink(mf);
					mf.nopen--;
					freeblks += delfile(qhash, mf);
				}
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}

			unlink(mf);
			if (c.open)
				mf.nopen--;
			freeblks += delfile(qhash, mf);
			srv.reply(ref Rmsg.Remove(tm.tag));
		Wstat =>
			(err, c, mf) := fidtomf(srv, qhash, tm.fid);
			stat := tm.stat;

			# Each field is changed only if it is given (not "", not
			# ~0) and differs. The tests were of difference alone, which
			# an unchanged field never showed: so a wstat giving a file's
			# own mode and time back, and a new owner, was asked nothing,
			# and any user made any file their own.
			if (err == nil && stat.name != nil && stat.name != mf.name) {
				parent := mf.parent;
				if (parent == nil)
					err = Eremoved;
				else if (!modeok(OWRITE, parent.perm, c.uname, parent.owner))
					err = Styxlib->Eperm;
				else if ((err = badname(stat.name)) == nil && dirlookup(parent, stat.name) != nil)
					err = Styxlib->Eexists;
			}
			if (err == nil && ((stat.mode != ~0 && stat.mode != mf.perm) || (stat.mtime != ~0 && stat.mtime != mf.mtime))) {
				if (c.uname != mf.owner)
					err = Styxlib->Eperm;
			}
			# a file's owner is not changed by wstat
			if (err == nil && stat.uid != nil && stat.uid != mf.owner)
				err = Styxlib->Eperm;
			# A length given is the file's new length: cut, or
			# lengthened with zeros.  It was not looked at, and the
			# wstat answered as done: truncate(2)'s caller had its
			# file as long as before.  It takes write permission,
			# as a write would, and room for what it adds.
			newlen := -1;
			if (err == nil && stat.length != ~big 0 && stat.length != big mf.length) {
				if (mf.perm & Sys->DMDIR)
					err = "a directory's length is not set";
				else if (!modeok(OWRITE, mf.perm, c.uname, mf.owner))
					err = Styxlib->Eperm;
				else if (stat.length < big 0 || stat.length > big Maxoff)
					err = Ebadoff;
				else if ((mf.perm & Sys->DMAPPEND) && stat.length < big mf.length)
					err = Styxlib->Eperm;	# append-only: not cut, as OTRUNC is not taken
				else {
					newlen = int stat.length;
					if (blocksfor(newlen) - mf.nblks > freeblks)
						err = Efull;
				}
			}
			if (err != nil) {
				srv.reply(ref Rmsg.Error(tm.tag, err));
				continue;
			}
			isdir := mf.perm & Sys->DMDIR;
			if(newlen >= 0)
				setlength(mf, newlen);
			if(stat.name != nil)
				mf.name = stat.name;
			if(stat.mode != ~0)
				mf.perm = (stat.mode & ~Sys->DMDIR) | isdir;	# a file stays a file
			if(stat.mtime != ~0)
				mf.mtime = stat.mtime;
			t := now();
			mf.atime = t;
			if(mf.parent != nil)	# nil once removed, while a fid has it open
				mf.parent.mtime = t;
			# not supporting group id at the moment
			srv.reply(ref Rmsg.Wstat(tm.tag));
		Attach =>
			c := srv.newchan(tm.fid);
			if (c == nil) {
				srv.reply(ref Rmsg.Error(tm.tag, Styxlib->Einuse));
				continue;
			}
			c.uname = tm.uname;
			c.qid = root.qid;
			srv.reply(ref Rmsg.Attach(tm.tag, c.qid));
		}
	}
}

# a file of n bytes is charged so many blocks (never none)
blocksfor(n: int): int
{
	nb := (n + blksz - 1) / blksz;
	if(nb < 1)
		nb = 1;
	return nb;
}

# The caller has checked the length and that there is room.
setlength(mf: ref Memfile, n: int)
{
	nb := blocksfor(n);
	if (n < mf.length) {
		for (i := nb; i < len mf.data; i++)
			mf.data[i] = nil;
		if (nb < mf.nblks) {
			freeblks += mf.nblks - nb;
			mf.nblks = nb;
		}
	} else {
		if (nb > mf.nblks) {
			freeblks -= nb - mf.nblks;
			mf.nblks = nb;
		}
		if (nb > len mf.data) {
			nd := array [nb] of array of byte;
			nd[0:] = mf.data;
			mf.data = nd;
		}
	}
	# what is past the shorter of the two lengths in its block reads
	# as zeros if the file grows over it; the blocks after are holes
	short := min(n, mf.length);
	if (short/blksz < len mf.data && (b := mf.data[short/blksz]) != nil)
		for (i := short % blksz; i < len b; i++)
			b[i] = byte 0;
	mf.length = n;
	mf.mtime = now();
}

writefile(mf: ref Memfile, offset: int, data: array of byte): string
{
	if(mf.perm & Sys->DMAPPEND){
		# the offset checked was the message's, which an append ignores
		offset = mf.length;
		if(offset > Maxoff - len data)
			return Ebadoff;
	}
	startblk := offset/blksz;
	nblks := ((len data + offset) - (startblk * blksz))/blksz;
	lastblk := startblk + nblks;

	#
	# The block table grows by DOUBLING, not by exactly what this
	# write needs.
	#
	# Sized exactly, it was reallocated and copied on every write
	# that extended the file, which is quadratic in the number of
	# blocks: a 2MB file is 4200 blocks of 512 bytes, so writing it
	# in ATOMICIO pieces meant 262 reallocations copying an average
	# of 2100 references each, and 262 tables' worth of garbage for
	# the collector on a heap that already holds every data block.
	# Measured, a 2MB copy inside this filesystem ran at 150 KB/s
	# while reading it out to the network ran at 12.4 MB/s -- and
	# reads take no such path (#609).
	#
	# Capacity and occupancy have to be counted separately once the
	# table can be longer than the file. The table's length WAS the
	# charged count, and three other places still returned blocks to
	# the store with "len mf.data"; with a doubling table that would
	# hand back more than was ever taken and let the store grow past
	# its size. mf.nblks now carries what freeblks was charged, and
	# those places return that instead.
	#
	nb := lastblk + 1;
	if (nb > mf.nblks) {
		if (nb - mf.nblks > freeblks)
			return Efull;
		freeblks -= nb - mf.nblks;
		mf.nblks = nb;
	}
	if (nb > len mf.data) {
		cap := len mf.data;
		if (cap == 0)
			cap = 1;
		while (cap < nb)
			cap *= 2;
		nd := array [cap] of array of byte;
		nd[0:] = mf.data;
		mf.data = nd;
	}
	mf.length = max(mf.length, offset + len data);

	# handle (possibly incomplete first block) separately
	offset %= blksz;
	end := min(blksz-offset, len data);
	# a block is made zeroed: the part of it a write skips over is a
	# hole like any other
	if (mf.data[startblk] == nil)
		mf.data[startblk] = array [blksz] of {* => byte 0};
	mf.data[startblk++][offset:] = data[:end];

	ix := blksz - offset;
	while (ix < len data) {
		if (mf.data[startblk] == nil)
			mf.data[startblk] = array [blksz] of {* => byte 0};
		end = min(ix+blksz,len data);
		mf.data[startblk++][:] = data[ix:end];
		ix += blksz;
	}
	mf.mtime = now();
	return nil;
}

filedata(mf: ref Memfile, offset, n: int): array of byte
{
	# A read at or past the end is empty, not negative. Two clients
	# racing on one file -- one reading while the other truncates or
	# removes it -- read past mf.length, and array[n] of a negative n
	# killed the whole server ("negative array size"), taking /tmp
	# with it for every process on the machine.
	if (offset +n > mf.length)
		n = mf.length - offset;
	if (n <= 0)
		return nil;

	# A block never written is nil -- a write past the end leaves a
	# hole -- and reads as zeros: data is made zeroed. Sliced, a nil
	# block was an array bounds error, the server gone (nativefuzz).
	data := array [n] of {* => byte 0};
	startblk := offset/blksz;
	offset %= blksz;
	rn := min(blksz - offset, n);
	if ((b := mf.data[startblk++]) != nil)
		data[:] = b[offset:offset+rn];
	ix := blksz - offset;
	while (ix < n) {
		rn = blksz;
		if (ix+rn > n)
			rn = n - ix;
		if ((b = mf.data[startblk++]) != nil)
			data[ix:] = b[:rn];
		ix += blksz;
	}
	return data;
}

QHSIZE: con 256;
QHMASK: con QHSIZE-1;

Qidhash.new() : ref Qidhash
{
	qh := ref Qidhash;
	qh.buckets = array [QHSIZE] of ref Memfile;
	qh.nextqid = 0;
	return qh;
}

Qidhash.add(h : self ref Qidhash, mf : ref Memfile)
{
	path := h.nextqid++;
	mf.qid = Sys->Qid(big path, 0, Sys->QTFILE);
	bix := path & QHMASK;
	mf.hashnext = h.buckets[bix];
	h.buckets[bix] = mf;
}

Qidhash.remove(h : self ref Qidhash, mf : ref Memfile)
{

	bix := int mf.qid.path & QHMASK;
	prev : ref Memfile;
	for (cur := h.buckets[bix]; cur != nil; cur = cur.hashnext) {
		if (cur == mf)
			break;
		prev = cur;
	}
	if (cur != nil) {
		if (prev != nil)
			prev.hashnext = cur.hashnext;
		else
			h.buckets[bix] = cur.hashnext;
		cur.hashnext = nil;
	}
}

Qidhash.lookup(h : self ref Qidhash, qid : Sys->Qid) : ref Memfile
{
	bix := int qid.path & QHMASK;
	for (mf := h.buckets[bix]; mf != nil; mf = mf.hashnext)
		if (mf.qid.path == qid.path)
			break;
	return mf;
}

newmf(qh : ref Qidhash, parent : ref Memfile, name, owner : string, perm : int) : ref Memfile
{
	# qid gets set by Qidhash.add()
	t := now();
	# name, owner, qid, perm, atime, mtime, nopen, data, nblks, length, ...
	mf := ref Memfile (name, owner, Sys->Qid(big 0,0,Sys->QTFILE), perm, t, t, 0, nil, 0, 0, parent, nil, nil, nil, nil);
	qh.add(mf);
	if(perm & Sys->DMDIR)
		mf.qid.qtype = Sys->QTDIR;
	return mf;
}

fidtomf(srv : ref Styxserver, qh : ref Qidhash, fid : int) : (string, ref Styxlib->Chan, ref Memfile)
{
	c := srv.fidtochan(fid);
	if (c == nil)
		return (Styxlib->Ebadfid, nil, nil);
	mf := qh.lookup(c.qid);
	if (mf == nil)
		return (Styxlib->Enotfound, c, nil);
	return (nil, c, mf);
}

# whether an open of this mode is one that writes
writes(mode : int) : int
{
	return (mode & 3) == OWRITE || (mode & 3) == Sys->ORDWR;
}

# why a name is none for a file, or nil
badname(name : string) : string
{
	if (name == nil || name == "." || name == "..")
		return "bad file name";
	for (i := 0; i < len name; i++)
		if (name[i] == '/' || name[i] == 0)
			return "bad file name";
	if (len array of byte name > Maxname)
		return "file name too long";
	return nil;
}

unlink(mf : ref Memfile)
{
	parent := mf.parent;
	if (parent == nil)
		return;
	if (mf.next != nil)
		mf.next.prev = mf.prev;
	if (mf.prev != nil)
		mf.prev.next = mf.next;
	else
		mf.parent.kids = mf.next;
	mf.parent = nil;
	mf.prev = nil;
	mf.next = nil;
}

delfile(qh : ref Qidhash, mf : ref Memfile) : int
{
	if (mf.nopen <= 0 && mf.parent == nil && mf.kids == nil
	&& mf.prev == nil && mf.next == nil) {
		qh.remove(mf);
		nblks := mf.nblks;
		mf.data = nil;
		mf.nblks = 0;
		return nblks;
	}
	return 0;
}

dirlookup(dir : ref Memfile, name : string) : ref Memfile
{
	if (name == ".")
		return dir;
	if (name == "..")
		return dir.parent;
	for (mf := dir.kids; mf != nil; mf = mf.next) {
		if (mf.name == name)
			break;
	}
	return mf;
}

access := array[] of {8r400, 8r200, 8r600, 8r100};
modeok(mode, perm : int, user, owner : string) : int
{
	if(mode >= (OTRUNC|ORCLOSE|OREAD|OWRITE))
		return 0;

	# not handling groups!
	if (user != owner)
		perm <<= 6;
	
	if ((mode & OTRUNC) && !(perm & 8r200))
		return 0;

	a := access[mode &3];
	if ((a & perm) != a)
		return 0;
	return 1;
}

dirdata(dir : ref Memfile, start, n : int) : array of byte
{
	data := array[Styx->DEFIOUNIT] of byte;
	for (k := dir.kids; start > 0 && k != nil; k = k.next) {
		a := styx->packdir(fileinfo(k));
		start -= len a;
	}
	r := 0;
	for (; r < n && k != nil; k = k.next) {
		a := styx->packdir(fileinfo(k));
		if(r+len a > n)
			break;
		data[r:] = a;
		r += len a;
	}
	return data[0:r];
}

fileinfo(f : ref Memfile) : Sys->Dir
{
	dir := sys->zerodir;
	dir.name = f.name;
	dir.uid = f.owner;
	dir.gid = "memfs";
	dir.qid = f.qid;
	dir.mode = f.perm;
	dir.atime = f.atime;
	dir.mtime = f.mtime;
	dir.length = big f.length;
	dir.dtype = 0;
	dir.dev = 0;
	return dir;
}

min(a, b : int) : int
{
	if (a < b)
		return a;
	return b;
}

max(a, b : int) : int
{
	if (a > b)
		return a;
	return b;
}

now(): int
{
	if (timefd == nil)
		return 0;
	buf := array[128] of byte;
	sys->seek(timefd, big 0, 0);
	n := sys->read(timefd, buf, len buf);
	if(n < 0)
		return 0;

	t := (big string buf[0:n]) / big 1000000;
	return int t;
}
