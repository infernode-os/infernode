implement Countersigner;

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "keyring.m";
	kr: Keyring;

include "msgio.m";
	msgio: Msgio;

include "security.m";
	login: Login;

Countersigner: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr, stdin, stdout: ref Sys->FD;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	msgio = load Msgio Msgio->PATH;
	login = load Login Login->PATH;
	if(msgio == nil || login == nil){
		sys->fprint(stderr, "countersigner: can't load %s or %s: %r\n", Msgio->PATH, Login->PATH);
		raise "fail:load";
	}
	msgio->init();

	# The records an operator has approved (verify(8) puts them in
	# /keydb/countersigned) are all of /keydb in this name space from
	# here on, so no boxid names anything else whatever the check below
	# lets by: ../signed/alice gave anybody the pad of a request nobody
	# had approved, which unblinds the certificate signer(8) sent for it.
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("/keydb/countersigned", "/keydb", Sys->MREPL) < 0 || sys->chdir("/keydb") < 0){
		sys->fprint(stderr, "countersigner: no key database\n");
		raise "fail:no keydb";
	}

	# get boxid
	buf := msgio->getmsg(stdin);
	if(buf == nil){
		sys->fprint(stderr, "countersigner: client hung up\n");
		raise "fail:hungup";
	}
	boxid := string buf;

	# A refusal is said to the client (an error message of the
	# protocol's, which its getmsg gives as the error): each was a
	# connection that closed, and a client could not tell a request not
	# yet approved from a network fault.  A name that is none and a
	# name not approved are told apart; nothing else is said of why.

	# the boxid is one name (login(6)), as the owner signer(8) took was
	e := login->okname(boxid);
	if(e != nil){
		sys->fprint(stderr, "countersigner: bad boxid: %s\n", e);
		msgio->senderrmsg(stdout, "bad id: " + e);
		raise "fail:bad boxid";
	}

	# read file
	file := boxid;
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "countersigner: can't open countersigned/%s: %r\n", file);
		msgio->senderrmsg(stdout, "no approved request for that id");
		raise "fail:bad boxid";
	}
	blind := msgio->getmsg(fd);
	if(blind == nil){
		sys->fprint(stderr, "countersigner: can't read countersigned/%s\n", file);
		msgio->senderrmsg(stdout, "countersigning service unavailable");
		raise "fail:no blind";
	}

	# answer client
	msgio->sendmsg(stdout, blind, len blind);
}
