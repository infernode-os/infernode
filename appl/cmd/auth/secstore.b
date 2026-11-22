implement Secstorec;

#
# interact with the Plan 9 secstore
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";
	dial: Dial;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "secstore.m";
	secstore: Secstore;

include "arg.m";

Secstorec: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

Maxfilesize: con 128*1024;

stderr: ref Sys->FD;
conn: ref Dial->Connection;
seckey: array of byte;
seckey2: array of byte;
pin: string;	# a second factor's, when one is given or asked for: erase() clears it
seckey4: array of byte;
rootkey: array of byte;	# files as logon and factotum write them (SGCM2)
filekey2: array of byte;	# the two older formats, read only
filekey: array of byte;
file: array of byte;
verbose := 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	secstore = load Secstore Secstore->PATH;
	dial = load Dial Dial->PATH;

	sys->pctl(Sys->FORKFD, nil);
	stderr = sys->fildes(2);
	secstore->init();
	secstore->privacy();

	addr := "net!$auth!secstore";
	user := readfile("/dev/user");
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("auth/secstore [-iv] [-k key] [-p pin] [-s net!server!secstore] [-u user] [{dmrptx} file ...]");
	iflag := 0;
	pass: string;
	while((o := arg->opt()) != 0)
		case o {
		'i' => iflag = 1;
		'k' =>
			pass = arg->earg();
			iflag = 2;	# given, not asked for: as -i, with nothing to read
			# an argument is read by whoever lists the processes
			sys->fprint(stderr, "secstore: warning: a password given with -k can be read by other programs (in /prog); use -i\n");
		'v' => verbose = 1;
		's' =>	addr = arg->earg();
		'u' => user = arg->earg();
		'p' => pin = arg->earg();
		* =>
			arg->usage();
		}
	args = arg->argv();
	op := -1;
	if(args != nil){
		if(len hd args != 1)
			arg->usage();
		op = (hd args)[0];
		args = tl args;
		case op {
		'd' or 'r' or 'p' or 'x' or 'm' =>
			if(args == nil)
				arg->usage();
		't' =>
			;
		* =>
			arg->usage();
		}
	}
	arg = nil;

	# (-k's password was asked for again at the console all the same)
	if(iflag == 1){
		buf := array[Secstore->Maxmsg] of byte;
		stdin := sys->fildes(0);
		for(nr := 0; nr < len buf && (n := sys->read(stdin, buf, len buf-nr)) > 0;)
			nr += n;
		s := string buf[0:nr];
		secstore->erasekey(buf[0:nr]);
		(nf, flds) := sys->tokenize(s, "\n");
		for(i := 0; i < len s; i++)
			s[i] = 0;
		if(nf < 1)
			error("no password on standard input");
		pass = hd flds;
		if(nf > 1)
			pin = hd tl flds;
		# the list's are the same strings: with it gone the ones
		# cleared below are the only ones (clearing a string that
		# something else still names clears a copy)
		flds = nil;
	}
	# The connection is the module's (conn, above), used after this loop.
	# A second conn was declared here and a third by the := in the loop:
	# the one the operations used was never set, and every operation
	# ended "dereference of nil" once the password had been proved.
	srvname, diag: string;
Auth:
	for(;;){
		if(!iflag)
			pass = readpassword("secstore password");
		if(pass == nil)
			exit;
		erase();
		seckey = secstore->mkseckey(pass);
		seckey2 = secstore->mkseckey2(pass);
		rootkey = secstore->mkfilekey3(user, pass);
		seckey4 = secstore->mkseckey4(rootkey);
		# the two formats no longer written have keys only for m,
		# which moves a file out of them
		if(op == 'm'){
			filekey2 = secstore->mkfilekey2(pass);
			filekey = secstore->mkfilekey(pass);
		}
		for(i := 0; i < len pass; i++)
			pass[i] = 0;	# clear it
		{
			(conn, srvname, diag) = secstore->connect4(dial->netmkaddr(addr, "net", "secstore"), user, seckey, seckey2, seckey4);
		}exception e{
		"*" =>
			# nothing the server sends should raise; if it does, say so
			conn = nil;
			srvname = nil;
			diag = "exception: " + e;
		}
		if(srvname == nil){
			sys->fprint(stderr, "secstore: authentication failed: %s\n",  diag);
			if(iflag){
				erase();
				raise "fail:auth";
			}
			continue;
		}
		case diag {
		"" =>
			break Auth;
		"need pin" =>
			if(!iflag){
				pin = readpassword("STA PIN+SecureID");
				if(len pin == 0){
					sys->fprint(stderr, "cancelled");
					erase();
					exit;
				}
			}else if(pin == nil){
				erase();
				raise "fail:no pin";
			}
			r := secstore->sendpin(conn, pin);
			for(i = 0; i < len pin; i++)
				pin[i] = 0;
			if(r < 0){
				sys->fprint(stderr, "secstore: pin rejected: %r\n");
				if(iflag){
					erase();
					raise "fail:bad pin";
				}
				continue;
			}
			# the pin was taken: authenticated.  (Nothing left the
			# loop here, so the password was asked for again.)
			break Auth;
		* =>
			sys->fprint(stderr, "secstore: authentication failed: %s\n",  diag);
			erase();
			raise "fail:auth";
		}
	}
	if(verbose)
		sys->fprint(stderr, "server: %s\n", clean(srvname));
	secstore->erasekey(seckey);
	secstore->erasekey(seckey2);
	secstore->erasekey(seckey4);
	seckey = nil;
	seckey2 = nil;
	seckey4 = nil;
	{
		operate(op, args);
	}exception e{
	"fail:*" =>
		erase();
		secstore->bye(conn);
		raise e;
	"*" =>
		erase();
		sys->fprint(stderr, "secstore: %s\n", e);
		raise "fail:error";
	}
	erase();
	secstore->bye(conn);
}

