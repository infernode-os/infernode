# ventisrv - venti server with in-memory index.
#
# Salvaged from Mechiel Lukkien's ventisrv (github.com/mjl-/ventisrv,
# GSoC 2007 "ventivac" project; public domain). The rest of the vac
# stack (vacput/vacget/vacfs, module/{vac,venti}.m) already ships in
# this tree; this is the server piece the man pages referenced.
# In-tree use: content store for the audit log's agent-provenance
# records (auditprov(2)) — see docs/compliance/audit-log-design.md §8.
#
# ventisrv stores a part of each stored score in memory.  at the
# command-line, the maximum data file size and mean block size (thus
# expected number of scores) is given.  the scores are assumed to be
# distributed evenly, so the number of bits of each score to keep in memory
# in order to make the probability of a collision <0.001 is calculated.
# now all stored scores are read from the index file and partially stored
# in main memory.

# a venti block read can result in 0 hits (data not present) or 1 or
# more hits.  for each of the hits, the full score has to be read from
# disk until a match is found (in which case the data will be returned and
# further reading stopped).  it is possible none of the in-memory "hits"
# are a hit in the data file.

# a venti block write will perform the same steps as the read.  if the
# data is not present, the header+data is written to the data file,
# another header is written to the index file.

# at startup, the index file and data file are checked.  if headers
# are missing from the index file, they are synced with headers from the
# data file.  missing headers in the data file are errors and ventisrv
# will stop with a dianostic message.

# possible improvements:
# - speedup syncing index file from data file at startup?
# - queueing index writes may help when filesystem does synchronous writes
# - make startup faster by reading partial scores into memory more
#   efficiently: insert non-sorted at startup, when all has been read,
#   sort the lists.  faster than inserting each block sorted.

implement Ventisrv;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "daytime.m";
	daytime: Daytime;
include "string.m";
	str: String;
include "keyring.m";
	kr: Keyring;
include "filter.m";
	deflate, inflate: Filter;
include "lock.m";
	lock: Lock;
	Semaphore: import lock;
include "venti.m";
	venti: Venti;
	Score, Scoresize, Vmsg: import venti;


Ventisrv: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Ihdr: adt {
	halfscore:	array of byte;
	dtype:	int;
	offset:	big;
	compressed:	int;

	unpack:	fn(d: array of byte): ref Ihdr;
	pack:	fn(ih: self ref Ihdr, d: array of byte);
};

Dhdr: adt {
	score:	Score;
	dtype:	int;
	size:	int;
	conntime:	big;

	unpack:	fn(d: array of byte): (ref Dhdr, string);
	pack:	fn(dh: self ref Dhdr, d: array of byte);
};

Chain: adt {
	d:	array of byte;
	used:	int;
	next:	cyclic ref Chain;

	mk:	fn(): ref Chain;
	getaddr:	fn(c: self ref Chain, i: int): (int, big);
	lookup: fn(c: self ref Chain, d: array of byte, l: list of (int, big)): list of (int, big);
	insert: fn(c: self ref Chain, ih: ref Ihdr);
};

Client: adt {
	rpid, wpid:	int;
	respc:	chan of ref Vmsg;
	inuse:	int;
	conntime:	big;
	readonly:	int;
};

Lookup: adt {
	c:	ref Client;
	tid:	int;
	addrs:	list of (int, big);
	pick {
	Read =>
		score:	Score;
		dtype:	int;
		size:	int;
	Write =>
		b:	ref Block;
	}
};

Store: adt {
	c:	ref Client;
	pick {
	Sync =>
		tid:	int;
	Write =>
		b:	ref Block;
	}
};

Block: adt
{
	score:	Score;
	dtype:	int;
	d:	array of byte;
};

Fhdr: adt {
	blocks:	array of ref Dhdr;
	hsize:	int;
	dsize:	int;

	unpack:	fn(d: array of byte): (ref Fhdr, array of int, string);
	pack:	fn(fh: self ref Fhdr, d: array of byte);
};

Queue: adt
{
	a:	array of ref Block;
	n:	int;

	lookup:	fn(q: self ref Queue, s: Score, dtype: int): array of byte;
	insert:	fn(q: self ref Queue, b: ref Block);
	remove:	fn(q: self ref Queue, b: ref Block);
};

Fifo: adt
{
	a:	array of ref Block;
	n, f:	int;
	sem:	ref Semaphore;

	lookup:	fn(l: self ref Fifo, s: Score, dtype: int): array of byte;
	insert:	fn(l: self ref Fifo, b: ref Block);
};

Flate: adt
{
	rqc:	chan of ref Filter->Rq;
	lastfill:	ref Filter->Rq.Fill;
	d:	array of byte;
	nd:	int;
	pid:	int;

	new:	fn(n: int): ref Flate;
	write:	fn(f: self ref Flate, d: array of byte): string;
	finish:	fn(f: self ref Flate): (array of byte, string);
};

Eperm:	con "permission denied";

Indexscoresize:	con 8;
Icomprmask:	con big 1<<(6*8-1);
Ihdrsize:	con Indexscoresize+1+6;	# scoresize+typesize+addrsize
Iverify:	con 128;	# check the half scores of the last n entries in the index file against the data file
Ichunksize:	con ((128*1024)/Ihdrsize)*Ihdrsize;	# chunk in bytes of index entries to read at a time
Nqueuechunks:	con 32;		# queue n Ichunksize blocks when reading index at startup
Dhdrmagic:	con big 16r2f9d81e5;
Fhdrmagic:	con big 16r78c66a15;
Dhdrsize:	con 4+Scoresize+1+2+4;	# magic+score+type+size+conntime
Fhdrsize:	con 4+1+2;	# magic+count+size
Fbhdrsize:	con 20+1+2+4;	# score+type+size+conntime
Maxreaders:	con 32;
Maxclients:	con 64;
Maxpendingwrites: con 1024;
Handshakems:	con 10000;
Maxblocksize:	con Dhdrsize+Venti->Maxlumpsize;

typebits: con 8;	# must be 8

chainblocks, headbits, nheads: int;
scorebits, addrbits: int;
comprmask:	big;
membytes, headbytes, scorebytes: int;
scorebytemask: byte;
maxdatasize: big;

Arraysize:	con 4+4+4;
Refsize:	con 4;

listenaddr: con "net!127.0.0.1!venti";
indexfile := "index";
datafile := "data";
statsdir := "/chan/";
statsfile := "ventisrvstats";
debug, Cflag, cflag, qflag, verbose: int;
verifyoffset := big -1;
raddrs, waddrs: list of string;

indexfd, datafd: ref Sys->FD;
indexsize, datasize: big;

zeroscore: Score;


heads: array of ref Chain;
reqc: chan of (ref Vmsg, ref Client);
wrotec: chan of (int, ref Client);
lookupc: chan of ref Lookup;
lookupdonec: chan of (int, ref Vmsg, ref Client);
syncdonec: chan of (ref Vmsg, ref Client);
storec: chan of ref Store;
writererrorc: chan of string;
sem: ref Semaphore;
statsem: ref Semaphore;
clienttokens: chan of int;

writequeue: ref Queue;
flatequeue: ref Fifo;

initheap, configheap: big;
nreads, nwrites, nwritesdup, nsyncs, npings: int;
nblocks, nflateblocks: int;
lookupcollisions: int;


