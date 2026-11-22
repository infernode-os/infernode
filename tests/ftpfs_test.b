implement FtpfsTest;

#
# ftpfs(4) against an FTP server that is not a friend.  ftpfs is started
# by hand against a server its user chose, and FTP is in clear, so the
# server is whoever answers.  With a server of the test's own on the
# loopback (reached by name through a connection server of the test's
# own, in a name space of its own):
#
# - a PASV reply's address was dialled whatever it was: the server sent
#   the client to connect to, and to send a stored file's bytes to, any
#   address it named.  The data connection goes to the control
#   connection's other end, and only the port is the reply's.
# - a directory's entries carried a qid, type and dev that nothing had
#   set (a Limbo frame's words: here an address of the emulator's), the
#   same in every entry.
# - a read at an offset of 2^31 indexed a file's first block with a
#   negative number, and a reply of the code alone ("250") was indexed
#   past its end: either ended the server, and every later use of the
#   mount waited for ever.
# - a file the server refused to store was reported as written, and
#   the refusal printed on standard output.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

FtpfsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SRCFILE: con "/tests/ftpfs_test.b";

passed := 0;
failed := 0;
skipped := 0;

# Each test in a process of its own, and given up on after a while: a
# mount whose server has stopped answering holds whoever touches it,
# the close of a file on it included.
run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	done := chan[1] of int;
	tmo := chan[1] of int;
	spawn body(testfn, t, done);
	spawn timer(tmo, 20000);
	alt {
	<-done =>
		;
	<-tmo =>
		t.error("not finished after 20 s: the mount no longer answers");
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

body(testfn: ref fn(t: ref T), t: ref T, done: chan of int)
{
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	done <-= 1;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

portof(c: Sys->Connection): string
{
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		return hd tl l;
	return "";
}

# ---- a connection server: "tcp!ftp.test!ftp" is the test's server ----

NAME: con "ftp.test";
ftpport: string;
csup := 0;

translate(q: string): (string, string)
{
	(n, f) := sys->tokenize(q, "!");
	if(n != 3)
		return (nil, "cs: can't translate address");
	name := hd tl f;
	port := hd tl tl f;
	if(name == NAME && port == "ftp")
		return ("/net/tcp/clone 127.0.0.1!" + ftpport, nil);
	if(len name > 0 && name[0] >= '0' && name[0] <= '9')
		return ("/net/tcp/clone " + name + "!" + port, nil);
	return (nil, "cs: can't translate address");
}

csserve(fio: ref Sys->FileIO)
{
	answers: list of (int, string);
	for(;;) alt {
	(off, count, fid, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		a: array of byte;
		for(l := answers; l != nil; l = tl l)
			if((hd l).t0 == fid) {
				a = array of byte (hd l).t1;
				break;
			}
		if(off >= len a)
			rc <-= (nil, nil);
		else {
			if(off + count > len a)
				count = len a - off;
			rc <-= (a[off:off+count], nil);
		}
	(nil, data, fid, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		(r, err) := translate(string data);
		if(err != nil)
			wc <-= (0, err);
		else {
			answers = (fid, r) :: answers;
			wc <-= (len data, nil);
		}
	}
}

# ---- the FTP server ----

LISTING: con
	"drwxr-xr-x 2 u g 4096 Jan  1 00:00 d\r\n" +
	"-rw-r--r-- 1 u g 6 Jan  1 00:00 f\r\n" +
	"drwxr-xr-x 2 u g 4096 Jan  1 00:00 crash3\r\n";

redirect := 0;	# PASV names the third party's address
thirdhit := 0;	# the third party was connected to
thirds: list of string;	# where third parties listen
thirdstop := 0;
stored := 0;	# bytes a STOR sent
stopping := 0;

say(fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	sys->write(fd, b, len b);
}

# a command line of the control connection; nil at its end
getline(fd: ref Sys->FD): string
{
	s := "";
	b := array[1] of byte;
	for(;;) {
		if(sys->read(fd, b, 1) != 1)
			return nil;
		if(b[0] == byte '\n')
			break;
		if(b[0] != byte '\r')
			s[len s] = int b[0];
	}
	return s;
}

# the data connection PASV promised, if the client makes it within a
# second and a half
accept(dc: Sys->Connection): ref Sys->FD
{
	c := chan[1] of ref Sys->FD;
	tmo := chan[1] of int;
	spawn acceptor(dc, c);
	spawn timer(tmo, 1500);
	alt {
	d := <-c =>
		return d;
	<-tmo =>
		# it went elsewhere: let the acceptor go
		sys->dial("tcp!127.0.0.1!" + portof(dc), nil);
		return nil;
	}
}

acceptor(dc: Sys->Connection, c: chan of ref Sys->FD)
{
	(ok, nc) := sys->listen(dc);
	if(ok < 0) {
		c <-= nil;
		return;
	}
	c <-= sys->open(nc.dir + "/data", Sys->ORDWR);
}

ftpconn(fd: ref Sys->FD)
{
	say(fd, "220 test ftp\r\n");
	cwd := "/";
	dc: Sys->Connection;
	havedc := 0;
	while((l := getline(fd)) != nil) {
		verb := l;
		arg := "";
		for(i := 0; i < len l; i++)
			if(l[i] == ' ') {
				verb = l[0:i];
				arg = l[i+1:];
				break;
			}
		case verb {
		"USER" =>
			say(fd, "331 pw\r\n");
		"PASS" =>
			say(fd, "230 ok\r\n");
		"TYPE" or "NOOP" =>
			say(fd, "200 ok\r\n");
		"PWD" =>
			say(fd, "257 \"/\" is current\r\n");
		"CWD" =>
			if(stalling && (arg == "/d" || arg == "//d")) {
				# no answer
				sys->sleep(20000);
				return;
			}
			if(madedir && (arg == "/d/newdir" || arg == "//d/newdir")) {
				cwd = arg;
				say(fd, "250 ok\r\n");
			} else if(len arg >= 6 && arg[len arg - 6:] == "crash3") {
				cwd = arg;
				say(fd, "250\r\n");	# the code and nothing more
			} else if(arg == "/" || arg == "/d" || arg == "//d") {
				cwd = arg;
				say(fd, "250 ok\r\n");
			} else
				say(fd, "550 no\r\n");
		"PASV" =>
			ok: int;
			(ok, dc) = sys->announce("tcp!127.0.0.1!0");
			if(ok < 0) {
				say(fd, "425 no\r\n");
				continue;
			}
			havedc = 1;
			p := int portof(dc);
			if(redirect) {
				# the same port at another address, where someone
				# else is listening
				(tok, tc) := sys->announce("tcp!127.0.0.78!" + string p);
				if(tok >= 0) {
					thirds = "tcp!127.0.0.78!" + string p :: thirds;
					spawn thirdparty(tc);
				}
				say(fd, sys->sprint("227 Entering Passive Mode (127,0,0,78,%d,%d)\r\n", p >> 8, p & 255));
			} else if(pasvbare)
				say(fd, sys->sprint("227 Entering Passive Mode 127,0,0,1,%d,%d\r\n", p >> 8, p & 255));
			else
				say(fd, sys->sprint("227 Entering Passive Mode (127,0,0,1,%d,%d)\r\n", p >> 8, p & 255));
		"LIST" =>
			lists = arg :: lists;
			if(faillists > 0) {
				# a listing that cannot be had just now, long or not
				faillists--;
				havedc = 0;
				say(fd, "425 cannot open a data connection\r\n");
				continue;
			}
			say(fd, "150 here\r\n");
			if(havedc) {
				d := accept(dc);
				havedc = 0;
				if(d == nil) {
					say(fd, "425 no data connection\r\n");
					continue;
				}
				if(cwd == "/")
					say(d, LISTING);
				else if(madedir && (cwd == "/d" || cwd == "//d"))
					say(d, "drwxr-xr-x 2 u g 0 Jan  1 00:00 newdir\r\n");
				d = nil;
			}
			say(fd, "226 done\r\n");
		"RETR" =>
			say(fd, "150 here\r\n");
			if(havedc) {
				d := accept(dc);
				if(d != nil)
					say(d, "hello\n");
				d = nil;
				havedc = 0;
			}
			say(fd, "226 done\r\n");
		"MKD" =>
			cmds = l :: cmds;
			madedir = 1;
			say(fd, "257 made\r\n");
		"DELE" or "RMD" =>
			cmds = l :: cmds;
			say(fd, "550 removal is against policy here\r\n");
		"STOR" =>
			cmds = l :: cmds;
			say(fd, "150 send\r\n");
			if(havedc) {
				d := accept(dc);
				buf := array[8192] of byte;
				while(d != nil && (n := sys->read(d, buf, len buf)) > 0)
					stored += n;
				d = nil;
				havedc = 0;
			}
			say(fd, "553 not allowed\r\n");
		"QUIT" =>
			say(fd, "221 bye\r\n");
			return;
		* =>
			say(fd, "500 what\r\n");
		}
	}
}

# someone a PASV reply can point at: says so, and gives a listing of its own
thirdparty(c: Sys->Connection)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0 || thirdstop)
		return;
	thirdhit = 1;
	d := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(d != nil)
		say(d, "-rw-r--r-- 1 u g 5 Jan  1 00:00 from-third-party\r\n");
}

ftpserve(c: Sys->Connection)
{
	for(;;) {
		(ok, nc) := sys->listen(c);
		if(ok < 0 || stopping)
			return;
		fd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(fd != nil)
			spawn ftpconn(fd);
	}
}

# what the tests ask of the server, and what it saw
stalling := 0;		# a CWD to d is never answered
pasvbare := 0;		# PASV's numbers without brackets
faillists := 0;		# so many LISTs refused
madedir := 0;		# MKD newdir has been taken
lists: list of string;	# each LIST's argument, newest first
cmds: list of string;	# MKD, DELE, RMD and STOR as they came, newest first
extraargs: list of string;	# more options for the next ftpfs

saw(verb: string): int
{
	for(l := cmds; l != nil; l = tl l)
		if(len hd l >= len verb && (hd l)[0:len verb] == verb)
			return 1;
	return 0;
}

# ---- ftpfs ----

Out: adt {
	s:	string;
};

collect(fd: ref Sys->FD, o: ref Out)
{
	buf := array[1024] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		o.s += string buf[0:n];
}

runftpfs(args: list of string, out, err: ref Sys->FD, done: chan of int)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(out.fd, 1);
	sys->dup(err.fd, 2);
	out = nil;
	err = nil;
	ftpfs := load Command "/dis/ftpfs.dis";
	if(ftpfs == nil) {
		done <-= -1;
		return;
	}
	{
		ftpfs->init(nil, args);
	} exception {
	"*" =>
		;
	}
	done <-= 0;
}

mtbase: string;
nmt := 0;

# An ftpfs, with a mount point of its own: one that stops answering
# keeps it, and whoever is waiting on it.
Fs: adt {
	mtpt:	string;
	stdout, stderr: ref Out;

	mounted:	fn(fs: self ref Fs): int;
	stop:	fn(fs: self ref Fs);
};

Fs.mounted(fs: self ref Fs): int
{
	(ok, d) := sys->stat(fs.mtpt);
	return ok >= 0 && d.dtype == 'M';
}

# An ftpfs of the server, mounted.
start(t: ref T): ref Fs
{
	if(!csup) {
		(ok, c) := sys->announce("tcp!127.0.0.1!0");
		if(ok < 0)
			t.skip(sys->sprint("announce: %r"));
		ftpport = portof(c);
		spawn ftpserve(c);
		if(sys->bind("#sftpfstest", "/net", Sys->MBEFORE) < 0)
			t.skip(sys->sprint("bind #s /net: %r"));
		fio := sys->file2chan("/net", "cs");
		if(fio == nil)
			t.skip(sys->sprint("file2chan /net/cs: %r"));
		spawn csserve(fio);
		csup = 1;
	}
	fs := ref Fs(sys->sprint("%s.%d", mtbase, nmt++), ref Out(""), ref Out(""));
	mtpt := fs.mtpt;
	stdout := fs.stdout;
	stderr := fs.stderr;
	sys->create(mtpt, Sys->OREAD, Sys->DMDIR | 8r755);
	op := array[2] of ref Sys->FD;
	ep := array[2] of ref Sys->FD;
	if(sys->pipe(op) < 0 || sys->pipe(ep) < 0)
		t.skip("no pipe");
	spawn collect(op[0], stdout);
	spawn collect(ep[0], stderr);
	done := chan[1] of int;
	args := "-q" :: "-m" :: mtpt :: "-a" :: "test@" :: NAME :: nil;
	for(; extraargs != nil; extraargs = tl extraargs)
		args = hd extraargs :: args;
	spawn runftpfs("ftpfs" :: args, op[1], ep[1], done);
	op[1] = nil;
	ep[1] = nil;
	tmo := chan[1] of int;
	spawn timer(tmo, 5000);
	alt {
	r := <-done =>
		if(r < 0)
			t.skip(sys->sprint("cannot load /dis/ftpfs.dis: %r"));
	<-tmo =>
		t.fatal("ftpfs did not start: " + stdout.s + stderr.s);
	}
	for(i := 0; i < 100 && !fs.mounted(); i++)
		sys->sleep(50);
	if(!fs.mounted())
		t.fatal("ftpfs did not mount: " + stdout.s + stderr.s);
	return fs;
}

Fs.stop(fs: self ref Fs)
{
	sys->unmount(nil, fs.mtpt);
	sys->sleep(100);
	sys->remove(fs.mtpt);
}

# ---- tests ----

# the names in a directory, and their Dirs
ls(d: string): list of Sys->Dir
{
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of Sys->Dir;
	for(;;) {
		(n, a) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = a[i] :: l;
	}
	return l;
}

# the names, in order
names(l: list of Sys->Dir): string
{
	a := array[len l] of string;
	n := 0;
	for(; l != nil; l = tl l)
		a[n++] = (hd l).name;
	for(i := 1; i < n; i++)
		for(j := i; j > 0 && a[j-1] > a[j]; j--)
			(a[j-1], a[j]) = (a[j], a[j-1]);
	s := "";
	for(i = 0; i < n; i++)
		s += a[i] + " ";
	return s;
}

lsbg(d: string, c: chan of list of Sys->Dir)
{
	c <-= ls(d);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# ls, given up on after ms: (the entries, whether it answered)
lswithin(d: string, ms: int): (list of Sys->Dir, int)
{
	c := chan[1] of list of Sys->Dir;
	tmo := chan[1] of int;
	spawn lsbg(d, c);
	spawn timer(tmo, ms);
	alt {
	l := <-c =>
		return (l, 1);
	<-tmo =>
		return (nil, 0);
	}
}

# A directory's entries have qids of their own.
testQids(t: ref T)
{
	redirect = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	(l, ok) := lswithin(mtpt, 5000);
	t.assert(ok, "the directory is listed");
	t.assertseq(names(l), "crash3 d f ", "its names");
	seen: list of big;
	for(; l != nil; l = tl l) {
		d := hd l;
		what := sys->sprint("%s: qid (16r%bux, %d, 16r%x)", d.name, d.qid.path, d.qid.vers, d.qid.qtype);
		t.assert(d.qid.path > big 0 && d.qid.path < big 100000, what + ": a path ftpfs gave it");
		for(s := seen; s != nil; s = tl s)
			t.assert(hd s != d.qid.path, what + ": a path no other entry has");
		seen = d.qid.path :: seen;
		if(d.mode & Sys->DMDIR)
			t.asserteq(d.qid.qtype, Sys->QTDIR, what + ": a directory's type");
		else
			t.asserteq(d.qid.qtype, Sys->QTFILE, what + ": a file's type");
		t.asserteq(d.qid.vers, 0, what + ": its version");
	}
	fs.stop();
}

# A PASV reply naming another address: the data connection is made to
# the server all the same.
testPasvAddress(t: ref T)
{
	redirect = 1;
	thirdhit = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	(l, ok) := lswithin(mtpt, 5000);
	t.assert(ok, "the directory is listed");
	t.assertseq(names(l), "crash3 d f ", "the server's own listing");
	t.asserteq(thirdhit, 0, "connections made to the address the reply named");
	fs.stop();
	redirect = 0;
	# let the third parties go
	thirdstop = 1;
	for(; thirds != nil; thirds = tl thirds)
		sys->dial(hd thirds, nil);
}

preadbg(fd: ref Sys->FD, off: big, c: chan of int)
{
	buf := array[16] of byte;
	c <-= sys->pread(fd, buf, len buf, off);
}

# what a pread at off gives, -98 if it has not answered within ms
preadwithin(fd: ref Sys->FD, off: big, ms: int): int
{
	c := chan[1] of int;
	tmo := chan[1] of int;
	spawn preadbg(fd, off, c);
	spawn timer(tmo, ms);
	alt {
	n := <-c =>
		return n;
	<-tmo =>
		return -98;
	}
}

# Offsets past an int are past the file's end, and the server goes on.
testFarOffset(t: ref T)
{
	redirect = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	fd := sys->open(mtpt + "/f", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open f: %r"));
	buf := array[16] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	t.assert(n == 6 && string buf[0:n] == "hello\n", sys->sprint("the file is read (%d bytes)", n));
	t.asserteq(preadwithin(fd, big 16r80000000, 4000), 0, "a read at 2^31");
	t.asserteq(preadwithin(fd, big 16r100000000, 4000), 0, "a read at 2^32");
	t.asserteq(preadwithin(fd, big 16r7fffffff, 4000), 0, "a read at 2^31-1");
	t.asserteq(preadwithin(fd, big 3, 4000), 3, "and one inside the file after them");
	fd = nil;
	(l, ok) := lswithin(mtpt, 4000);
	t.assert(ok && names(l) == "crash3 d f ", "the mount still answers");
	fs.stop();
}

statbg(f: string, c: chan of int)
{
	(ok, nil) := sys->stat(f);
	c <-= ok;
}

# A reply that is its code and nothing more is a reply.
testShortReply(t: ref T)
{
	redirect = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	c := chan[1] of int;
	tmo := chan[1] of int;
	spawn statbg(mtpt + "/crash3/x", c);
	spawn timer(tmo, 4000);
	alt {
	ok := <-c =>
		t.asserteq(ok, -1, "a file that is not there, in a directory whose CWD is answered \"250\"");
	<-tmo =>
		t.error("no answer within 4 s to a stat below a directory whose CWD is answered \"250\"");
	}
	(l, ok) := lswithin(mtpt, 4000);
	t.assert(ok && names(l) == "crash3 d f ", "the mount still answers");
	fs.stop();
}

# A file the server will not store: the close is told, on standard error.
testRefusedStore(t: ref T)
{
	redirect = 0;
	stored = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	fd := sys->create(mtpt + "/new", Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	b := array of byte "some data\n";
	t.asserteq(sys->write(fd, b, len b), len b, "the write (kept until the close)");
	fd = nil;
	sys->sleep(200);
	t.asserteq(stored, len b, "bytes the server was sent");
	t.assert(contains(fs.stderr.s, "could not create"), "standard error says the server refused it: " + fs.stderr.s);
	t.assert(!contains(fs.stdout.s, "could not create"), "and standard output does not: " + fs.stdout.s);
	fs.stop();
}

# A PASV reply whose numbers are not in brackets (RFC 1123 4.1.2.6) is
# one: the split made for that form was dropped, and nothing was listed.
testPasvBare(t: ref T)
{
	redirect = 0;
	pasvbare = 1;
	fs := start(t);
	(l, ok) := lswithin(fs.mtpt, 5000);
	pasvbare = 0;
	t.assert(ok, "the directory is listed");
	t.assertseq(names(l), "crash3 d f ", "through a PASV reply with no brackets");
	fs.stop();
}

openbg(f: string, mode: int, c: chan of int)
{
	fd := sys->open(f, mode);
	c <-= fd != nil;
	fd = nil;
}

# A name is found only if it is there.  In a directory not yet listed
# every name was found, so an open for writing of a file that is not
# there "opened" it and stored an empty file of the name at the close;
# and making a directory was that, the server never asked to make one.
testNames(t: ref T)
{
	redirect = 0;
	cmds = nil;
	madedir = 0;
	fs := start(t);
	mtpt := fs.mtpt;
	c := chan[1] of int;
	tmo := chan[1] of int;
	# in a directory that has not been listed yet
	spawn openbg(mtpt + "/d/nosuch", Sys->OWRITE | Sys->OTRUNC, c);
	spawn timer(tmo, 5000);
	alt {
	ok := <-c =>
		t.asserteq(ok, 0, "an open, for writing, of a file that is not there");
	<-tmo =>
		t.error("no answer to an open within 5 s");
	}
	sys->sleep(200);
	t.assert(!saw("STOR"), "nothing is stored for it");

	fs.stop();
	cmds = nil;
	fs = start(t);
	mtpt = fs.mtpt;
	fd := sys->create(mtpt + "/d/newdir", Sys->OREAD, Sys->DMDIR | 8r755);
	t.assert(fd != nil, sys->sprint("a directory is made: %r"));
	if(fd != nil) {
		(ok, d) := sys->fstat(fd);
		t.assert(ok >= 0 && (d.mode & Sys->DMDIR), "and is a directory when asked");
	}
	fd = nil;
	sys->sleep(200);
	t.assert(saw("MKD newdir"), "the server is asked to make it");
	t.assert(!saw("STOR"), "and no file of its name is stored");
	(l, ok) := lswithin(mtpt + "/d", 5000);
	t.assert(ok && contains(names(l), "newdir "), "it is listed: " + names(l));
	madedir = 0;
	fs.stop();
}

removebg(f: string, c: chan of string)
{
	if(sys->remove(f) < 0)
		c <-= sys->sprint("%r");
	else
		c <-= "removed";
}

# A remove the server refuses is told in the server's words, and leaves
# the mount usable: the fid stayed busy (a remove clunks it either way),
# so the next walk that used its number was "fid in use".
testRefusedRemove(t: ref T)
{
	redirect = 0;
	cmds = nil;
	fs := start(t);
	mtpt := fs.mtpt;
	c := chan[1] of string;
	tmo := chan[1] of int;
	spawn removebg(mtpt + "/f", c);
	spawn timer(tmo, 5000);
	alt {
	e := <-c =>
		t.assert(contains(e, "against policy"), "a refused remove says what the server said: " + e);
	<-tmo =>
		t.error("no answer to a remove within 5 s");
	}
	t.assert(saw("DELE f"), "the server was asked");
	bad := 0;
	for(i := 0; i < 6; i++) {
		(ok, nil) := sys->stat(mtpt + "/f");
		if(ok < 0)
			bad++;
	}
	t.asserteq(bad, 0, "stats of the file that fail after the refused remove");
	fs.stop();
}

# A listing that fails once does not change how every later one is
# asked for: after any failed "LIST -la" the server was taken for one
# that has no long listing, for good.
testListAgain(t: ref T)
{
	redirect = 0;
	lists = nil;
	faillists = 2;	# the long listing, and the plain one tried after it
	fs := start(t);
	(nil, ok) := lswithin(fs.mtpt, 5000);
	t.asserteq(faillists, 0, "the first listing was refused both ways");
	(l, ok2) := lswithin(fs.mtpt, 5000);
	t.assert(ok2 && names(l) == "crash3 d f ", "the directory is listed when asked again: " + names(l));
	t.assert(lists != nil && hd lists == "-la", "and is asked for as a long listing still");
	ok = ok;
	fs.stop();
}

# A server that stops answering does not keep the mount for ever: its
# connections are hung up after -t seconds with nothing from it, and
# the request is answered with an error.
testStall(t: ref T)
{
	redirect = 0;
	extraargs = "2" :: "-t" :: nil;
	fs := start(t);
	mtpt := fs.mtpt;
	(l, lok) := lswithin(mtpt, 5000);
	t.assert(lok && names(l) == "crash3 d f ", "the mount answers");
	c := chan[1] of int;
	tmo := chan[1] of int;
	stalling = 1;
	spawn statbg(mtpt + "/d/x", c);
	spawn timer(tmo, 12000);
	alt {
	ok := <-c =>
		t.asserteq(ok, -1, "a request the server never answers ends in an error");
	<-tmo =>
		t.error("a request the server never answers was still waiting after 12 s");
	}
	stalling = 0;
	t.assert(contains(fs.stderr.s, "hanging up"), "and standard error says the server was given up on: " + fs.stderr.s);
	fs.stop();
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	# the connection server and the mount are this test's alone
	sys->pctl(Sys->FORKNS, nil);
	mtbase = sys->sprint("/tmp/ftpfs_test.%d", sys->pctl(0, nil));

	run("Qids", testQids);
	run("PasvAddress", testPasvAddress);
	run("FarOffset", testFarOffset);
	run("RefusedStore", testRefusedStore);
	run("ShortReply", testShortReply);
	run("PasvBare", testPasvBare);
	run("Names", testNames);
	run("RefusedRemove", testRefusedRemove);
	run("ListAgain", testListAgain);
	run("Stall", testStall);

	# let the server's listener go
	stopping = 1;
	if(ftpport != nil)
		sys->dial("tcp!127.0.0.1!" + ftpport, nil);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
