implement X509Chain;

#
# Drive x509's verification entry points on DER files, for
# tests/host/x509_chain_test.sh: one case a line of the file named,
#
#	label roots now [r=root.der ...] [c=crl.der ...] l=leaf.der [l=inter.der ...]
#	label store certsdir crlsdir l=leaf.der [l=inter.der ...]
#
# "roots" is verify_certchain_roots with the roots, CRLs and time
# given; "store" is verify_certchain, as a TLS client calls it, with
# the two directories bound over /lib/certs and /lib/crls in this
# program's own name space and a module instance of its own (the
# stores are read once).  Each case prints
#
#	label: ACCEPT
#	label: REJECT why
#	label: EXCEPTION text
#
# The last is what the test is there to refuse: a certificate is a
# peer's bytes, and verifying it does not end the caller.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "asn1.m";
include "keyring.m";
include "security.m";
include "pkcs.m";
include "x509.m";

X509Chain: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		sys->print("cannot open %s: %r\n", path);
		return nil;
	}
	buf := array[1024*1024] of byte;
	tot := 0;
	while(tot < len buf && (n := sys->read(fd, buf[tot:], len buf - tot)) > 0)
		tot += n;
	return buf[0:tot];
}

rev(l: list of array of byte): list of array of byte
{
	r: list of array of byte;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(len args != 2) {
		sys->print("usage: x509_chain cases\n");
		return;
	}
	sys->pctl(Sys->FORKNS, nil);
	f := bufio->open(hd tl args, Sys->OREAD);
	if(f == nil) {
		sys->print("cannot open %s: %r\n", hd tl args);
		return;
	}
	shared := load X509 X509->PATH;
	if(shared == nil || (e := shared->init()) != nil) {
		sys->print("cannot load x509: %s\n", e);
		return;
	}
	while((line := f.gets('\n')) != nil) {
		(n, w) := sys->tokenize(line, " \t\n");
		if(n < 3 || (hd w)[0] == '#')
			continue;
		label := hd w;
		mode := hd tl w;
		w = tl tl w;
		x509 := shared;
		now := 0;
		if(mode == "store") {
			if(sys->bind(hd w, "/lib/certs", Sys->MREPL) < 0 ||
			   sys->bind(hd tl w, "/lib/crls", Sys->MREPL) < 0) {
				sys->print("%s: cannot bind the stores: %r\n", label);
				continue;
			}
			w = tl tl w;
			x509 = load X509 X509->PATH;
			if(x509 == nil || x509->init() != nil) {
				sys->print("%s: cannot load x509\n", label);
				continue;
			}
		} else {
			now = int hd w;
			w = tl w;
		}
		roots, crls, chain: list of array of byte;
		for(; w != nil; w = tl w) {
			a := hd w;
			if(len a < 3 || a[1] != '=')
				continue;
			b := readfile(a[2:]);
			case a[0] {
			'r' =>	roots = b :: roots;
			'c' =>	crls = b :: crls;
			'l' =>	chain = b :: chain;
			}
		}
		ok := 0;
		err := "";
		{
			if(mode == "store")
				(ok, err) = x509->verify_certchain(rev(chain));
			else
				(ok, err) = x509->verify_certchain_roots(rev(chain), rev(roots), rev(crls), now);
			if(ok)
				sys->print("%s: ACCEPT\n", label);
			else
				sys->print("%s: REJECT %s\n", label, err);
		} exception x {
		"*" =>
			sys->print("%s: EXCEPTION %s\n", label, x);
		}
	}
	sys->print("DONE\n");
}
