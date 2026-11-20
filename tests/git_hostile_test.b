implement GitHostileTest;

#
# The git library on names that a remote or a repository's own objects
# give it.
#
# A ref is a file of its name under .git, and a tree entry a file of its
# name in a directory of the work tree.  The library joined the names to
# those directories whatever they were:
#
#   - a remote advertising refs/heads/../../../../X had X written, outside
#     .git, when its refs were stored (updaterefs, writeref), holding the
#     remote's hash;
#   - a tree with an entry "..", a name with a slash, or ".git" was
#     checked out where its author chose: above the work tree, or into
#     git's own directory (its config, which names the remote pushed to);
#   - HEAD, or a symbolic ref, saying "ref: ../../x" had the file x read
#     as the ref, and one naming itself was followed without end;
#   - a tree that could not be read was taken for a clean work tree, and
#     what followed wrote over it.
#
# Names are now a ref's (git's check-ref-format, under refs/) and a tree
# entry's (one component; not ".", "..", or what a host reads as ".git"),
# checked where they arrive and again where they become a path.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

include "git.m";
	git: Git;
	Hash, TreeEntry, Repo, Ref, IndexEntry: import git;

GitHostileTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/git_hostile_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# A scratch directory holding a repository at repo/.git, so that names
# escaping the repository land in the scratch directory and nowhere else.
top: string;

mkrepo(t: ref T, name: string): (string, string, ref Repo)
{
	dir := top + "/" + name;
	cleanup(dir);
	sys->create(top, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(dir, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(dir + "/repo", Sys->OREAD, Sys->DMDIR | 8r755);
	gitdir := dir + "/repo/.git";
	(repo, err) := git->initrepo(gitdir, 0);
	if(err != nil)
		t.fatal("initrepo: " + err);
	return (dir, gitdir, repo);
}

cleanup(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		sys->remove(path);
		return;
	}
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			child := path + "/" + dirs[i].name;
			if(dirs[i].qid.qtype & Sys->QTDIR)
				cleanup(child);
			else
				sys->remove(child);
		}
	}
	fd = nil;
	sys->remove(path);
}

# the files under path whose names begin ESCAPED, as one string
escaped(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			child := path + "/" + dirs[i].name;
			if(len dirs[i].name >= 7 && dirs[i].name[0:7] == "ESCAPED")
				s += " " + child;
			if(dirs[i].qid.qtype & Sys->QTDIR)
				s += escaped(child);
		}
	}
	return s;
}

slurp(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

put(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil) {
		b := array of byte s;
		sys->write(fd, b, len b);
	}
}

somehash(): Hash
{
	(h, nil) := git->parsehash("ce013625030ba8dba906f756967f9e9ca394464a");
	return h;
}

testRefNames(t: ref T)
{
	good := array[] of {
		"refs/heads/main",
		"refs/heads/feature/x-1_2.y",
		"refs/remotes/origin/main",
		"refs/tags/v1.0",
		"refs/heads/@",
	};
	for(i := 0; i < len good; i++)
		t.assert(git->validrefname(good[i]), "a ref's name: " + good[i]);
	bad := array[] of {
		"",
		"HEAD",
		"refs/",
		"main",
		"/refs/heads/x",
		"refs/heads/../../../../x",
		"refs/heads/..",
		"refs/heads/a..b",
		"refs/heads/.hidden",
		"refs/heads/a/.b",
		"refs/heads/x.lock",
		"refs/heads/x.lock/y",
		"refs/heads//x",
		"refs/heads/x/",
		"refs/heads/x.",
		"refs/heads/a b",
		"refs/heads/a\tb",
		"refs/heads/a\nb",
		"refs/heads/a\u007fb",
		"refs/heads/a~1",
		"refs/heads/a^{}",
		"refs/heads/a:b",
		"refs/heads/a?",
		"refs/heads/a*",
		"refs/heads/a[1]",
		"refs/heads/a\\b",
		"refs/heads/a@{1}",
		"../refs/heads/x",
	};
	for(i = 0; i < len bad; i++)
		t.assert(!git->validrefname(bad[i]), sprint("not a ref's name: %q", bad[i]));
}

