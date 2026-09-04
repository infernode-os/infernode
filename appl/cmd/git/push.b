implement Gitpush;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
	arg: Arg;

include "git.m";
	git: Git;
	Hash, Ref, Repo, RefUpdate: import git;

Gitpush: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	arg = load Arg Arg->PATH;
	git = load Git Git->PATH;
	if(git == nil)
		fail(sprint("load Git: %r"));

	err := git->init();
	if(err != nil)
		fail("git init: " + err);

	arg->init(args);
	arg->setusage(arg->progname() + " [-v] [remote] [refspec]");

	verbose := 0;
	while((ch := arg->opt()) != 0)
		case ch {
		'v' =>
			verbose = 1;
		* =>
			arg->usage();
		}

	argv := arg->argv();
	remote := "origin";
	refspec := "";
	if(len argv >= 1) {
		remote = hd argv;
		argv = tl argv;
	}
	if(len argv >= 1) {
		refspec = hd argv;
	}

	gitdir := git->findgitdir(".");
	if(gitdir == nil)
		fail("not a git repository");

	remoteurl := git->getremoteurl(gitdir, remote);
	if(remoteurl == nil)
		fail("no url for remote: " + remote);

	(repo, oerr) := git->openrepo(gitdir);
	if(oerr != nil)
		fail("openrepo: " + oerr);

	# Resolve HEAD to get local branch and hash
	(headref, herr) := repo.head();
	if(herr != nil)
		fail("HEAD: " + herr);

	branch := "";
	if(len headref > 11 && headref[:11] == "refs/heads/")
		branch = headref[11:];
	else
		fail("HEAD is not on a branch");

	(localhash, lrerr) := repo.readref(headref);
	if(lrerr != nil)
		fail("resolve HEAD: " + lrerr);

	# Parse refspec
	srcbranch := branch;
	dstbranch := branch;
	if(refspec != "") {
		(src, dst) := splitcolon(refspec);
		if(dst != "") {
			srcbranch = src;
			dstbranch = dst;
		} else {
			srcbranch = refspec;
			dstbranch = refspec;
		}
		# Re-resolve if different from HEAD branch
		if(srcbranch != branch) {
			(lh, le) := repo.readref("refs/heads/" + srcbranch);
			if(le != nil)
				fail("branch '" + srcbranch + "' not found");
			localhash = lh;
		}
	}

	dstrefname := "refs/heads/" + dstbranch;

	if(verbose)
		sys->fprint(stderr, "pushing %s -> %s on %s (%s)\n",
			srcbranch, dstbranch, remote, remoteurl);

	# Discover remote refs
	(refs, nil, derr) := git->discover_receive(remoteurl);
	if(derr != nil)
		fail("discover: " + derr);

	# Find old hash for target ref on remote
	oldhash := git->nullhash();
	for(rl := refs; rl != nil; rl = tl rl) {
		r := hd rl;
		if(r.name == dstrefname) {
			oldhash = r.hash;
			break;
		}
	}

	# Already up to date?
	if(localhash.eq(oldhash)) {
		sys->print("Everything up-to-date\n");
		return;
	}

	if(verbose)
		sys->fprint(stderr, "%s: %s -> %s\n",
			dstrefname, oldhash.hex()[:7], localhash.hex()[:7]);

	# Collect remote hashes as have set
	have: list of Hash;
	for(rl = refs; rl != nil; rl = tl rl) {
		r := hd rl;
		have = r.hash :: have;
	}

	# Enumerate objects to send
	want := localhash :: nil;
	(objects, eerr) := git->enumobjects(repo, want, have);
	if(eerr != nil)
		fail("enumobjects: " + eerr);

	nobj := 0;
	for(ol := objects; ol != nil; ol = tl ol)
		nobj++;

	if(verbose)
		sys->fprint(stderr, "sending %d objects\n", nobj);

	# Build pack
	(packdata, perr) := git->writepack(objects);
	if(perr != nil)
		fail("writepack: " + perr);

	# Read credentials.  Deliberately done here rather than in the Git
	# library: #338 removed readcredentials() from Git so that a module
	# loaded by an agent tool cannot read a credentials file.  The command
	# reads it in its own namespace, where visibility of .git/credentials
	# is the capability that decides whether a push can authenticate.
	creds := readcredentials(gitdir);
	if(creds == nil)
		fail("no credentials found; create .git/credentials with user:token");

	# Push
	upd := ref RefUpdate(oldhash, localhash, dstrefname);
	updates := upd :: nil;

	serr := git->sendpack(remoteurl, updates, packdata, creds);
	if(serr != nil)
		fail("push: " + serr);

	sys->print("To %s\n", remoteurl);
	sys->print("   %s..%s  %s -> %s\n",
		oldhash.hex()[:7], localhash.hex()[:7], srcbranch, dstbranch);
}

readcredentials(gitdir: string): string
{
	fd := sys->open(gitdir + "/credentials", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array [1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return strtrim(string buf[:n]);
}

strtrim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

splitcolon(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ':')
			return (s[:i], s[i+1:]);
	return (s, "");
}

fail(msg: string)
{
	sys->fprint(stderr, "git/push: %s\n", msg);
	raise "fail:" + msg;
}
