implement Mkauditkey;

#
# mkauditkey - generate the audit checkpoint-signing key, in memory.
#
# Generates an ML-DSA-87 (CNSA 2.0 Category 5) signer key, writes its
# PUBLIC key to the given file (default /usr/inferno/audit/pub; not a
# secret), and prints a single-line factotum key bearing the PRIVATE key
# to standard output:
#
#   key proto=sign service=audit !sk=<enc(sktostr(SK))>
#
# enc maps sktostr's newlines to '@' and base64 padding '=' to '~', so the
# value is single-line and '='-free (factotum's parseline mis-handles '='
# inside a value, and the key line must fit one 8192-byte write); the sign
# proto reverses it. The private key is never written to disk: it exists
# only in memory and is emitted to stdout, which the provisioning script
# pipes straight into /mnt/factotum/ctl, where factotum seals it into
# secstore. auditfs then asks factotum to sign checkpoints; it never sees
# the private key (AU-10).
#
#   usage: mkauditkey [-a algorithm] [pubkeyfile]
#
# See doc/compliance/audit-log-factotum-signing-DESIGN.md.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
	kr: Keyring;

Mkauditkey: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		fail(sys->sprint("cannot load keyring: %r"));
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail("cannot load arg");

	alg := "mldsa87";
	pubfile := "/usr/inferno/audit/pub";
	arg->init(argv);
	arg->setusage("mkauditkey [-a algorithm] [pubkeyfile]");
	while((c := arg->opt()) != 0){
		case c {
		'a' =>	alg = arg->earg();
		* =>	arg->usage();
		}
	}
	argv = arg->argv();
	if(argv != nil)
		pubfile = hd argv;

	sk := kr->genSK(alg, "audit", 0);
	if(sk == nil)
		fail(sys->sprint("cannot generate %s key (algorithm configured?)", alg));
	pk := kr->sktopk(sk);

	# Publish the public key (not a secret).
	fd := sys->create(pubfile, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail(sys->sprint("cannot write %s: %r", pubfile));
	pkb := array of byte (kr->pktostr(pk) + "\n");
	if(sys->write(fd, pkb, len pkb) != len pkb)
		fail(sys->sprint("cannot write %s: %r", pubfile));

	# Emit the private key as a single-line factotum key on stdout.
	# Use one write (not sys->print, whose fixed format buffer would
	# split a ~6.6KB line and make factotum reject it as multiline).
	line := array of byte ("key proto=sign service=audit !sk="
		+ encode(kr->sktostr(sk)) + "\n");
	if(sys->write(sys->fildes(1), line, len line) != len line)
		fail(sys->sprint("cannot write key line: %r"));
}

# encode maps sktostr's newlines to '@' and base64 padding '=' to '~' so
# the value is single-line and '='-free; the sign proto reverses it.
encode(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\n' =>	c = '@';
		'=' =>	c = '~';
		}
		r[len r] = c;
	}
	return r;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "mkauditkey: %s\n", s);
	raise "fail:error";
}
