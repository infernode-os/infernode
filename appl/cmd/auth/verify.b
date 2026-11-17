implement Verify;

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;

include "draw.m";

include "security.m";
	login: Login;

Verify: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr, stdin: ref Sys->FD;

pro := array[] of {
	"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
	"hotel", "india", "juliet", "kilo", "lima", "mike", "nancy", "oscar",
	"papa", "quebec", "romeo", "sierra", "tango", "uniform",
	"victor", "whisky", "xray", "yankee", "zulu"
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;

	stdin = sys->fildes(0);
	stderr = sys->fildes(2);

	if(args != nil)
		args = tl args;
	if(args == nil){
		sys->fprint(stderr, "usage: verify boxid\n");
		raise "fail:usage";
	}

	sys->pctl(Sys->FORKNS, nil);
	if(sys->chdir("/keydb") < 0){
		sys->fprint(stderr, "signer: no key database\n");
		raise "fail:no keydb";
	}

	# the id is one name, as signer(8) took it: it names a file here
	boxid := hd args;
	login = load Login Login->PATH;
	if(login == nil){
		sys->fprint(stderr, "verify: can't load %s: %r\n", Login->PATH);
		raise "fail:load";
	}
	if((e := login->okname(boxid)) != nil){
		sys->fprint(stderr, "verify: bad id: %s\n", e);
		raise "fail:bad id";
	}
	file := "signed/"+boxid;
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "signer: can't open %s: %r\n", file);
		raise "fail:no certificate";
	}
	certbuf := kr->getmsg(fd);
	digest := kr->getmsg(fd);
	if(digest == nil || certbuf == nil){
		sys->fprint(stderr, "signer: can't read %s: %r\n", file);
		raise "fail:bad certificate";
	}

	s: string;
	# sixteen bytes of it are read out, two words a byte: 128 bits of
	# a SHA-256 (the record once held an MD5, which was all of it)
	for(i := 0; i < len digest && i < 16; i++){
		s = s + (string (2*i)) + ": " + pro[((int digest[i])>>4)%len pro] + "\t";
		s = s + (string (2*i+1)) + ": " + pro[(int digest[i])%len pro] + "\n";
	}

	sys->print("%s\naccept (y or n)? ", s);
	buf := array[5] of byte;
	n := sys->read(stdin, buf, len buf);
	# A request answered is gone from signed/, either way: one that
	# was rejected stayed, and while it stayed signer(8) took no other
	# for that name.
	if(n < 1 || buf[0] != byte 'y'){
		fd = nil;
		sys->remove(file);
		sys->print("\nrejected\n");
		raise "fail:rejected";
	}
	sys->print("\naccepted\n");

	nfile := "countersigned/"+boxid;
	fd = sys->create(nfile, Sys->OWRITE, 8r600);
	if(fd == nil){
		sys->fprint(stderr, "signer: can't create %s: %r\n", nfile);
		raise "fail:create";
	}
	if(kr->sendmsg(fd, certbuf, len certbuf) < 0){
		sys->fprint(stderr, "signer: can't write %s: %r\n", nfile);
		sys->remove(nfile);
		raise "fail:write";
	}
	sys->remove(file);
}