init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	daytime = load Daytime Daytime->PATH;
	str = load String String->PATH;
	kr = load Keyring Keyring->PATH;
	lock = load Lock Lock->PATH;
	lock->init();
	deflate = load Filter Filter->DEFLATEPATH;
	inflate = load Filter Filter->INFLATEPATH;
	deflate->init();
	inflate->init();
	venti = load Venti Venti->PATH;
	venti->init();

	arg->init(args);
	arg->setusage(arg->progname()+ " [-DcCqv] [-I indexoffset] [-i index] [-d data] [-s statsfile] [-r addr] [-w addr] maxdatasize meanblocksize");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	debug++;
		'I' =>	verifyoffset = big arg->earg();
		'c' =>	cflag++;
			Cflag++;
		'C' =>	Cflag++;
		'd' =>	datafile = arg->earg();
		'i' =>	indexfile = arg->earg();
		'q' =>	qflag++;
			verbose++;
		'v' =>	verbose++;
		's' =>	(statsdir, statsfile) = str->splitstrr(arg->earg(), "/");
			if(statsfile == nil) {
				sys->fprint(sys->fildes(2), "bad stats file");
				arg->usage();
			}
		'r' =>	raddrs = arg->earg()::raddrs;
		'w' =>	waddrs = arg->earg()::waddrs;
		* =>
			sys->fprint(sys->fildes(2), "bad option: -%c\n", c);
			arg->usage();
		}

	args = arg->argv();
	verbose += debug;
	if(len args != 2)
		arg->usage();

	if(raddrs == nil && waddrs == nil)
		waddrs = listenaddr::nil;

	initheap = heapused();

	maxdatasize = suffix(hd args);
	meanblocksize := int suffix(hd tl args);
	maxblocks := maxdatasize/big (meanblocksize+Dhdrsize);

	addrbits = log2(maxdatasize);
	if(Cflag)
		addrbits += 1;
	if(addrbits > 48)
		fail("maxdatasize too large");
	comprmask = (big 1<<(addrbits-1));
	headbits = log2(maxblocks/big 1000);
	minscorebits := log2(maxblocks)+log2(big 1000);
	totalbits := ((addrbits+typebits+minscorebits-headbits+8-1)/8)*8;
	scorebits = totalbits-addrbits-typebits;

	chainblocks = 256;
	membytes = (typebits+scorebits+addrbits+8-1)/8;
	headbytes = (headbits+8-1)/8;
	scorebytes = (scorebits+8-1)/8;
	scorebytemask = byte ((1<<(scorebits % 8)) - 1);

	zeroscore = Score.zero();
	nheads = 1<<headbits;
	heads = array[nheads] of ref Chain;
	reqc = chan[256] of (ref Vmsg, ref Client);
	wrotec = chan of (int, ref Client);
	lookupc = chan of ref Lookup;
	lookupdonec = chan[1] of (int, ref Vmsg, ref Client);
	syncdonec = chan[1] of (ref Vmsg, ref Client);
	storec = chan[32] of ref Store;
	# Error publication must not block a worker while main is synchronously
	# draining outstanding lookups in takewrites(). Only the first error is
	# published (seterror guards lasterr), so one slot is sufficient.
	writererrorc = chan[1] of string;
	sem = Semaphore.new();
	statsem = Semaphore.new();
	clienttokens = chan[Maxclients] of int;
	for(i := 0; i < Maxclients; i++)
		clienttokens <-= 1;

	writequeue = ref Queue(array[2] of ref Block, 0);
	flatequeue = ref Fifo(array[64] of ref Block, 0, 0, Semaphore.new());

	chainsize := Arraysize+4+Refsize + chainblocks*membytes;	# this probably takes more overhead, internal memory allocation at least
	blocksperhead := int (maxblocks/big nheads);
	chainsperhead := (blocksperhead+chainblocks-1)/chainblocks;
	totalchains := chainsperhead*nheads;
	headsize := Arraysize+nheads*Refsize;
	maxwasted := nheads*chainsize;
	maxmemusage := big headsize+big chainsize*big totalchains;
	max := heapmax();
	if(maxmemusage > max)
		say(sprint("maximum memory usage (%bd bytes) larger than available memory (%bd bytes)", maxmemusage, max));
	if(debug) {
		say(sprint("typebits=%d scorebits=%d addrbits=%d headbits=%d",
			typebits, scorebits, addrbits, headbits));
		say(sprint("nheads=%d membytes=%d headbytes=%d scorebytes=%d scorebytemask=%d",
			nheads, membytes, headbytes, scorebytes, int scorebytemask));
		say(sprint("headsize=%d chainsize=%d blocksperhead=%d totalchains=%d maxwasted=%d",
			headsize, chainsize, blocksperhead, totalchains, maxwasted));
	}
	if(verbose)
		say(sprint("maxmemusage=%bd maxblocks=%bd", maxmemusage, maxblocks));
	if(qflag)
		return;

	conns: list of (Sys->Connection, int);
	conns = announce(raddrs, 1, conns);
	conns = announce(waddrs, 0, conns);
	config();
	listen(conns);
	main();
}

announce(addrs: list of string, readonly: int, conns: list of (Sys->Connection, int)): list of (Sys->Connection, int)
{
	for(l := addrs; l != nil; l = tl l) {
		(ok, conn) := sys->announce(hd l);
		if(ok < 0)
			fail(sprint("announce %s: %r", hd l));
		conns = (conn, readonly)::conns;
	}
	return conns;
}

listen(conns: list of (Sys->Connection, int))
{
	for(l := conns; l != nil; l = tl l) {
		(conn, readonly) := hd l;
		spawn listener(conn, readonly);
		if(debug) say("listener spawned");
	}
}

listener(aconn: Sys->Connection, readonly: int)
{
	for(;;) {
		if(debug) say("listener: listening");
		(ok, conn) := sys->listen(aconn);
		if(ok < 0)
			fail(sprint("listen: %r"));
		if(debug) say("listener: have client");
		dfd := sys->open(conn.dir+"/data", sys->ORDWR);
		cfd := sys->open(conn.dir+"/ctl", sys->OWRITE);
		if(dfd == nil || cfd == nil) {
			if(verbose) say(sprint("opening connection data/control file: %r"));
			dfd = nil;
			cfd = nil;
		} else {
			<-clienttokens;
			spawn clientguard(dfd, cfd, readonly);
		}
	}
}

clientguard(fd, cfd: ref Sys->FD, readonly: int)
{
	{
		client(fd, cfd, readonly);
	} exception {
	* =>
		;
	}
	clienttokens <-= 1;
}

handshaketimer(cfd: ref Sys->FD, done: chan of int)
{
	sys->sleep(Handshakems);
	alt {
	<-done =>
		;
	* =>
		if(cfd != nil)
			sys->fprint(cfd, "hangup");
	}
}

filesize(fd: ref Sys->FD): big
{
	(ok, d) := sys->fstat(fd);
	if(ok != 0)
		fail(sprint("fstat on index or data file: %r"));
	return d.length;
}

