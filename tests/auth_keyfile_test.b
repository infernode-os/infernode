implement AuthKeyfileTest;

#
# Auth->keyfile, which names the certificate a key specification asks
# for: server, service and dom are names in the user's key directory and
# nothing else.  With a slash in one (server=../../x) the name made of it
# was a path to anywhere the caller could read; key= is the attribute
# that takes a path, and still does.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	auth: Auth;
include "testing.m";
	testing: Testing;
	T: import testing;

AuthKeyfileTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auth_keyfile_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
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
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testKeyfile(t: ref T)
{
	# a path is what key= is for
	t.assertseq(auth->keyfile("key=/some/where/cert"), "/some/where/cert", "key= with a path is that path");
	t.assertseq(auth->keyfile("key=./cert"), "./cert", "key= with a relative path is that path");

	# the others are names
	bad := array[] of {
		"server=../../../etc/x",
		"server=a/b",
		"server=tcp!../../x",
		"server=net/../..!host",
		"service=../x server=host",
		"service=a/b",
	};
	for(i := 0; i < len bad; i++)
		t.assert(auth->keyfile(bad[i]) == nil, bad[i] + " names no key file");

	# a dom with a slash is not looked for; the rest of the specification stands
	f := auth->keyfile("dom=../../x");
	t.assert(f != nil && !contains(f, ".."), "dom=../../x is not followed: " + f);

	# and plain names still give a file in the key directory
	f = auth->keyfile("server=somehost service=styx");
	t.assert(f != nil && contains(f, "/keyring/") && !contains(f, ".."), "a plain server names a file in the key directory: " + f);
	f = auth->keyfile("");
	t.assert(f != nil && contains(f, "/keyring/default"), "no specification is the default key: " + f);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || auth == nil){
		sys->fprint(sys->fildes(2), "cannot load testing or auth: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Keyfile", testKeyfile);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
