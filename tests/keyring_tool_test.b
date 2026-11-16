implement KeyringToolTest;

#
# The agent's keyring tool, against a stand-in presentation ctl and a
# stand-in list of factotum's keys.
#
# "open" says what the UI server said. It answered "launched Keyring in
# presentation zone" whatever became of its write: a ctl that refused
# everything, and a second open (which the UI server refuses, the
# artifact existing), were both "launched".
#
# "check" answers for a whole service or domain name. It matched any
# text after "service=" or "dom=" in factotum's listing, so where the
# tool can read the listing a caller could spell out every key's
# attributes a character at a time ("check ima" was yes, "check imap
# proto=pass dom=imap.exa" was yes).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

KeyringToolTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Tool: module
{
	init: fn(): string;
	exec: fn(args: string): string;
};

SRCFILE: con "/tests/keyring_tool_test.b";

passed := 0;
failed := 0;
skipped := 0;
scratch: string;
kr: Tool;

broken := 0;	# the ctl refuses everything
made := 0;	# the keyring artifact exists
written: list of string;

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

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

mkdir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

put(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil) {
		b := array of byte data;
		sys->write(fd, b, len b);
	}
}

# the presentation ctl, as luciuisrv answers a create and a center
ctlserver(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			rc <-= (nil, nil);
	(nil, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		cmd := string data;
		written = cmd :: written;
		if(broken)
			wc <-= (0, "activity is closed");
		else if(hasprefix(cmd, "create ") && made)
			wc <-= (0, "artifact already exists: keyring");
		else {
			if(hasprefix(cmd, "create "))
				made = 1;
			wc <-= (len data, nil);
		}
	}
}

testOpen(t: ref T)
{
	r := kr->exec("open");
	t.assert(hasprefix(r, "launched Keyring"), "the first open launches: " + r);
	r = kr->exec("open");
	t.assert(!hasprefix(r, "error") && contains(r, "already open"),
		"a second says it is already open: " + r);
	broken = 1;
	r = kr->exec("open");
	t.assert(hasprefix(r, "error"), "a ctl that refuses is an error, not a launch: " + r);
	r = kr->exec("need an API key");
	t.assert(hasprefix(r, "error"), "and so for need: " + r);
	broken = 0;
}

testCheck(t: ref T)
{
	t.assert(hasprefix(kr->exec("check imap"), "yes"), "a service that has a key: " + kr->exec("check imap"));
	t.assert(hasprefix(kr->exec("check imap.example.com"), "yes"), "a mail server by its domain");
	t.assert(hasprefix(kr->exec("check ima"), "no"), "part of a service's name is no service: " + kr->exec("check ima"));
	t.assert(hasprefix(kr->exec("check imap.exa"), "no"), "nor part of a domain");
	t.assert(hasprefix(kr->exec("check wallet-eth-sav"), "no"), "nor part of an account's name");
	r := kr->exec("check imap proto=pass dom=imap.exa");
	t.assert(hasprefix(r, "error"), "more than a name is refused: " + r);
	t.assert(hasprefix(kr->exec("check nosuch"), "no"), "a service with no key");
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

	sys->pctl(Sys->FORKNS, nil);
	scratch = sys->sprint("/tmp/keyring_tool_test.%d", sys->pctl(0, nil));
	mkdir(scratch);
	ui := scratch + "/ui";
	mkdir(ui);
	mkdir(ui + "/activity");
	mkdir(ui + "/activity/0");
	mkdir(ui + "/activity/0/presentation");
	put(ui + "/activity/current", "0\n");
	if(sys->bind("#s", ui + "/activity/0/presentation", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind #s: %r");
	fio := sys->file2chan(ui + "/activity/0/presentation", "ctl");
	if(fio == nil)
		raise sys->sprint("fail:file2chan: %r");
	spawn ctlserver(fio);
	mkdir("/mnt/ui");	# a fresh tree has no mount point; a dev tree may
	if(sys->bind(ui, "/mnt/ui", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind /mnt/ui: %r");

	fa := scratch + "/factotum";
	mkdir(fa);
	put(fa + "/ctl",
		"key proto=pass service=imap dom=imap.example.com user=alice !password?\n" +
		"key proto=pass service=wallet-eth-savings user=wallet chain=ethereum !password?\n");
	if(sys->bind(fa, "/mnt/factotum", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind /mnt/factotum: %r");

	kr = load Tool "/dis/veltro/tools/keyring.dis";
	if(kr == nil)
		raise sys->sprint("fail:cannot load the keyring tool: %r");
	kr->init();

	run("Open/SaysWhatHappened", testOpen);
	run("Check/WholeName", testCheck);

	sys->unmount(nil, "/mnt/ui");
	sys->unmount(nil, "/mnt/factotum");
	sys->unmount(nil, ui + "/activity/0/presentation");
	rmtree(scratch);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

rmtree(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil) {
		for(;;) {
			(n, dirs) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				rmtree(path + "/" + dirs[i].name);
		}
		fd = nil;
	}
	sys->remove(path);
}