config()
{
	indexfd = sys->open(indexfile, sys->ORDWR);
	if(indexfd == nil)
		fail(sprint("opening %s: %r", indexfile));
	datafd = sys->open(datafile, sys->ORDWR);
	if(datafd == nil)
		fail(sprint("opening %s: %r", datafile));

	indexsize = filesize(indexfd);
	datasize = filesize(datafd);
	if(indexsize % big Ihdrsize != big 0)
		fail(sprint("index file not multiple of iheadersize (indexsize=%bd iheadersize=%d)", indexsize, Ihdrsize));

	doffset := big 0;
	io := verifyoffset;
	if(io < big 0) {
		io = indexsize-big (Iverify*Ihdrsize);
		if(io < big 0)
			io = big 0;
	} else if(io > indexsize)
		fail(sprint("index file offset to verify at lies outsize index file"));
	else
		if(verbose) say(sprint("starting index file verification at offset=%bd", io));
		
	if(indexsize > big 0) {
		if(debug) say(sprint("config: verifying last entries in index file at offset=%bd", io));
		ih := getihdr(io);
		if(ih == nil)
			fail(sprint("premature eof on index file at offset=%bd", io));
		while(ih.compressed) {
			io += big Ihdrsize;
			nih := getihdr(io);
			if(nih.offset != ih.offset)
				break;
			ih = nih;
		}
		while(io < indexsize) {
			(ndoffset, nio) := indexverify(io);
			if(nio == big -1) {
				dir := sys->nulldir;
				dir.length = io;
				if(sys->fwstat(indexfd, dir) != 0)
					fail(sprint("truncating index file to remove trailing entries for compressed blocks: %r"));
				indexsize = io;
				break;
			}
			(doffset, io) = (ndoffset, nio);
		}
	}

	if(debug) say("config: syncing index file to data file");
	nadd := ncompr := 0;
	while(doffset < datasize) {
		(dhdrs, compr, noffset, err) := offsetread(doffset);
		if(err != nil)
			fail(sprint("syncing index from data at offset=%bd: %s", doffset, err));
		for(i := 0; i < len dhdrs; i++) {
			dhdr := dhdrs[i];
			err = indexstore(ref Ihdr(dhdr.score.a[:Indexscoresize], dhdr.dtype, doffset, compr));
			if(err != nil)
				fail("syncing index from data: "+err);
			nadd++;
		}
		if(compr)
			ncompr = len dhdrs;
		doffset = noffset;
	}
	if(verbose) say(sprint("config: added %d entries to index file of which %d compressed", nadd, ncompr));

	if(debug) say("config: reading entries into memory");
	indexsize = filesize(indexfd);
	t0 := sys->millisec();

	blockc := chan[Nqueuechunks] of (array of byte, big);
	donec := chan of int;
	spawn indexunpack(blockc, donec);
	for(o := big 0; o < indexsize; o += big Ichunksize) {
		d := array[Ichunksize] of byte;
		n := preadn(indexfd, d, len d, o);
		if(n < 0 || n % Ihdrsize != 0) {
			if(n > 0)
				sys->werrstr("bytes read not multiple of iheadersize");
			fail(sprint("reading index entries chunk at offset=%bd: %r", o));
		}
		if(n > 0)
			blockc<- = (d[:n], o);
		if(n < Ichunksize)
			break;
	}
	blockc<- = (nil, big 0);
	<-donec;
	t1 := sys->millisec();
	nblocks = int (indexsize/big Ihdrsize);

	if(verbose) say(sprint("config: done, loaded %d entries (%bd bytes) of which %d compressed in memory in %0.2f s",
		nblocks, indexsize, nflateblocks, real (t1-t0)/1000.0));
}

checkheaders(ih: ref Ihdr, dh: ref Dhdr)
{
	if(halfcmp(ih.halfscore, dh.score.a, ih.dtype, dh.dtype) == 0)
		return;
	fail(sprint("partial score or type index file does not match block in data file at offset=%bd, index: score=%s type=%d compressed=%d, data: score=%s type=%d",
		ih.offset, scorestr(ih.halfscore), ih.dtype, ih.compressed, dh.score.text(), dh.dtype));
}

getihdr(o: big): ref Ihdr
{
	d := array[Ihdrsize] of byte;
	n := preadn(indexfd, d, len d, o);
	if(n < 0)
		fail(sprint("reading at offset=%bd: %r", o));
	if(n == 0)
		return nil;
	if(n != len d)
		fail(sprint("short read on index file at offset=%bd", o));
	ih := Ihdr.unpack(d);
	if(ih.offset > datasize)
		fail(sprint("index entry at offset=%bd points past end of data file (offset=%bd)", o, ih.offset));
	return ih;
}

indexverify(o: big): (big, big)
{
	ih := getihdr(o);
	(dhs, nil, noffset, berr) := offsetread(ih.offset);
	if(berr != nil)
		fail("reading block pointed to by one of last entries in index file: "+berr);
	checkheaders(ih, dhs[0]);
	o += big Ihdrsize;
	for(i := 1; i < len dhs; i++) {
		ih = getihdr(o);
		if(ih == nil)
			return (big -1, big -1);
		checkheaders(ih, dhs[i]);
		o += big Ihdrsize;
	}
	return (noffset, o);
}

indexunpack(blockc: chan of (array of byte, big), donec: chan of int)
{
	for(;;) {
		(d, o) := <-blockc;
		if(d == nil)
			break;

		for(i := 0; i < len d; i += Ihdrsize) {
			ih := Ihdr.unpack(d[i:i+Ihdrsize]);
			meminsert(ih);
			if(ih.compressed) {
				if(!Cflag)
					fail(sprint("compressed block at index file offset=%bd but -C not specified", o));
				nflateblocks++;
			}
		}
	}
	donec<- = 0;
}

killc(c: ref Client)
{
	killpid(c.rpid);
	killpid(c.wpid);
	c.rpid = c.wpid = -1;
}

killpid(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill\n");
}

decompress(src, dst: array of byte): string
{
if(debug) say(sprint("decompress len src=%d len dst=%d", len src, len dst));
	rqc := inflate->start("");
	<-rqc;

done:
	for(;;) {
		pick r := <-rqc {
		Fill =>
			n := len src;
			if(len r.buf < n)
				n = len r.buf;
			r.buf[:] = src[:n];
			src = src[n:];
			r.reply<- = n;
		Result =>
			if(len r.buf > len dst) {
				r.reply<- = -1;
				return "inflated data too large";
			}
			dst[:] = r.buf;
			dst = dst[len r.buf:];
			r.reply<- = 0;
		Finished =>
			if(len r.buf != 0)
				return "leftover data at end of inflate";
			break done;
		Error =>
			return r.e;
		}
	}
	if(len dst != 0)
		return "inflated data smaller than expected";
	return nil;
}


flateadd(f: ref Flate, d: array of byte)
{
	if(f.nd+len d <= len f.d)
		f.d[f.nd:] = d;
	f.nd += len d;
}

Flate.new(n: int): ref Flate
{
	f := ref Flate(deflate->start(""), nil, array[n] of byte, 0, 0);
	pick r := <-f.rqc {
	Start =>	f.pid = r.pid;
	* =>	fail("bad first message from deflate");
	}
	pick r := <-f.rqc {
	Fill =>	f.lastfill = r;
	* =>	fail("bad second message from deflate");
	}
	return f;
}

Flate.write(f: self ref Flate, d: array of byte): string
{
	if(f.nd > len d)
		return nil;

	n := len d;
	if(len f.lastfill.buf < n)
		n = len f.lastfill.buf;
	f.lastfill.buf[:] = d[:n];
	f.lastfill.reply<- = n;
	f.lastfill = nil;

	for(;;) {
		pick r := <-f.rqc {
		Fill =>
			f.lastfill = r;
			return nil;
		Result =>
			flateadd(f, r.buf);
		Error =>
			return r.e;
		* =>	fail("bad rq from deflate");
		}
	}
	return nil;
}

Flate.finish(f: self ref Flate): (array of byte, string)
{
	if(f.nd > len f.d) {
		killpid(f.pid);
		return (nil, nil);
	}
	f.lastfill.reply<- = 0;
done:
	for(;;) {
		pick r := <-f.rqc {
		Result =>
			flateadd(f, r.buf);
			r.reply<- = 0;
		Finished =>
			if(len r.buf != 0)
				fail("deflate left data uncompressed");
			break done;
		Error =>
			return (nil, r.e);
		* =>
			fail("bad response from deflate");
		}
	}
	if(f.nd > len f.d)
		return (nil, nil);
	return (f.d[:f.nd], nil);
}

