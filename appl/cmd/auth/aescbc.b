implement Aescbc;

#
# broadly transliterated from the Plan 9 command
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "keyring.m";
	kr: Keyring;
	AESbsize, MD5dlen, SHA1dlen: import Keyring;

include "arg.m";

Aescbc: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

#
# encrypted file: v2hdr, 16 byte IV, AES-CBC(key, random || file), HMAC_SHA1(md5(key), AES-CBC(random || file))
#
# Before that format there was one with no header and no MAC: a 16 byte
# IV, then AES-CBC(key, file || sixteen X's), under the same key. It was
# taken whenever the input did not begin with the header. Since CBC lets
# whoever knows one block of the plaintext choose what a block decrypts
# to, a file in the new format and sixteen known bytes of its contents
# were enough to make, with no key, a header-less file of chosen blocks
# that was accepted with success: the MAC of the new format protected
# nothing against someone able to replace the file. The old format is now
# read only when asked for (-c), and is said not to be authenticated.
#
# Nothing is written until the whole input has been checked: the
# decrypted bytes were written as they came and the MAC compared at the
# end, so a changed or cut file gave its output and then an error. A file
# is read twice, checked and then decrypted (and checked again, against
# one that changes meanwhile); input that is not a file, a pipe say, is
# held in memory until it has been checked, up to Maxheld bytes.
#

Checkpat: con "XXXXXXXXXXXXXXXX";
Checklen: con len Checkpat;
Bufsize: con 4096;
AESmaxkey: con 32;
Maxheld: con 64*1024*1024;	# of input that cannot be read twice

V2hdr: con "AES CBC SHA1  2\n";

bin: ref Iobuf;
bout: ref Iobuf;
stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	bufio = load Bufio Bufio->PATH;

	sys->pctl(Sys->FORKFD, nil);
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("auth/aescbc -d [-c] [-k key] [-f keyfile] <file.aes >clear.txt\n  or: auth/aescbc -e [-k key] [-f keyfile] <clear.txt >file.aes");
	encrypt := -1;
	compat := 0;
	keyfile: string;
	pass: string;
	while((o := arg->opt()) != 0)
		case o {
		'd' or 'e' =>
			if(encrypt >= 0)
				arg->usage();
			encrypt = o == 'e';
		'c' =>
			compat = 1;
		'f' =>
			keyfile = arg->earg();
		'k' =>
			pass = arg->earg();
		* =>
			arg->usage();
		}
	args = arg->argv();
	if(args != nil || encrypt < 0 || encrypt && compat)
		arg->usage();
	arg = nil;

	bin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	bout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);

	buf := array[Bufsize+SHA1dlen] of byte;	# Checklen <= SHA1dlen

	pwd: array of byte;
	if(keyfile != nil){
		fd := sys->open(keyfile, Sys->OREAD);
		if(fd == nil)
			error(sys->sprint("can't open %q: %r", keyfile), "keyfile");
		n := sys->readn(fd, buf, len buf);
		while(n > 0 && buf[n-1] == byte '\n')
			n--;
		if(n <= 0)
			error("no key", "no key");
		pwd = buf[0:n];
	}else{
		if(pass == nil)
			pass = readpassword("password");
		if(pass == nil)
			error("no key", "no key");
		pwd = array of byte pass;
		for(i := 0;  i < len pass; i++)
			pass[i] = 0;
	}
	key := array[AESmaxkey] of byte;
	key2 := array[SHA1dlen] of byte;
	dstate := kr->sha1(array of byte "aescbc file", 11, nil, nil);
	kr->sha1(pwd, len pwd, key2, dstate);
	for(i := 0; i < len pwd; i++)
		pwd[i] = byte 0;
	key[0:] = key2[0:MD5dlen];
	nkey := MD5dlen;
	kr->md5(key, nkey, key2, nil);	# protect key even if HMAC_SHA1 is broken
	key2 = key2[0:MD5dlen];

	if(encrypt){
		Write(array of byte V2hdr, AESbsize);
		genrandom(buf, 2*AESbsize); # CBC is semantically secure if IV is unpredictable.
		aes := kr->aessetup(key[0:nkey], buf);  # use first AESbsize bytes as IV
		kr->aescbc(aes, buf[AESbsize:], AESbsize, Keyring->Encrypt);  # use second AESbsize bytes as initial plaintext
		Write(buf, 2*AESbsize);
		dstate = kr->hmac_sha1(buf[AESbsize:], AESbsize, key2, nil, nil);
		while((n := bin.read(buf, Bufsize)) > 0){
			kr->aescbc(aes, buf, n, Keyring->Encrypt);
			Write(buf, n);
			dstate = kr->hmac_sha1(buf, n, key2, nil, dstate);
			if(n < Bufsize)
				break;
		}
		if(n < 0)
			error(sys->sprint("read error: %r"), "read error");
		kr->hmac_sha1(nil, 0, key2, buf, dstate);
		Write(buf, SHA1dlen);
	}else{	# decrypt
		in := Input.new(sys->fildes(0));
		(err, why) := decrypt(in, key, nkey, key2, compat, 0);
		if(err == nil){
			in.rewind();
			(err, why) = decrypt(in, key, nkey, key2, compat, 1);
			if(err != nil)
				err = "the input changed as it was decrypted: " + err;
		}
		if(err != nil)
			error(err, why);
	}
	if(bout.flush() == Bufio->ERROR){
		sys->fprint(stderr, "aescbc: write error: %r\n");
		raise "fail:write error";
	}
}