operate(op: int, args: list of string)
{
	if(op == 't'){
		erase();	# no longer need the keys
		(entries, lerr) := secstore->files(conn);
		if(lerr != nil)
			error("can't list files: " + lerr);
		for(; entries != nil; entries = tl entries){
			(name, size, date, hash, nil) := hd entries;
			# only the files named, if any are (the loop compared each
			# with the first name and then asked whether the list was
			# empty: nothing was ever left out)
			if(args != nil){
				for(l := args; l != nil; l = tl l)
					if(hd l == name)
						break;
				if(l == nil)
					continue;
			}
			# the names and dates are the server's
			if(verbose)
				sys->print("%-14q %10d %s %s\n", clean(name), size, clean(date), clean(hash));
			else
				sys->print("%q\n", clean(name));
		}
		return;
	}
	for(; args != nil; args = tl args){
		fname := hd args;
		case op {
		'd' =>
			checkname(fname, 1);
			if(secstore->remove(conn, fname) < 0)
				error(sys->sprint("can't remove %q: %r", fname));
			# the server does not answer a remove: ask it
			(nil, absent, rerr) := secstore->fetch(conn, fname, 0);
			if(rerr != nil)
				error(sys->sprint("can't tell whether %q was removed: %s", fname, rerr));
			if(!absent)
				error(sys->sprint("%q was not removed by the server", fname));
			verb('d', fname);
		'p' =>
			checkname(fname, 1);
			file = getfile(fname);
			lines := secstore->lines(file);
			lno := 1;
			for(; lines != nil; lines = tl lines){
				l := hd lines;
				if(sys->write(sys->fildes(1), l, len l) != len l)
					sys->fprint(sys->fildes(2), "secstore (%s:%d): %r\n", fname, lno);
				lno++;
			}
			secstore->erasekey(file);
			file = nil;
			verb('p', fname);
		'x' =>
			checkname(fname, 1);
			file = getfile(fname);
			# A new file, mode 600, and never one that is already
			# there: the decrypted secret was written into whatever
			# file of that name the directory held, with its mode
			# and its owner.
			sys->remove(fname);
			ofd := sys->create(fname, Sys->OWRITE|Sys->OEXCL, 8r600);
			if(ofd == nil)
				error(sys->sprint("can't create %q: %r", fname));
			if(sys->write(ofd, file, len file) != len file)
				error(sys->sprint("error writing to %q: %r", fname));
			secstore->erasekey(file);
			file = nil;
			verb('x', fname);
		'r' =>
			# on the server, the last component of the local name
			sname := checkname(fname, 0);
			fd := sys->open(fname, sys->OREAD);
			if(fd == nil)
				error(sys->sprint("open %q: %r", fname));
			(ok, dir) := sys->fstat(fd);
			if(ok != 0)
				error(sys->sprint("stat %q: %r", fname));
			if(dir.length > big Maxfilesize)
				error(sys->sprint("length %bd > Maxfilesize %d", dir.length, Maxfilesize));
			file = array[int dir.length] of byte;
			if(sys->readn(fd, file, len file) != len file)
				error(sys->sprint("short read: %r"));
			sent := secstore->encrypt3(file, rootkey);
			if(sent == nil || secstore->putfile(conn, sname, sent) < 0)
				error(sys->sprint("can't store %q: %r", sname));
			# the server does not answer a store: read it back
			(back, nil, berr) := secstore->fetch(conn, sname, 0);
			if(berr != nil)
				error(sys->sprint("can't tell whether %q was stored: %s", sname, berr));
			if(!same(back, sent))
				error(sys->sprint("%q was not stored by the server", sname));
			secstore->erasekey(file);
			file = nil;
			verb('r', sname);
		'm' =>
			# Move a file of an older format (SGCM1, or Plan 9's
			# AES-CBC under a SHA-1 of the password) to the one
			# written now.  Nothing else reads the older formats.
			checkname(fname, 1);
			(old, absent, merr) := secstore->fetch(conn, fname, 0);
			if(absent)
				error(sys->sprint("can't fetch %q: the server has no such file", fname));
			if(merr != nil)
				error(sys->sprint("can't fetch %q: %s", fname, merr));
			if(secstore->iscurrent(old)){
				if(secstore->decrypt3(old, rootkey, nil, nil) == nil)
					error(sys->sprint("%q is in the current format and does not decrypt with this password", fname));
				sys->fprint(stderr, "secstore: %q is already in the current format\n", fname);
				break;
			}
			file = secstore->decrypt3(old, rootkey, filekey2, filekey);
			if(file == nil)
				error(sys->sprint("can't decrypt %q: %r", fname));
			sent := secstore->encrypt3(file, rootkey);
			secstore->erasekey(file);
			file = nil;
			if(sent == nil || secstore->putfile(conn, fname, sent) < 0)
				error(sys->sprint("can't store %q: %r", fname));
			(back, nil, berr) := secstore->fetch(conn, fname, 0);
			if(berr != nil)
				error(sys->sprint("can't tell whether %q was stored: %s", fname, berr));
			if(!same(back, sent))
				error(sys->sprint("%q was not stored by the server", fname));
			verb('m', fname);
		* =>
			error(sys->sprint("op %c not implemented", op));
		}
	}
}