reader()
{
	for(;;) {
		pick w := <-lookupc {
		Read =>	
			if(debug) say("reader: have read message");

			(nil, d, err) := datalookup(w.addrs, w.score, w.dtype, 1, w.size);
			if(len d > w.size)
				err = "data larger than requested";
			if(err == nil && d == nil)
				err = "no such score/type";
			rmsg: ref Vmsg;
			if(err == nil) {
				rmsg = ref Vmsg.Rread(0, w.tid, d);
			} else {
				rmsg = ref Vmsg.Rerror(0, w.tid, err);
				if(verbose) say("reader: error reading data: "+err);
			}
			if(debug) say("reader: read handled");
			lookupdonec<- = (0, rmsg, w.c);

		Write =>
			if(debug) say(sprint("reader: have write message"));

			(hit, nil, err) := datalookup(w.addrs, w.b.score, w.b.dtype, 0, len w.b.d);
			if(err != nil) {
				if(debug) say("reader: datalookup failed: "+err);
				sem.obtain();
				writequeue.remove(w.b);
				sem.release();
				seterror("write lookup: " + err);
				lookupdonec<- = (1, nil, w.c);
				continue;
			}
			if(hit) {
if(debug) say("reader: have hit, already in datafile");
				sem.obtain();
				writequeue.remove(w.b);
				sem.release();
				statsem.obtain();
				nwritesdup++;
				statsem.release();
			} else {
if(debug) say("reader: no hit, need to write block");
				if(debug) say("reader: data not yet present for write");
				storec<- = ref Store.Write(w.c, w.b);
			}
			if(debug) say("reader: write handled");
			lookupdonec<- = (1, nil, w.c);
		}
	}
}

flate: ref Flate;
Maxfblocks:	con 256;
rawsize: int;
nfblocks: int;
fblocks: array of (ref Block, big);


flatefinish(): string
{
if(debug) say(sprint("flatefinish: rawsize=%d nfblocks=%d", rawsize, nfblocks));

	(d, err) := flate.finish();
	if(err != nil)
		return "flatefinish: "+err;

	if(d == nil || Fhdrsize+nfblocks*Fbhdrsize+len d > Maxblocksize) {
		if(debug) say("flatefinish: data too large, writing as normal blocks");

		l := array[nfblocks] of (ref Ihdr, ref Block);
		for(i := 0; i < nfblocks; i++) {
			(b, conntime) := fblocks[i];
			dh := ref Dhdr(b.score, b.dtype, len b.d, conntime);
			offset: big;
			(offset, err) = datastore(dh, b.d);
			ih := ref Ihdr(b.score.a[:Indexscoresize], b.dtype, offset, 0);
			if(err == nil)
				err = indexstore(ih);
			if(err != nil)
				return err;
			l[i] = (ih, b);
		}
		sem.obtain();
		for(i = 0; i < nfblocks; i++) {
			(ih, b) := l[i];
			meminsert(ih);
			writequeue.remove(b);
		}
		sem.release();
	} else {
		if(debug) say("flatefinish: writing deflated block");

		dhs := array[nfblocks] of ref Dhdr;
		for(i := 0; i < nfblocks; i++) {
			(b, conntime) := fblocks[i];
			dhs[i] = ref Dhdr(b.score, b.dtype, len b.d, conntime);
		}
		offset: big;
		(offset, err) = datastoreflate(dhs, d);
		if(err != nil)
			return err;
		ihs := array[nfblocks] of ref Ihdr;
		for(i = 0; i < nfblocks; i++) {
			(b, nil) := fblocks[i];
			ihs[i] = ref Ihdr(b.score.a[:Indexscoresize], b.dtype, offset, 1);
			err = indexstore(ihs[i]);
			if(err != nil)
				return err;
		}
		sem.obtain();
		for(i = 0; i < nfblocks; i++) {
			(b, nil) := fblocks[i];
			meminsert(ihs[i]);
			writequeue.remove(b);
		}
		sem.release();
if(debug) say("flatefinish: flated block done");
	}
	for(i := 0; i < nfblocks; i++)
		fblocks[i] = (nil, big 0);
	nfblocks = 0;
	rawsize = 0;
	flate = Flate.new(Maxblocksize);
if(debug) say("flatefinish: done");
	return nil;
}

lasterr: string;

seterror(s: string)
{
	if(lasterr == nil || verbose)
		say("write error: "+s);
	if(lasterr == nil) {
		lasterr = s;
		writererrorc<- = s;
	}
}

writer()
{
	flate = Flate.new(Maxblocksize);
	fblocks = array[Maxfblocks] of (ref Block, big);

	for(;;) {
		pick st := <-storec {
		Write =>
			if(lasterr != nil)
				continue;
			b := st.b;
			if(cflag) {
				max := Fhdrsize+(nfblocks+1)*Fbhdrsize+(rawsize+len b.d)*9/10;
				if(nfblocks == Maxfblocks || max > Maxblocksize) {
					err := flatefinish();
					if(err != nil) {
						seterror(err);
						continue;
					}
				}
				err := flate.write(b.d);
				if(err != nil) {
					seterror(err);
					continue;
				}
				fblocks[nfblocks++] = (b, st.c.conntime);
				rawsize += len b.d;

			} else {
				dh := ref Dhdr(b.score, b.dtype, len b.d, st.c.conntime);
				(offset, err) := datastore(dh, b.d);
				ih := ref Ihdr(b.score.a[:Indexscoresize], b.dtype, offset, 0);
				if(err == nil)
					err = indexstore(ih);
				if(err != nil) {
					seterror(err);
					continue;
				}
				sem.obtain();
				meminsert(ih);
				writequeue.remove(b);
				sem.release();
				if(debug) say("writer: data now on file");
			}
		Sync =>
			if(lasterr != nil) {
				if(st.c != nil)
					syncdonec<- = (ref Vmsg.Rerror(0, st.tid, lasterr), st.c);
				continue;
			}
			rmsg: ref Vmsg;
			if(cflag && nfblocks > 0) {
				err := flatefinish();
				if(err != nil) {
					err = "compress/write: "+err;
					seterror(err);
					rmsg = ref Vmsg.Rerror(0, st.tid, err);
					if(st.c != nil)
						syncdonec<- = (rmsg, st.c);
					continue;
				}
			}
			if(sys->fwstat(datafd, sys->nulldir) == 0) {
				rmsg = ref Vmsg.Rsync(0, st.tid);
			} else {
				rmsg = ref Vmsg.Rerror(0, st.tid, sprint("syncing: %r"));
				seterror(sprint("syncing: %r"));
			}
			if(st.c != nil)
				syncdonec<- = (rmsg, st.c);
			if(debug) say("writer: sync is done");
		}
	}
}

nreaders, nbusyreaders, nreaderwrites: int;

lookupsend(w: ref Lookup)
{
	if(nbusyreaders >= nreaders && nreaders < Maxreaders) {
		spawn reader();
		nreaders++;
	}
	if(nbusyreaders >= nreaders) {
		(iswrite, rm, rc) := <-lookupdonec;
		lookupdone(iswrite, rm, rc);
	}
	lookupc<- = w;
	nbusyreaders++;
	if(tagof w == tagof Lookup.Write)
		nreaderwrites++;
	if(debug) say("main: message sent to reader");
}

lookupdone(iswrite: int, rmsg: ref Vmsg, c: ref Client)
{
	nbusyreaders--;
	if(iswrite)
		nreaderwrites--;
	if(c.rpid != -1 && rmsg != nil)
		c.respc<- = rmsg;
	if(debug) say("main: rmsg from reader handled");
}

takewrites()
{
	while(nreaderwrites > 0) {
		(iswrite, rm, rc) := <-lookupdonec;
		lookupdone(iswrite, rm, rc);
	}
}