testTreeNames(t: ref T)
{
	good := array[] of {
		"a.txt", "Makefile", ".gitignore", ".github", "a b", "a\\b", "git", "x.git", ".x", "été",
	};
	for(i := 0; i < len good; i++)
		t.assert(git->validtreename(good[i]), "a tree entry's name: " + good[i]);
	bad := array[] of {
		"", ".", "..", "a/b", "../x", "/x", "x/",
		".git", ".GIT", ".Git", ".git.", ".git ", ".git . .", ".git::$INDEX_ALLOCATION",
		"git~1", "GIT~1", ".g‌it", "..\\x", "a\\.git\\b", "a\\..", "...", ". ",
		"a\nb", "a\u0001b", "a\u007f",
	};
	for(i = 0; i < len bad; i++)
		t.assert(!git->validtreename(bad[i]), sprint("not a tree entry's name: %q", bad[i]));
}

# A ref is written only under .git, under refs/
testWriteRefOutside(t: ref T)
{
	(dir, gitdir, repo) := mkrepo(t, "writeref");
	h := somehash();
	names := array[] of {
		"refs/heads/../../../../ESCAPED-REF",
		"refs/heads/../../../ESCAPED-IN-WORKTREE",
		"../ESCAPED-PLAIN",
		"refs/../../ESCAPED-SHORT",
		"refs/heads/ESCAPED.lock",
		"ESCAPED-TOP",
		"config",
	};
	config := slurp(gitdir + "/config");
	for(i := 0; i < len names; i++)
		git->writeref(gitdir, names[i], h);
	t.assertseq(escaped(dir), "", "no ref is written outside refs/");
	t.assertseq(slurp(gitdir + "/config"), config, ".git/config is not a ref");

	# and the result says so
	t.assertnotnil(git->writeref(gitdir, "refs/heads/../../../../ESCAPED-REF", h), "an unsafe name is an error");
	t.assertnotnil(git->writesymref(gitdir, "HEAD", "refs/heads/../../ESCAPED-HEAD"), "an unsafe target is an error");
	t.assertnotnil(git->writesymref(gitdir, "../ESCAPED-SYM", "refs/heads/main"), "an unsafe symbolic ref is an error");
	t.assertseq(escaped(dir), "", "nothing written by the refused calls");

	# a ref still is
	t.assertnil(git->writeref(gitdir, "refs/heads/topic/one", h), "an ordinary ref is written");
	(got, err) := repo.readref("refs/heads/topic/one");
	t.assertnil(err, "and read back");
	t.assert(got.eq(h), "with its hash");
	t.assertnil(git->writesymref(gitdir, "HEAD", "refs/heads/topic/one"), "HEAD is moved");
	(hr, herr) := repo.head();
	t.assertnil(herr, "HEAD read");
	t.assertseq(hr, "refs/heads/topic/one", "HEAD names the branch");
	cleanup(dir);
}

# A remote's refs are stored under their own names only when those are names
testUpdateRefsHostile(t: ref T)
{
	(dir, gitdir, repo) := mkrepo(t, "updaterefs");
	h := somehash();
	names := array[] of {
		"HEAD",
		"refs/heads/main",
		"refs/heads/../../../../ESCAPED-REF",
		"refs/heads/../../../../../ESCAPED-ABOVE",
		"refs/tags/../../../ESCAPED-TAG",
		"refs/tags/v1",
		"refs/tags/v1^{}",
		"refs/pull/1/head",
	};
	refs: list of Ref;
	for(i := len names - 1; i >= 0; i--)
		refs = Ref(names[i], h) :: refs;

	err := git->updaterefs(gitdir, "origin", refs, 0);
	t.assertseq(escaped(dir), "", "a remote's ref names write nothing outside refs/");
	t.assertnotnil(err, "the unsafe names are reported");
	t.log("updaterefs: " + err);
	(got, rerr) := repo.readref("refs/remotes/origin/main");
	t.assertnil(rerr, "the remote's branch is tracked");
	t.assert(got.eq(h), "at the remote's hash");
	(nil, terr) := repo.readref("refs/tags/v1");
	t.assertnil(terr, "the remote's tag is stored");
	(ok, nil) := sys->stat(gitdir + "/refs/tags/v1^{}");
	t.assert(ok < 0, "what a tag points at (^{}) is not stored as a ref");

	# the remote's name is one component under refs/remotes
	git->updaterefs(gitdir, "../../../ESCAPED-REMOTE", Ref("refs/heads/main", h) :: nil, 0);
	git->updaterefs(gitdir, "..", Ref("refs/heads/ESCAPED-DOTDOT", h) :: nil, 0);
	git->updaterefs(gitdir, "a/b", Ref("refs/heads/ESCAPED-SLASH", h) :: nil, 0);
	t.assertseq(escaped(dir), "", "a remote's own name writes nothing outside refs/remotes");
	t.assertnotnil(git->updaterefs(gitdir, "..", Ref("refs/heads/main", h) :: nil, 0), "an unsafe remote name is an error");
	cleanup(dir);
}

