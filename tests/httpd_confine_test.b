implement HttpdConfineTest;

#
# The confinement httpd(8) gives each connection, as the kernel keeps
# it: pctl(FORKNS), the site bound over / (MREPL), chdir /, pctl(NODEVS)
# -- appl/svc/httpd/httpd.b's connection() in order.  After it:
#
#   - "/" is the site, and ".." from it, however many, is the site
#   - what was outside it (/dis, /dev, /prog, /n, /net) is not there
#   - no device can be attached by name (#c, #p, #U, #I, #e is allowed
#     and empty after NEWENV)
#   - a host symlink in the site (devfs) is not followed, a file or a
#     directory
#   - what was mounted inside the site before is still there
#   - the parent's name space is unchanged
#
# httpd refuses ".." in a request before it reaches the kernel; this is
# the layer under that, should a path ever get past it.
#
# Run by tests/host/httpd_test.sh, which makes the site (with its host
# symlinks); alone, it makes one under /tmp without them.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

HttpdConfineTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/httpd_confine_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

site := "";
symlinks := 0;

# Results from a confined process, as lines
confined(c: chan of list of string)
{
	r: list of string;
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->NEWENV, nil);
	if(sys->bind(site, "/", Sys->MREPL) < 0 || sys->chdir("/") < 0) {
		c <-= sys->sprint("setup failed: %r") :: nil;
		return;
	}
	sys->pctl(Sys->NODEVS, nil);
	for(l := "/" :: "/.." :: "/../.." :: "/../../.." :: "/sub/../.." :: nil; l != nil; l = tl l)
		r = sys->sprint("dir %s %s", hd l, names(hd l)) :: r;
	for(l = "/dis/sh.dis" :: "/dev/cons" :: "/prog" :: "/n/local" :: "/net/tcp" :: "/../dis/sh.dis" ::
	        "/../../dev/sysname" :: "#c/sysname" :: "#p" :: "#U/etc/passwd" :: "#U*/etc/passwd" :: "#I/tcp" ::
	        "#s" :: "#e" :: "/link.txt" :: "/etcdir/hostname" :: "/sub/escape/hostname" :: nil; l != nil; l = tl l) {
		fd := sys->open(hd l, Sys->OREAD);
		if(fd == nil)
			r = sys->sprint("open %s no", hd l) :: r;
		else {
			b := array[64] of byte;
			n := sys->read(fd, b, len b);
			if(n < 0)
				n = 0;
			r = sys->sprint("open %s yes %q", hd l, string b[0:n]) :: r;
		}
	}
	fd := sys->open("/mounted/marker", Sys->OREAD);
	r = sys->sprint("mounted %d", fd != nil) :: r;
	c <-= r;
}

names(d: string): string
{
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil)
		return "none";
	s := "";
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			s += " " + dirs[i].name;
	}
	return s;
}

lookup(r: list of string, key: string): string
{
	for(; r != nil; r = tl r)
		if(len hd r >= len key && (hd r)[0:len key] == key)
			return (hd r)[len key:];
	return nil;
}

testConfined(t: ref T)
{
	c := chan of list of string;
	spawn confined(c);
	r := <-c;
	if(len r == 1)
		t.fatal(hd r);
	top := lookup(r, "dir / ");
	t.assert(contains(top, " hello.txt") && contains(top, " sub"), "/ is the site: " + top);
	for(l := "/.." :: "/../.." :: "/../../.." :: "/sub/../.." :: nil; l != nil; l = tl l)
		t.assertseq(lookup(r, "dir " + hd l + " "), top, hd l + " is the site");
	for(l = "/dis/sh.dis" :: "/dev/cons" :: "/prog" :: "/n/local" :: "/net/tcp" :: "/../dis/sh.dis" ::
	        "/../../dev/sysname" :: "#c/sysname" :: "#p" :: "#U/etc/passwd" :: "#U*/etc/passwd" :: "#I/tcp" :: nil; l != nil; l = tl l)
		t.assertseq(lookup(r, "open " + hd l + " "), "no", hd l + " not reached");
	t.assertseq(lookup(r, "open #e "), "yes ''", "#e is allowed (NODEVS keeps it), and empty after NEWENV");
	# #s (srv(3)) NODEVS keeps too: what is posted there can be
	# opened by name.  httpd never opens a name that begins with #.
	t.log("#s: " + lookup(r, "open #s "));
	if(symlinks) {
		for(l = "/link.txt" :: "/etcdir/hostname" :: "/sub/escape/hostname" :: nil; l != nil; l = tl l)
			t.assertseq(lookup(r, "open " + hd l + " "), "no", "host symlink " + hd l + " not followed");
	}
	t.assertseq(lookup(r, "mounted "), "1", "a mount inside the site is still there");
	t.assert(sys->open("/dis/sh.dis", Sys->OREAD) != nil, "the parent's name space unchanged");
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
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
	for(a := tl args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
		else
			site = hd a;
	}
	if(site == nil) {
		# a site of our own, without host symlinks
		site = "/tmp/httpd_confine." + string sys->pctl(0, nil);
		sys->create(site, Sys->OREAD, Sys->DMDIR|8r755);
		sys->create(site + "/sub", Sys->OREAD, Sys->DMDIR|8r755);
		sys->create(site + "/hello.txt", Sys->OWRITE, 8r644);
	} else
		symlinks = 1;
	# something mounted inside the site, as a device's server would be
	sys->create(site + "/mounted", Sys->OREAD, Sys->DMDIR|8r755);
	m := "/tmp/httpd_confine_m." + string sys->pctl(0, nil);
	sys->create(m, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(m + "/marker", Sys->OWRITE, 8r644);
	if(sys->bind(m, site + "/mounted", Sys->MREPL) < 0)
		sys->fprint(sys->fildes(2), "bind: %r\n");

	run("Confined", testConfined);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