main()
{
	writeerror: string;

	fio := sys->file2chan(statsdir, statsfile);
	if(fio == nil) {
		say(sprint("file2chan: %r;  not serving statistics"));
		fio = ref sys->FileIO(chan of (int, int, int, sys->Rread), chan of (int, array of byte, int, sys->Rwrite));
	} else
		if(debug) say(sprint("file2chan: serving %s%s", statsdir, statsfile));

	spawn writer();

	configheap = heapused();
	if(verbose)
		say(sprint("heap used after startup=%bd", configheap-initheap));

	for(;;) alt {
	(offset, nil, nil, rc) := <- fio.read =>
		if(rc == nil)
			continue;

		statsem.obtain();
		lnblocks := nblocks;
		lnflateblocks := nflateblocks;
		ldatasize := datasize;
		lnwritesdup := nwritesdup;
		statsem.release();

		h := heapused();
		mean := 0;
		if(lnblocks > 0)
			mean = int (ldatasize/big lnblocks);
		buf := array of byte sprint(
			"%14d reads\n%14d writes\n%14d syncs\n%14d pings\n"+
			"%14d dupwrites\n%14d lookupcollisions\n%14d blocks\n%14d flateblocks\n%14d meanblocksize\n"+
			"%14d readerprocs\n%14d busyreaderprocs\n%14d readerwrites\n"+
			"%14bd totalheap\n%14bd newheap\n%14bd datasize\n%s\n",
			nreads, nwrites, nsyncs, npings,
			lnwritesdup, lookupcollisions, lnblocks, lnflateblocks, mean,
			nreaders, nbusyreaders, nreaderwrites,
			h, h-configheap, ldatasize, writeerror);

		if(offset > len buf)
			offset = len buf;
		rc <-= (buf[offset:], nil);

	(nil, nil, nil, wc) := <- fio.write =>
		if(wc == nil)
			continue;
		if(debug) say("main: file2chan write");
		wc <-= (0, Eperm);

	(iswrite, rmsg, c) := <-lookupdonec =>
		lookupdone(iswrite, rmsg, c);

	err := <-writererrorc =>
		if(debug) say("main: writer error: "+err);
		writeerror = err;

	(rmsg, c) := <-syncdonec =>
		if(c.rpid != -1)
			c.respc<- = rmsg;
		if(debug) say("main: sync rmsg from writer handled");

	(ok, c) := <-wrotec =>
		if(debug) say("main: client wrote vmsg");
		if(ok == 0) {
			if(writeerror == nil && !c.readonly) {
				takewrites();
				storec<- = ref Store.Sync(nil, 0);
			}
			killc(c);
			if(debug) say("main: client killed after write error");
		} else
			c.inuse--;

	(vmsg, c) := <-reqc =>
		if(debug) say("main: client read message: "+vmsg.text());
		if(vmsg == nil) {
			if(writeerror == nil && !c.readonly) {
				takewrites();
				storec<- = ref Store.Sync(nil, 0);
			}
			killc(c);
			if(debug) say("main: client killed after read error");
			continue;
		}
		if(c.inuse >= 256+1) {
			killc(c);
			if(debug) say("main: client killed after too many tids in use");
			continue;
		}
		c.inuse++;

		pick tmsg := vmsg {
		Tread =>
			nreads++;
			if(tmsg.score.eq(zeroscore)) {
				c.respc<- = ref Vmsg.Rread(0, tmsg.tid, array[0] of byte);
				continue;
			}

			sem.obtain();
			d := queuelookup(tmsg.score, tmsg.etype);
			if(d != nil) {
				sem.release();
				c.respc<- = ref Vmsg.Rread(0, tmsg.tid, d);
				continue;
			}
			addrs := memlookup(tmsg.score, tmsg.etype);
			sem.release();
			if(len addrs == 0) {
				c.respc<- = ref Vmsg.Rerror(0, tmsg.tid, "no such score/type");
				continue;
			}

			lookupsend(ref Lookup.Read(c, tmsg.tid, addrs, tmsg.score, tmsg.etype, tmsg.n));

		Twrite =>
			nwrites++;
			nowritemsg: string;
			if(writeerror != nil)
				nowritemsg = writeerror;
			if(c.readonly)
				nowritemsg = "writes not allowed";
			if(nowritemsg != nil) {
				c.respc<- = ref Vmsg.Rerror(0, tmsg.tid, nowritemsg);
				continue;
			}

			score := Score(sha1(tmsg.data));

			if(score.eq(zeroscore)) {
				c.respc<- = ref Vmsg.Rwrite(0, tmsg.tid, score);
				continue;
			}

			sem.obtain();
			d := queuelookup(score, tmsg.etype);
			if(d != nil) {
				sem.release();
				c.respc<- = ref Vmsg.Rwrite(0, tmsg.tid, score);
				continue;
			}
			if(writequeue.n >= Maxpendingwrites) {
				sem.release();
				c.respc<- = ref Vmsg.Rerror(0, tmsg.tid, "write queue full");
				continue;
			}
			addrs := memlookup(score, tmsg.etype);
			writequeue.insert(b := ref Block(score, tmsg.etype, tmsg.data));
			sem.release();

			if(len addrs > 0)
				lookupsend(ref Lookup.Write(c, tmsg.tid, addrs, b));
			else
				storec<- = ref Store.Write(c, b);
			c.respc<- = ref Vmsg.Rwrite(0, tmsg.tid, score);

		Tsync =>
			nsyncs++;
			nowritemsg: string;
			if(writeerror != nil)
				nowritemsg = writeerror;
			if(c.readonly)
				nowritemsg = "writes not allowed";
			if(nowritemsg != nil) {
				c.respc<- = ref Vmsg.Rerror(0, tmsg.tid, nowritemsg);
			} else {
				takewrites();
				storec<- = ref Store.Sync(c, tmsg.tid);
			}

		Tping =>
			npings++;
			c.respc<- = ref Vmsg.Rping(0, tmsg.tid);

		* =>
			if(debug) say(sprint("main: bad tmsg, tag=%d", tagof vmsg));
		}
	}
}

readline(fd: ref Sys->FD): array of byte
{
	buf := array[128]  of byte;
	for(i := 0; i < len buf; i++) {
		if(sys->read(fd, buf[i:], 1) != 1)
			return nil;
		if(buf[i] == byte '\n')
			return buf[:i];
	}
	sys->werrstr("version line too long");
	return nil;
}

compatible(s: string): int
{
	if(!str->prefix("venti-", s))
		return 0;
	(s, nil) = str->splitstrr(s[len "venti-":], "-");
	if(s == nil)
		return 0;
	for(l := sys->tokenize(s[:len s-1], ":").t1; l != nil; l = tl l)
		if(hd l == "02")
			return 1;
	return 0;
}

handshake(fd: ref Sys->FD): string
{
	if(sys->fprint(fd, "venti-02-ventisrv\n") < 0)
		return sprint("writing version: %r");

	d := readline(fd);
	if(d == nil)
		return sprint("bad version (%r)");
	if(!compatible(vers := string d))
		return sprint("bad version (%s)", vers);

	(tvmsg, terr) := Vmsg.read(fd);
	if(terr != nil)
		return "reading thello: "+terr;

	if(tagof tvmsg != tagof Vmsg.Thello)
		return "first message not thello";

	rvmsg := ref Vmsg.Rhello(0, 0, nil, 0, 0);
	md := rvmsg.pack();
	if(md == nil || sys->write(fd, md, len md) != len md)
		return sprint("writing rhello: %r");
	return nil;
}

client(fd, cfd: ref Sys->FD, readonly: int)
{
	conntime := big daytime->now();
	hsdone := chan[1] of int;
	spawn handshaketimer(cfd, hsdone);
	herr := handshake(fd);
	hsdone <-= 1;
	if(herr != nil) {
		if(debug) say("handshake failed: "+herr);
		return;
	}

	c := ref Client(sys->pctl(0, nil), 0, chan[256+1] of ref Vmsg, 0, conntime, readonly);
	spawn cwriter(fd, pidc := chan of int, c);
	c.wpid = <-pidc;

	for(;;) {
		(vmsg, err) := Vmsg.read(fd);
		if(vmsg != nil && !vmsg.istmsg)
			err = "message not tmsg";
		if(vmsg != nil && tagof vmsg == tagof Vmsg.Tgoodbye)
			err = "closing down";
		if(err != nil || vmsg == nil) {
			if(debug) say("client: reading: "+err);
			break;
		}

		reqc<- = (vmsg, c);
	}
	reqc<- = (nil, c);
}