mktree(t: ref T, gitdir: string, ents: array of TreeEntry): Hash
{
	(h, err) := git->writelooseobj(gitdir, git->OBJ_TREE, git->encodetree(ents));
	if(err != nil)
		t.fatal("write tree: " + err);
	return h;
}

# A tree's names are files of the directory it is checked out in
testCheckoutHostileTree(t: ref T)
{
	(dir, gitdir, repo) := mkrepo(t, "checkout");
	work := dir + "/repo";
	(blob, berr) := git->writelooseobj(gitdir, git->OBJ_BLOB, array of byte "from the tree\n");
	t.assertnil(berr, "blob written");
	inner := mktree(t, gitdir, array[] of {TreeEntry(8r100644, "ESCAPED-INNER", blob)});
	cfg := mktree(t, gitdir, array[] of {TreeEntry(8r100644, "config", blob)});
	config := slurp(gitdir + "/config");

	evil := array[] of {
		TreeEntry(8r40000, "..", inner),
		TreeEntry(8r100644, "../ESCAPED-SLASH", blob),
		TreeEntry(8r100644, "sub/../../ESCAPED-DEEP", blob),
		TreeEntry(8r40000, ".git", cfg),
		TreeEntry(8r40000, ".GIT", cfg),
		TreeEntry(8r40000, ".git.", cfg),
		TreeEntry(8r100644, ".", blob),
		TreeEntry(8r100644, "", blob),
	};
	for(i := 0; i < len evil; i++) {
		# beside an ordinary file, as a hostile branch's tree would be
		ents := array[] of {TreeEntry(8r100644, "ok.txt", blob), evil[i]};
		err := repo.checkout(mktree(t, gitdir, ents), work);
		t.assertnotnil(err, sprint("checkout refuses a tree with an entry %q", evil[i].name));
		t.assertseq(escaped(dir), "", sprint("an entry %q writes nothing outside the work tree", evil[i].name));
		t.assertseq(slurp(gitdir + "/config"), config, sprint("an entry %q leaves .git/config alone", evil[i].name));
		# by the names made, not by stat: on a host that folds case
		# (macOS) a stat of .GIT finds the repository's own .git
		t.assertseq(strangers(work), "", "nothing that a host reads as .git is made");
	}

	# an ordinary tree is checked out as it was
	sub := mktree(t, gitdir, array[] of {TreeEntry(8r100644, "b.txt", blob)});
	good := array[] of {TreeEntry(8r100644, "a.txt", blob), TreeEntry(8r40000, "sub", sub)};
	t.assertnil(repo.checkout(mktree(t, gitdir, good), work), "an ordinary tree is checked out");
	t.assertseq(slurp(work + "/a.txt"), "from the tree\n", "its file");
	t.assertseq(slurp(work + "/sub/b.txt"), "from the tree\n", "its directory's file");

	# and the same trees are refused wherever they are read for their names
	(nil, perr) := git->parsetree(git->encodetree(array[] of {TreeEntry(8r40000, "..", inner)}));
	t.assertnotnil(perr, "parsetree refuses the name");
	cleanup(dir);
}

# The names in a work tree other than the repository and the file
# every hostile tree carries
strangers(work: string): string
{
	fd := sys->open(work, Sys->OREAD);
	if(fd == nil)
		return sprint("cannot open %s: %r", work);
	s := "";
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(dirs[i].name != ".git" && dirs[i].name != "ok.txt")
				s += " " + dirs[i].name;
	}
	return s;
}

# What HEAD and a symbolic ref say is a ref's name
testSymbolicRefs(t: ref T)
{
	(dir, gitdir, repo) := mkrepo(t, "symref");
	h := somehash();

	# a file outside the repository that holds a hash is not a ref
	put(dir + "/outside", h.hex() + "\n");
	put(gitdir + "/HEAD", "ref: ../../outside\n");
	(nil, err) := repo.readref("HEAD");
	t.assertnotnil(err, "HEAD naming a file outside .git is not followed");
	(nil, err) = repo.readref("../../outside");
	t.assertnotnil(err, "a ref is not read from outside .git");

	# a symbolic ref naming itself ends
	put(gitdir + "/HEAD", "ref: refs/heads/loop\n");
	put(gitdir + "/refs/heads/loop", "ref: refs/heads/loop\n");
	done := chan of string;
	spawn readhead(repo, done);
	tick := chan of int;
	spawn timer(tick, 10000);
	alt {
	e := <-done =>
		t.assertnotnil(e, "a symbolic ref naming itself is an error");
	<-tick =>
		t.error("a symbolic ref naming itself was followed without end");
	}

	# a chain of two is followed
	t.assertnil(git->writeref(gitdir, "refs/heads/real", h), "a branch");
	put(gitdir + "/refs/heads/alias", "ref: refs/heads/real\n");
	put(gitdir + "/HEAD", "ref: refs/heads/alias\n");
	(got, gerr) := repo.readref("HEAD");
	t.assertnil(gerr, "HEAD through a symbolic ref");
	t.assert(got.eq(h), "is the branch's commit");
	cleanup(dir);
}