same(a, b: array of byte): int
{
	if(a == nil || len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# the server's text, for the terminal: no control characters
clean(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] == 16r7f)
			s[i] = '?';
	return s;
}

checkname(s: string, noslash: int): string
{
	tail := s;
	for(i := 0; i < len s; i++){
		if(s[i] == '/'){
			if(noslash)
				break;
			tail = s[i+1:];
		}
		if(s[i] == '\n' || s[i] <= ' ')
			break;
	}
	# (PAK is where a server keeps the account's verifier, beside its files)
	if(s == nil || tail == nil || i < len s || tail == ".." || tail == "." || tail == "PAK")
		error(sys->sprint("can't use %q as a secstore file name", s));	# server checks as well, of course
	return tail;
}

verb(op: int, n: string)
{
	if(verbose)
		sys->fprint(stderr, "%c %q\n", op, n);
}

#
# A file, decrypted: as logon and factotum write it (AES-256-GCM under a
# key made from the user and the password), or in either older format.
# Only the oldest was read, so the file this command exists to print,
# factotum, could not be.
#
getfile(fname: string): array of byte
{
	(f, absent, err) := secstore->fetch(conn, fname, 0);
	if(absent)
		error(sys->sprint("can't fetch %q: the server has no such file", fname));
	if(err != nil)
		error(sys->sprint("can't fetch %q: %s", fname, err));
	if(len f == 0)
		error(sys->sprint("%q is empty on the server: not an encrypted file", fname));
	enc := f;
	f = secstore->decrypt3(enc, rootkey, nil, nil);
	if(f == nil){
		if(!secstore->iscurrent(enc))
			error(sys->sprint("%q is in an old format: move it with auth/secstore m %s", fname, fname));
		error(sys->sprint("can't decrypt %q: %r", fname));
	}
	return f;
}

erase()
{
	if(secstore != nil){
		secstore->erasekey(seckey);
		secstore->erasekey(seckey2);
		secstore->erasekey(seckey4);
		secstore->erasekey(rootkey);
		secstore->erasekey(filekey2);
		secstore->erasekey(filekey);
		secstore->erasekey(file);
	}
	for(i := 0; i < len pin; i++)
		pin[i] = 0;
}

error(s: string)
{
	erase();
	sys->fprint(stderr, "secstore: %s\n", s);
	raise "fail:error";
}

readpassword(prompt: string): string
{
	cons := sys->open("/dev/cons", Sys->ORDWR);
	if(cons == nil)
		return nil;
	stdin := bufio->fopen(cons, Sys->OREAD);
	if(stdin == nil)
		return nil;
	cfd := sys->open("/dev/consctl", Sys->OWRITE);
	if (cfd == nil || sys->fprint(cfd, "rawon") <= 0)
		sys->fprint(stderr, "secstore: warning: cannot hide typed password\n");
L:
	for(;;){
		sys->fprint(cons, "%s: ", prompt);
		s := "";
		while ((c := stdin.getc()) >= 0){
			case c {
			'\n' or ('d'&8r037) =>
				sys->fprint(cons, "\n");
				return s;
			'\b' or 8r177 =>
				if(len s > 0)
					s = s[0:len s - 1];
			'u' & 8r037 =>
				sys->fprint(cons, "\n");
				continue L;
			* =>
				s[len s] = c;
			}
		}
		break;
	}
	return nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return "";
	return string buf[0:n]; 
}