cwriter(fd: ref Sys->FD, pidc: chan of int, c: ref Client)
{
	pidc<- = sys->pctl(0, nil);
	for(;;) {
		rmsg := <-c.respc;
		if(rmsg == nil) {
			if(debug) say("client: have nil on respc, closing");
			break;
		}
		d := rmsg.pack();
		n := sys->write(fd, d, len d);
		if(n != len d) {
			if(debug) say(sprint("client: writing rmsg: %r"));
			break;
		}
		wrotec<- = (1, c);
	}
	if(debug) say("client: exiting");
	wrotec<- = (0, c);
}

halfcmp(hs: array of byte, s: array of byte, hdt, dt: int): int
{
	if(hdt != dt)
		return hdt - dt;
	for(i := 0; i < len hs; i++)
		if(hs[i] != s[i])
			return int hs[i] - int s[i];
	return 0;
}

indexstore(ih: ref Ihdr): string
{
	d := array[Ihdrsize] of byte;
	ih.pack(d);
	n := sys->pwrite(indexfd, d, len d, indexsize);
	if(n != len d)
		return sprint("writing index at offset=%bd: %r", indexsize);
if(debug) say(sprint("indexstore: stored at indexsize=%bd data offset=%bd", indexsize, ih.offset));
	indexsize += big n;
	return nil;
}

datastoreflate(blocks: array of ref Dhdr, d: array of byte): (big, string)
{
if(debug) say(sprint("datastoreflate: len blocks=%d len d=%d", len blocks, len d));
	fh := ref Fhdr(blocks, len blocks*Fbhdrsize, len d);
	fhbuf := array[Fhdrsize+fh.hsize] of byte;
	fh.pack(fhbuf);
	if(big (len fhbuf+len d)+datasize > maxdatasize)
		return (datasize, sprint("data file full"));

	n := sys->pwrite(datafd, fhbuf, len fhbuf, datasize);
	if(n != len fhbuf)
		return (datasize, sprint("writing flateblock header: %r"));

	n = sys->pwrite(datafd, d, len d, datasize+big len fhbuf);
	if(n != len d)
		return (datasize, sprint("writing flateblock data: %r"));

	offset := datasize;
	statsem.obtain();
	datasize += big (len fhbuf+len d);
	nblocks += len blocks;
	nflateblocks += len blocks;
	statsem.release();
if(debug) say(sprint("datastoreflate: stored at offset=%bd datasize=%bd len blocks=%d comprsize=%d", offset, datasize, len blocks, len d));
	return (offset, nil);
}


datastore(dh: ref Dhdr, d: array of byte): (big, string)
{
	if(dh.size != len d)
		fail(sprint("datastore: refusing to write block, header says %d bytes, data is %d bytes", dh.size, len d));
	if(big (Dhdrsize+dh.size)+datasize > maxdatasize)
		return (datasize, sprint("data file full"));

	dhbuf := array[Dhdrsize] of byte;
	dh.pack(dhbuf);
	n := sys->pwrite(datafd, dhbuf, len dhbuf, datasize);
	if(n != len dhbuf)
		return (datasize, sprint("writing data header: %r"));

	n = sys->pwrite(datafd, d, len d, datasize+big len dhbuf);
	if(n != len d)
		return (datasize, sprint("writing data: %r"));

	offset := datasize;
	statsem.obtain();
	datasize += big (len dhbuf+len d);
	nblocks++;
	statsem.release();
if(debug) say(sprint("datastore: stored at offset=%bd datasize=%bd blocksize=%d", offset, datasize, dh.size));
	return (offset, nil);
}

offsetread(offset: big): (array of ref Dhdr, int, big, string)
{
	d := array[Maxblocksize] of byte;
	n := preadn(datafd, d, len d, offset);
	if(n < 0)
		return (nil, 0, big 0, sprint("reading: %r"));
	if(n < 4)
		return (nil, 0, big 0, "short header");
	case get32(d, 0) {
	Dhdrmagic =>
		if(len d < Dhdrsize)
			return (nil, 0, big 0, "short dheader");

		(dhdr, err) := Dhdr.unpack(d);
		if(err != nil)
			return (nil, 0, big 0, "unpack dheader: "+err);
		if(Dhdrsize+dhdr.size > len d)
			return (nil, 0, big 0, "dheader points outside data file");

		score := Score(sha1(d[Dhdrsize:Dhdrsize+dhdr.size]));
		if(!score.eq(dhdr.score))
			return (nil, 0, big 0, sprint("dheader score (%s) does not match actual score (%s) at offset=%bd",
				dhdr.score.text(), score.text(), offset));
		return (array[1] of {dhdr}, 0, offset+big (Dhdrsize+dhdr.size), nil);

	Fhdrmagic =>
		if(len d < Fhdrsize)
			return (nil, 0, big 0, "short fheader");

		(fhdr, o, err) := Fhdr.unpack(d);
		if(err != nil)
			return (nil, 0, big 0, "unpack fheader: "+err);
		if(Fhdrsize+fhdr.hsize+fhdr.dsize > len d)
			return (nil, 0, big 0, "fheader points outside data file");

		nb := len fhdr.blocks;
		lb := fhdr.blocks[nb-1];
		uncsize := o[nb-1]+lb.size;
		dst := array[uncsize] of byte;
		s := Fhdrsize+fhdr.hsize;
		err = decompress(d[s:s+fhdr.dsize], dst);
		if(err != nil)
			return (nil, 0, big 0, "decompressing: "+err);

		for(i := 0; i < len fhdr.blocks; i++) {
			dhdr := fhdr.blocks[i];
			off := o[i];
			score := Score(sha1(dst[off:off+dhdr.size]));
			if(!score.eq(dhdr.score))
				return (nil, 0, big 0, sprint("fheader score (%s, i=%d) does not match actual score (%s) at offset=%bd",
					dhdr.score.text(), i, score.text(), offset));
		}
		return (fhdr.blocks, 1, offset+big (Fhdrsize+fhdr.hsize+fhdr.dsize), nil);

	* =>
		return (nil, 0, big 0, "bad magic");
	}
}

dblockget(offset: big, score: Score, dtype, readdata, size: int): (int, array of byte, string)
{
if(debug) say(sprint("blockread offset=%bd", offset));
	rsize := size;
	if(rsize == Venti->Maxlumpsize)
		rsize = 8*1024;
	buf := array[Dhdrsize+rsize] of byte;
	n := preadn(datafd, buf, len buf, offset);
	if(n < Dhdrsize)
		return (0, nil, sprint("reading block header at offset=%bd: %r", offset));

	(dh, err) := Dhdr.unpack(buf[:Dhdrsize]);
	if(err != nil)
		return (0, nil, err);

	d: array of byte;
	if(readdata) {
		d = buf[Dhdrsize:];
		if(len d > dh.size)
			d = d[:dh.size];
		if(len d < dh.size) {
			if(size == rsize)
				return (0, nil, sprint("data (%d bytes) larger than requested (%d bytes)", dh.size, size));
			newd := array[dh.size] of byte;
			newd[:] = d;
			want := len newd-len d;
			n = preadn(datafd, newd[len d:], want, offset+big len buf);
			if(n >= 0 && n < want)
				sys->werrstr("short read");
			if(n != want)
				return (0, nil, sprint("reading block at offset=%bd: %r", offset));
			d = newd;
		}
		ds := Score(sha1(d[:dh.size]));
		if(!dh.score.eq(ds))
			return (0, nil, sprint("mismatching score for block at offset=%bd: header=%s data=%s", offset, dh.score.text(), ds.text()));
	}

	if(!score.eq(dh.score) || dh.dtype != dtype)
		return (0, nil, nil);
	return (1, d, nil);
}

flatequeueadd(blocks: array of ref Dhdr, o: array of int, d: array of byte)
{
	flatequeue.sem.obtain();
	for(i := 0; i < len blocks; i++) {
		dh := blocks[i];
		off := o[i];
		flatequeue.insert(ref Block(dh.score, dh.dtype, d[off:off+dh.size]));
	}
	flatequeue.sem.release();
}