#
# The input, read once to be checked and again to be decrypted: a file
# by going back to where it began, anything else from memory.
#
Input: adt {
	fd:	ref Sys->FD;
	b:	ref Iobuf;
	start:	big;	# where a file's input began; -1 if it cannot be read twice
	keep:	int;	# what is read is being kept
	kept:	list of array of byte;	# newest first, while keeping; then oldest first
	nkept:	int;
	cur:	array of byte;	# rest of the piece being read from memory

	new:	fn(fd: ref Sys->FD): ref Input;
	read:	fn(in: self ref Input, buf: array of byte, n: int): int;
	rewind:	fn(in: self ref Input);
};

Input.new(fd: ref Sys->FD): ref Input
{
	in := ref Input(fd, bin, big -1, 0, nil, 0, nil);
	# a file on a file server: of some length, and seek goes back in it.
	# A pipe refuses the seek; a connection or a device takes it and
	# gives other bytes the second time.
	(ok, d) := sys->fstat(fd);
	if(ok >= 0 && (d.qid.qtype & Sys->QTDIR) == 0 && d.length > big 0 && (d.dtype == 'U' || d.dtype == 'M'))
		in.start = sys->seek(fd, big 0, Sys->SEEKRELA);
	if(in.start < big 0)
		in.keep = 1;
	return in;
}

# as Iobuf.read: n bytes unless the input ends first; -1 on error
Input.read(in: self ref Input, buf: array of byte, n: int): int
{
	if(in.b != nil){
		r := in.b.read(buf, n);
		if(r > 0 && in.keep){
			in.nkept += r;
			if(in.nkept > Maxheld)
				error(sys->sprint("the input is not a file and is longer than %d bytes: decrypt it from a file", Maxheld), "too long");
			a := array[r] of byte;
			a[0:] = buf[0:r];
			in.kept = a :: in.kept;
		}
		return r;
	}
	o := 0;
	while(o < n){
		if(len in.cur == 0){
			if(in.kept == nil)
				break;
			in.cur = hd in.kept;
			in.kept = tl in.kept;
			continue;
		}
		m := len in.cur;
		if(m > n-o)
			m = n-o;
		buf[o:] = in.cur[0:m];
		in.cur = in.cur[m:];
		o += m;
	}
	return o;
}

Input.rewind(in: self ref Input)
{
	if(in.keep){
		l: list of array of byte;
		for(; in.kept != nil; in.kept = tl in.kept)
			l = hd in.kept :: l;
		in.kept = l;
		in.keep = 0;
		in.b = nil;
		in.cur = nil;
		return;
	}
	if(sys->seek(in.fd, in.start, Sys->SEEKSTART) != in.start)
		error(sys->sprint("can't read the input a second time: %r"), "read error");
	in.b = bufio->fopen(in.fd, Bufio->OREAD);
}

