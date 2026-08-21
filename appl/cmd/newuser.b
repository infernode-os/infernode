implement Newuser;

#
# newuser - create a user home under /usr from the shipped skeleton.
#
# Historically this was prose, not code: doc/install.ms said "To create
# a new user, copy the directory /usr/inferno into /usr/username", and
# kfscmd(8)'s newuser command sat in a roff ignore-block, documented
# but never implemented. This finishes that arc. With the whole-/usr
# overlay (docs/PERSISTENCE.md) the new home lands on the durable side
# and survives system updates by construction.
#
# Network authentication for the new user (changelogin(8) on the
# signer, getauthinfo(8) at first login) remains separate, as it
# always was.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";

include "arg.m";

include "readdir.m";
	readdir: Readdir;

Newuser: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SKEL: con "/usr/inferno";

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sprint("load arg: %r"));
	readdir = load Readdir Readdir->PATH;

	skel := SKEL;
	arg->init(args);
	arg->setusage("newuser [-s skeleton] name");
	while((c := arg->opt()) != 0)
		case c {
		's' =>	skel = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	name := hd args;

	if(!validname(name))
		fail("invalid user name (letters, digits, - and _ only)");
	home := "/usr/" + name;
	(ok, nil) := sys->stat(home);
	if(ok >= 0)
		fail(home + " already exists");
	(sok, sd) := sys->stat(skel);
	if(sok < 0 || (sd.mode & Sys->DMDIR) == 0)
		fail(sprint("no skeleton directory %s", skel));

	err := copydir(skel, home);
	if(err != nil)
		fail(err);
	# per-user working dirs the skeleton ships empty (and so may be
	# missing from a copied tree)
	mkdirp(home + "/tmp");
	mkdirp(home + "/keyring");
	mkdirp(home + "/charon");

	sys->print("%s created from %s\n", home, skel);
	sys->print("for networked authentication: changelogin(8) on the signer, then getauthinfo(8) as the user\n");
}

validname(s: string): int
{
	if(s == nil || s == "" || s == "." || s == ".." || len s > 64)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == '-' || c == '_'))
			return 0;
	}
	return 1;
}

# recursive copy; skips secstore contents (credentials are per-user,
# never inherited) but keeps the empty directory.
copydir(src, dst: string): string
{
	(ok, sd) := sys->stat(src);
	if(ok < 0)
		return sprint("stat %s: %r", src);
	if(sys->create(dst, Sys->OREAD, Sys->DMDIR | (sd.mode & 8r777)) == nil) {
		(dok, dd) := sys->stat(dst);
		if(dok < 0 || (dd.mode & Sys->DMDIR) == 0)
			return sprint("create %s: %r", dst);
	}
	if(readdir == nil)
		return "cannot load readdir";
	(dirs, n) := readdir->init(src, Readdir->NAME);
	if(n < 0)
		return sprint("read %s: %r", src);
	for(i := 0; i < n; i++) {
		d := dirs[i];
		s := src + "/" + d.name;
		t := dst + "/" + d.name;
		if(d.mode & Sys->DMDIR) {
			# per-install service state, never inherited: credentials,
			# temp, the audit chain + its venti store, snapshots
			if(d.name == "audit" || d.name == "snapshots")
				continue;
			if(d.name == "secstore" || d.name == "tmp") {
				mkdirp(t);
				continue;
			}
			err := copydir(s, t);
			if(err != nil)
				return err;
		} else {
			err := copyfile(s, t, d.mode & 8r777);
			if(err != nil)
				return err;
		}
	}
	return nil;
}

copyfile(src, dst: string, mode: int): string
{
	sfd := sys->open(src, Sys->OREAD);
	if(sfd == nil)
		return sprint("open %s: %r", src);
	dfd := sys->create(dst, Sys->OWRITE, mode);
	if(dfd == nil)
		return sprint("create %s: %r", dst);
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(sfd, buf, len buf);
		if(n < 0)
			return sprint("read %s: %r", src);
		if(n == 0)
			break;
		if(sys->write(dfd, buf, n) != n)
			return sprint("write %s: %r", dst);
	}
	return nil;
}

mkdirp(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

fail(s: string)
{
	sys->fprint(stderr, "newuser: %s\n", s);
	raise "fail:" + s;
}