fblockget(offset: big, score: Score, dtype, readdata, size: int): (int, array of byte, string)
{
	buf := array[Maxblocksize] of byte;
	n := preadn(datafd, buf, len buf, offset);
	if(n < 0)
		return (0, nil, sprint("reading: %r"));
	buf = buf[:n];
	(f, o, err) := Fhdr.unpack(buf);
	if(err != nil)
		return (0, nil, err);
	for(i := 0; i < len f.blocks; i++) {
		dh := f.blocks[i];
		if(dh.dtype == dtype && dh.score.eq(score)) {
			if(dh.size > size)
				return (0, nil, sprint("data (%d) larger than requested (%d)", dh.size, size));
if(debug) say("flateblockget: hit");
			if(!readdata)
				return (1, nil, nil);
			nb := len f.blocks;
			lb := f.blocks[nb-1];
			dst := array[o[nb-1]+lb.size] of byte;
			s := Fhdrsize+f.hsize;
			if(len buf < s+f.dsize)
				return (0, nil, sprint("fheader points outside datafile at offset=%bd need=%d have=%d", offset, s+f.dsize, n));
			err = decompress(buf[s:s+f.dsize], dst);
			if(err != nil)
				return (0, nil, "decompressing: "+err);
			flatequeueadd(f.blocks, o, dst);
			off := o[i];
			return (1, dst[off:off+dh.size], nil);
		}
	}
if(debug) say("flateblockget: miss");
	return (0, nil, nil);
}

blockget(compressed: int, offset: big, score: Score, dtype: int, readdata: int, size: int): (int, array of byte, string)
{
	if(compressed)
		return fblockget(offset, score, dtype, readdata, size);
	return dblockget(offset, score, dtype, readdata, size);
}

datalookup(offsets: list of (int, big), score: Score, dtype: int, readdata: int, size: int): (int, array of byte, string)
{
	err: string;
	for(l := offsets; l != nil; l = tl l) {
		(compr, o) := hd l;
		(hit, d, derr) := blockget(compr, o, score, dtype, readdata, size);
		if(hit)
			return (hit, d, nil);
		if(derr != nil)
			err = derr;
	}
	return (0, nil, err);
}

getscore(c: ref Chain, i: int, a: array of byte)
{
	b := (i+1)*membytes-1-scorebytes;
	a[0] = c.d[b]&scorebytemask;
	for(j := 1; j < scorebytes; j++)
		a[j] = c.d[b+j];
}

dumpchain(c: ref Chain)
{
	for(i := 0; i < c.used; i++) {
		l := (i+1)*membytes-1;
		dtype := c.d[l];
		getscore(c, i, d := array[scorebytes] of byte);
		(compr, addr) := c.getaddr(i);
		say(sprint("  i=%d dtype=%d addr=%bd compr=%d score=%s", i, int dtype, addr, compr, scorestr(d)));
	}
}

dumphead(score: Score)
{
	i := 0;
	for(c := heads[head(score.a)]; c != nil; c = c.next) {
		say(sprint("chain %d, c.used=%d", i++, c.used));
		dumpchain(c);
	}
}

blockcmp(c: ref Chain, j: int, d: array of byte): int
{
	o := (j+1)*membytes-1;
	for(i := len d-1; i > 0; i--) {
		if(c.d[o] != d[i])
			return int c.d[o]-int d[i];
		o--;
	}
	return int (c.d[o]&scorebytemask)-int (d[0]&scorebytemask);
}

find(c: ref Chain, d: array of byte): int
{
	f := 0;
	l := c.used;
	while(f < l) {
		m := (f+l)/2;
		cmp := blockcmp(c, m, d);
		if(cmp < 0)
			f = m+1;
		else
			l = m;
	}
	return l;
}

find0(c: ref Chain, d: array of byte): int
{
	for(i := 0; i < c.used; i++)
		if(blockcmp(c, i, d) >= 0)
			return i;
	return i;
}

Chain.getaddr(c: self ref Chain, j: int): (int, big)
{
	o := j*membytes;
	v := big 0;
	for(b := addrbits; b >= 8; b -= 8)
		v |= big c.d[o++] << (b-8);
	if(b > 0)
		v |= big c.d[o] >> (8-b);
	iscompr := Cflag && int ((v&comprmask)>>(addrbits-1));
	if(iscompr)
		v &= ~comprmask;
	return (iscompr, v);
}

Chain.lookup(c: self ref Chain, d: array of byte, l: list of (int, big)): list of (int, big)
{
	for(i := find(c, d); i < c.used && blockcmp(c, i, d) == 0; i++)
		l = c.getaddr(i)::l;
	return l;
}

lookup0(c: ref Chain, d: array of byte, l: list of (int, big)): list of (int, big)
{
	for(i := find0(c, d); i < c.used && blockcmp(c, i, d) == 0; i++)
		l = c.getaddr(i)::l;
	return l;
}

Chain.insert(c: self ref Chain, ih: ref Ihdr)
{
	d := array[membytes] of byte;
	mkentry(ih, d);
	i := find(c, d[len d-(scorebytes+1):]);
	c.d[(i+1)*membytes:] = c.d[i*membytes:c.used*membytes];
	c.d[i*membytes:] = d;
	c.used++;
}

Chain.mk(): ref Chain
{
	return ref Chain(array[chainblocks*membytes] of byte, 0, nil);
}

sha1(a: array of byte): array of byte
{
	r := array[kr->SHA1dlen] of byte;
	kr->sha1(a, len a, r, nil);
	return r;
}

scorestr(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sprint("%02x", int d[i]);
	return s;
}


Fifo.lookup(l: self ref Fifo, s: Score, dtype: int): array of byte
{
	for(i := 0; i < l.n; i++) {
		b := l.a[i];
		if(b.dtype == dtype && b.score.eq(s))
			return b.d;
	}
	return nil;
}

Fifo.insert(l: self ref Fifo, b: ref Block)
{
	l.a[l.f] = b;
	l.f = (l.f+1)%len l.a;
	if(l.n < len l.a)
		l.n++;
}


Queue.lookup(q: self ref Queue, s: Score, dtype: int): array of byte
{
	for(i := 0; i < q.n; i++)
		if(q.a[i].dtype == dtype && q.a[i].score.eq(s))
			return q.a[i].d;
	return nil;
}

Queue.insert(q: self ref Queue, b: ref Block)
{
	if(q.n >= len q.a) {
		newa := array[2*len q.a] of ref Block;
		newa[:] = q.a;
		q.a = newa;
	}
	q.a[q.n++] = b;
}

Queue.remove(q: self ref Queue, b: ref Block)
{
	for(i := 0; i < q.n; i++) {
		if(q.a[i] == b) {
			q.a[i:] = q.a[i+1:q.n];
			q.a[--q.n] = nil;
			return;
		}
	}
fail("did not remove anything");
}

queuelookup(score: Score, dtype: int): array of byte
{
	d := writequeue.lookup(score, dtype);
	if(d == nil)
		d = flatequeue.lookup(score, dtype);
	return d;
}

head(d: array of byte): int
{
	return ((int d[0]<<0)|(int d[1]<<8)|(int d[2]<<16)) % len heads;
}

chain(d: array of byte): ref Chain
{
	c := heads[h := head(d)];
	if(c == nil)
		c = heads[h] = Chain.mk();
	while(c.next != nil)
		c = c.next;
	if(c.used >= chainblocks) {
		c.next = Chain.mk();
		c = c.next;
	}
	return c;
}

meminsert(ih: ref Ihdr)
{
	if(debug) say(sprint("insert: adding halfscore=%s type=%d offset=%bd compressed=%d", scorestr(ih.halfscore), ih.dtype, ih.offset, ih.compressed));
	chain(ih.halfscore).insert(ih);
}