readhead(repo: ref Repo, done: chan of string)
{
	{
		(nil, err) := repo.readref("HEAD");
		done <-= err;
	} exception e {
	"*" =>
		done <-= "exception: " + e;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# A tree that cannot be read is not a clean work tree
testIsCleanUnreadable(t: ref T)
{
	(dir, nil, repo) := mkrepo(t, "isclean");
	work := dir + "/repo";
	put(work + "/precious.txt", "not committed\n");
	(clean, why) := git->isclean(repo, somehash(), work);
	t.assert(!clean, "a tree that is not in the repository is not clean");
	t.log("isclean: " + why);
	(empty, nil) := git->parsehash("4b825dc642cb6eb9a060e54bf8d69288fbee4904");
	(eclean, nil) := git->isclean(repo, empty, work);
	t.assert(eclean, "the empty tree, which need not be stored, is");
	cleanup(dir);
}

# The index is made of HEAD's tree when nothing is staged: its names too
testIndexFromHostileTree(t: ref T)
{
	(dir, gitdir, repo) := mkrepo(t, "index");
	(blob, nil) := git->writelooseobj(gitdir, git->OBJ_BLOB, array of byte "x\n");
	names := array[] of {"..", "x\n100644 " + blob.hex() + " ../../ESCAPED-INDEX", "a/b"};
	(headref, herr) := repo.head();
	t.assertnil(herr, "HEAD names a branch");
	for(i := 0; i < len names; i++) {
		mode := 8r100644;
		eh := blob;
		if(names[i] == "..") {
			mode = 8r40000;
			eh = mktree(t, gitdir, array[] of {TreeEntry(8r100644, "f", blob)});
		}
		root := mktree(t, gitdir, array[] of {TreeEntry(mode, names[i], eh)});
		ctext := "tree " + root.hex() + "\nauthor T <t@e> 0 +0000\ncommitter T <t@e> 0 +0000\n\nx\n";
		(ch, cerr) := git->writelooseobj(gitdir, git->OBJ_COMMIT, array of byte ctext);
		t.assertnil(cerr, "commit written");
		t.assertnil(git->writeref(gitdir, headref, ch), "branch moved");
		(ents, lerr) := git->loadindex(gitdir);
		bad := "";
		for(; ents != nil; ents = tl ents) {
			p := (hd ents).path;
			if(p == nil || p[0] == '.' || p[0] == '/' || len p > 2 && p[0:3] == "../")
				bad += sprint(" %q", p);
			for(j := 0; j < len p; j++)
				if(p[j] == '\n')
					bad += sprint(" %q", p);
		}
		t.assertseq(bad, "", sprint("no unsafe path in the index from a tree with %q", names[i]));
		t.assertnotnil(lerr, sprint("the index of a tree with %q is an error", names[i]));
	}
	cleanup(dir);
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

	git = load Git Git->PATH;
	if(git == nil) {
		sys->fprint(sys->fildes(2), "cannot load git module: %r\n");
		raise "fail:cannot load git module";
	}
	err := git->init();
	if(err != nil) {
		sys->fprint(sys->fildes(2), "git init: %s\n", err);
		raise "fail:git init: " + err;
	}

	top = "/tmp/git_hostile_test." + string sys->pctl(0, nil);
	cleanup(top);

	run("RefNames", testRefNames);
	run("TreeNames", testTreeNames);
	run("WriteRefOutside", testWriteRefOutside);
	run("UpdateRefsHostile", testUpdateRefsHostile);
	run("CheckoutHostileTree", testCheckoutHostileTree);
	run("SymbolicRefs", testSymbolicRefs);
	run("IsCleanUnreadable", testIsCleanUnreadable);
	run("IndexFromHostileTree", testIndexFromHostileTree);

	cleanup(top);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