short(n: int): (string, string)
{
	if(n < 0)
		return (sys->sprint("read error: %r"), "read error");
	return ("unexpectedly short read", "read error");
}

#
# One reading of the input: checked, and written out only if out is set.
# The error and the exit status's word, or nil.
#
decrypt(in: ref Input, key: array of byte, nkey: int, key2: array of byte, compat: int, out: int): (string, string)
{
	buf := array[Bufsize+SHA1dlen] of byte;	# Checklen <= SHA1dlen
	n: int;
	if((n = in.read(buf, AESbsize)) != AESbsize)
		return short(n);
	if(string buf[0:AESbsize] == V2hdr){
		# IV and random initial plaintext
		if((n = in.read(buf, 2*AESbsize)) != 2*AESbsize)
			return short(n);
		aes := kr->aessetup(key[0:nkey], buf);
		dstate := kr->hmac_sha1(buf[AESbsize:], AESbsize, key2, nil, nil);
		kr->aescbc(aes, buf[AESbsize:], AESbsize, Keyring->Decrypt);
		if((n = in.read(buf, SHA1dlen)) != SHA1dlen)
			return short(n);
		while((n = in.read(buf[SHA1dlen:], Bufsize)) > 0){
			dstate = kr->hmac_sha1(buf, n, key2, nil, dstate);
			kr->aescbc(aes, buf, n, Keyring->Decrypt);
			if(out)
				Write(buf, n);
			buf[0:] = buf[n:n+SHA1dlen];	# these bytes are not yet decrypted
		}
		# a read that failed was "failed to authenticate"
		if(n < 0)
			return (sys->sprint("read error: %r"), "read error");
		kr->hmac_sha1(nil, 0, key2, buf[SHA1dlen:], dstate);
		if(!eqbytes(buf, buf[SHA1dlen:], SHA1dlen))
			return ("decrypted file failed to authenticate", "failed to authenticate");
		return (nil, nil);
	}
	if(!compat)
		return ("the input has not aescbc's header; -c reads the old format with none, which is not authenticated", "bad header");
	# compatibility with past mistake; assume we're decrypting secstore files
	aes := kr->aessetup(key[0:AESbsize], buf);
	if((n = in.read(buf, Checklen)) != Checklen)
		return short(n);
	kr->aescbc(aes, buf, Checklen, Keyring->Decrypt);
	while((n = in.read(buf[Checklen:], Bufsize)) > 0){
		kr->aescbc(aes, buf[Checklen:], n, Keyring->Decrypt);
		if(out)
			Write(buf, n);
		buf[0:] = buf[n:n+Checklen];
	}
	if(n < 0)
		return (sys->sprint("read error: %r"), "read error");
	if(!eqbytes(buf, array of byte Checkpat, Checklen))
		return ("decrypted file failed to authenticate", "failed to authenticate");
	return (nil, nil);
}

error(s: string, why: string)
{
	bout.flush();
	sys->fprint(stderr, "aescbc: %s\n", s);
	raise "fail:"+why;
}

# equal, in time that does not depend on where they differ
eqbytes(a: array of byte, b: array of byte, n: int): int
{
	if(len a < n || len b < n)
		return 0;
	d := 0;
	for(i := 0; i < n; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

Write(buf: array of byte, n: int)
{
	if(bout.write(buf,  n) != n){
		sys->fprint(sys->fildes(2), "aescbc: write error: %r\n");
		raise "fail:write error";
	}
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
		sys->fprint(stderr, "aescbc: warning: cannot hide typed password\n");
	s: string;
L:
	for(;;){
		sys->fprint(cons, "%s: ", prompt);
		s = "";
		while ((c := stdin.getc()) >= 0){
			case c {
			'\n' =>
				break L;
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
	}
	sys->fprint(cons, "\n");
	return s;
}

genrandom(b: array of byte, n: int)
{
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "aescbc: can't open /dev/notquiterandom: %r\n");
		raise "fail:random";
	}
	if(sys->read(fd, b, n) != n){
		sys->fprint(stderr, "aescbc: can't read random numbers: %r\n");
		raise "fail:read random";
	}
}