mkentry(ih: ref Ihdr, d: array of byte)
{
	mkmem(ih.halfscore, ih.dtype, d[len d-(scorebytes+1):]);
	o := 0;
	offset := ih.offset;
	if(ih.compressed)
		offset |= comprmask;
	for(b := addrbits; b >= 8; b-= 8)
		d[o++] = byte (offset>>(b-8));
	if(b > 0)
		d[o++] |= byte (offset<<(8-b));
}

mkmem(a: array of byte, dtype: int, d: array of byte)
{
	d[:] = a[headbytes:headbytes+scorebytes];
	d[0] &= scorebytemask;
	d[len d-1] = byte dtype;
}

memlookup(score: Score, dtype: int): list of (int, big)
{
	if(debug) say(sprint("lookup: looking for score=%s type=%d", score.text(), dtype));

	mkmem(score.a, dtype, d := array[scorebytes+1] of byte);
	addrs: list of (int, big);
	for(c := heads[head(score.a)]; c != nil; c = c.next)
		addrs = c.lookup(d, addrs);
	if(len addrs > 1)
		lookupcollisions += len addrs-1;
	return addrs;
}

memlookup0(score: Score, dtype: int): list of (int, big)
{
	if(debug) say(sprint("lookup: looking for score=%s type=%d", score.text(), dtype));

	mkmem(score.a, dtype, d := array[scorebytes+1] of byte);
	addrs: list of (int, big);
	for(c := heads[head(score.a)]; c != nil; c = c.next)
		addrs = lookup0(c, d, addrs);
	return addrs;
}

preadn(fd: ref Sys->FD, d: array of byte, want: int, offset: big): int
{
	have := 0;
	while(want - have > 0) {
		n := sys->pread(fd, d[have:], want-have, offset+big have);
		if(n < 0)
			return -1;
		if(n == 0)
			break;
		have += n;
	}
	return have;
}

get16(d: array of byte, i: int): int
{
	return (int d[i]<<8) | (int d[i+1]<<0);
}

get32(d: array of byte, i: int): big
{
	return (big get16(d, i)<<16)|big get16(d, i+2);
}

get48(d: array of byte, i: int): big
{
	return (big get16(d, i)<<32)|get32(d, i+2);
}

put16(d: array of byte, i: int, v: int)
{
	d[i+0] = byte (v>>8);
	d[i+1] = byte (v>>0);
}

put32(d: array of byte, i: int, v: big)
{
	put16(d, i+0, int (v>>16));
	put16(d, i+2, int (v>>0));
}

put48(d: array of byte, i: int, v: big)
{
	put16(d, i+0, int(v>>32));
	put32(d, i+2, v>>0);
}

Ihdr.unpack(d: array of byte): ref Ihdr
{
	o := 0;
	halfscore := d[o:o+Indexscoresize];
	o += Indexscoresize;
	dtype := int d[o];
	o += 1;
	offset := get48(d, o);
	compressed := 0;
	if((offset&Icomprmask) == Icomprmask)
		compressed = 1;
	offset &= ~Icomprmask;
	o += 6;
	if(o != Ihdrsize)
		fail("bad iheader.unpack");
	return ref Ihdr(halfscore, dtype, offset, compressed);
}

Ihdr.pack(ih: self ref Ihdr, d: array of byte)
{
	o := 0;
	d[o:] = ih.halfscore;
	o += len ih.halfscore;
	d[o] = byte ih.dtype;
	o += 1;
	offset := ih.offset;
	if(ih.compressed)
		offset |= Icomprmask;
	put48(d, o, offset);
	o += 6;
	if(o != Ihdrsize)
		fail("bad iheader.pack");
}

Dhdr.unpack(d: array of byte): (ref Dhdr, string)
{
	o := 0;
	if(get32(d, o) != Dhdrmagic)
		return (nil, "bad dhdr magic");
	o += 4;
	score := d[o:o+Scoresize];
	o += Scoresize;
	dtype := int d[o];
	o += 1;
	size := get16(d, o);
	o += 2;
	conntime := get32(d, o);
	o += 4;
	if(o != Dhdrsize)
		fail("bad dheader.unpack");
	return (ref Dhdr(Score(score), dtype, size, conntime), nil);
}

Dhdr.pack(dh: self ref Dhdr, d: array of byte)
{
	o := 0;
	put32(d, o, Dhdrmagic);
	o += 4;
	d[o:] = dh.score.a;
	o += Scoresize;
	d[o] = byte dh.dtype;
	o += 1;
	put16(d, o, dh.size);
	o += 2;
	put32(d, o, dh.conntime);
	o += 4;
	if(o != Dhdrsize)
		fail("bad dheader.pack");
}


Fhdr.unpack(d: array of byte): (ref Fhdr, array of int, string)
{
	o := 0;
	if(get32(d, o) != Fhdrmagic)
		return (nil, nil, "bad fhdr magic");
	o += 4;
	nb := int d[o++];
	hsize := nb*Fbhdrsize;
	if(o+hsize > len d)
		return (nil, nil, "header points outside buffer");
	dsize := get16(d, o);
	o += 2;

	offset := 0;
	b := array[nb] of ref Dhdr;
	offsets := array[nb] of int;
	for(i := 0; i < nb; i++) {
		score := d[o:o+Scoresize];
		o += Scoresize;
		dtype := int d[o];
		o += 1;
		size := get16(d, o);
		o += 2;
		conntime := get32(d, o);
		o += 4;
		b[i] = ref Dhdr(Score(score), dtype, size, conntime);
		offsets[i] = offset;
		offset += size;
	}
	return (ref Fhdr(b, hsize, dsize), offsets, nil);
}

Fhdr.pack(fh: self ref Fhdr, d: array of byte)
{
	o := 0;
	put32(d, o, Fhdrmagic);
	o += 4;
	d[o] = byte len fh.blocks;
	o += 1;
	put16(d, o, fh.dsize);
	o += 2;
	for(i := 0; i < len fh.blocks; i++) {
		b := fh.blocks[i];
		d[o:] = b.score.a;
		o += Scoresize;
		d[o] = byte b.dtype;
		o += 1;
		put16(d, o, b.size);
		o += 2;
		put32(d, o, b.conntime);
		o += 4;
	}
	if(o != Fhdrsize+len fh.blocks*Fbhdrsize)
		fail("bad fhdr.pack");
}

mfd: ref Sys->FD;
Current, Max: con iota;

heapinfo(which: int): big
{
	if(mfd == nil)
		mfd = sys->open("/dev/memory", sys->OREAD);
        if(mfd == nil)
               fail(sprint("open /dev/memory: %r")); 
        sys->seek(mfd, big 0, Sys->SEEKSTART);

        buf := array[400] of byte;
        n := sys->read(mfd, buf, len buf);
        if(n <= 0)
                fail(sprint("reading /dev/memory: %r"));

        (nil, l) := sys->tokenize(string buf[0:n], "\n");
        for(; l != nil; l = tl l)
                if((hd l)[7*12:] == "heap" && which == Current)
			return big ((hd l)[0:12]);
                else if ((hd l)[7*12:] == "heap" && which == Max)
			return big ((hd l)[12:24]);
	fail("missing heap line in /dev/memory");
	return big 0;
}

heapmax(): big
{
	return heapinfo(Max);
}

heapused(): big
{
	return heapinfo(Current);
}

suffix(s: string): big
{
	l := array[] of {'k', 'm', 'g', 't', 'p'};
	mult := big 1;
	if(s == nil)
		return big 0;
	s = str->tolower(s);
	for(i := 0; i < len l; i++) {
		mult *= big 1024;
		if(s[len s-1] == l[i])
			return mult * big s[:len s-1];
	}
	return big s;
}

log2(v: big): int
{
	for(bits := 0; (big 1<<bits) < v; bits++)
		;
	return bits;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}

say(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}
