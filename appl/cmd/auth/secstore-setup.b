implement SecstoreSetup;

#
# secstore-setup - Create secstore user accounts
#
# Prompts for a username and password, computes the PAK verifier,
# and stores it in the secstore directory.  Optionally imports
# current factotum keys into the new secstore account.
#
# Usage:
#   auth/secstore-setup [-s storedir] [-u user] [-i] [-V secstore|secstore3]
#
# Options:
#   -s storedir   secstore data directory (default: /usr/inferno/secstore)
#   -u user       username (default: current user from /dev/user)
#   -i            import current factotum keys into secstore
#   -V version    PAK verifier version (default: secstore3)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "secstore.m";
	secstore: Secstore;

include "arg.m";

SecstoreSetup: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

storedir := "/usr/inferno/secstore";
stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	secstore = load Secstore Secstore->PATH;
	stderr = sys->fildes(2);

	if(secstore == nil)
		fatal("cannot load required modules");

	secstore->init();

	user := readfile("/dev/user");
	force := 0;
	pass: string;
	version := "secstore4";

	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("auth/secstore-setup [-f] [-k password] [-s storedir] [-u user] [-V secstore|secstore3|secstore4]");
		while((o := arg->opt()) != 0)
			case o {
			'f' =>	force = 1;
			'i' =>
				# It wrote a file "factotum" made of what a read
				# of factotum's ctl gives, which has no secrets
				# in it and is not in the form logon loads: an
				# import of nothing, said to have worked.
				fatal("-i is gone: factotum gives no secrets to be read; it saves its own keys once it is told the account (auth/factotum -S, or a login)");
			'k' =>
				pass = arg->earg();
				sys->fprint(stderr, "secstore-setup: warning: a password given with -k can be read by other programs (in /prog); it is for tests\n");
			's' =>	storedir = arg->earg();
			'u' =>	user = arg->earg();
			'V' =>	version = arg->earg();
			* =>	arg->usage();
			}
	}

	if(user == nil || user == "")
		fatal("no username");
	# the name is a directory in the store, as the server takes it
	if(user == "." || user == ".." || hasslash(user))
		fatal("user name cannot be a path: " + user);
	if(version != "secstore" && version != "secstore3" && version != "secstore4")
		fatal("unsupported verifier version");
	if(version != "secstore4")
		sys->fprint(stderr, "secstore-setup: warning: a %s account is one to be moved: its first login makes it secstore4\n", version);

	sys->fprint(stderr, "secstore setup for user: %s\n", user);
	sys->fprint(stderr, "store directory: %s\n", storedir);

	# An account that is there is not written over: its verifier was
	# replaced without a word, and its files, under the old password,
	# were then beyond the account's reach.
	userdir := storedir + "/" + user;
	pakpath := userdir + "/PAK";
	(pok, nil) := sys->stat(pakpath);
	if(pok >= 0 && !force)
		fatal(sys->sprint("the account %s exists (%s): -f replaces its verifier; its files stay under the old password", user, pakpath));

	# Prompt for password if not provided via -k
	if(pass == nil || pass == "") {
		pass = promptpassword("secstore password: ");
		if(pass == nil || pass == "")
			fatal("no password");
		pass2 := promptpassword("confirm password: ");
		if(pass2 != pass)
			fatal("passwords don't match");
	}
	# SP 800-63B 5.1.1.2: a memorized secret is at least 8 characters;
	# the store may be read by whoever takes the disk, and is guessed
	# at offline from then on
	if(len pass < Minpass)
		fatal(sys->sprint("the password must be at least %d characters", Minpass));

	# Compute the PAK verifier: only the hash its version takes
	pwhash: array of byte;
	case version {
	"secstore" =>
		pwhash = secstore->mkseckey(pass);
	"secstore3" =>
		pwhash = secstore->mkseckey2(pass);
	* =>
		root := secstore->mkfilekey3(user, pass);
		pwhash = secstore->mkseckey4(root);
		secstore->erasekey(root);
	}
	hexHi := secstore->mkverifier(user, version, pwhash);
	secstore->erasekey(pwhash);
	if(hexHi == nil)
		fatal("can't make the verifier");

	# Create user directory.  Each must be a directory when this is
	# done: one that could not be made, with a file of that name in
	# its place, was not noticed.
	sys->create(storedir, Sys->OREAD, Sys->DMDIR | 8r700);
	(sok, sd) := sys->stat(storedir);
	if(sok < 0 || (sd.mode & Sys->DMDIR) == 0)
		fatal(sys->sprint("can't make the directory %s: %r", storedir));
	sys->create(userdir, Sys->OREAD, Sys->DMDIR | 8r700);
	(dok, dd) := sys->stat(userdir);
	if(dok < 0 || (dd.mode & Sys->DMDIR) == 0)
		fatal(sys->sprint("can't make the directory %s: %r", userdir));

	# Write verifier: all of it, or no account.  The write's result was
	# not looked at, and "setup complete" was printed over a verifier cut
	# short, which is an account nobody can log in to.  It is written
	# beside the old one and renamed, so a stop leaves one of them.
	tmp := userdir + "/.new.PAK";
	sys->remove(tmp);
	fd := sys->create(tmp, Sys->OWRITE|Sys->OEXCL, 8r600);
	if(fd == nil)
		fatal(sys->sprint("can't create %s: %r", tmp));
	b := array of byte (secstore->formatverifier(version, hexHi) + "\n");
	if(sys->write(fd, b, len b) != len b){
		e := sys->sprint("can't write %s: %r", tmp);
		fd = nil;
		sys->remove(tmp);
		fatal(e);
	}
	fd = nil;
	nd := sys->nulldir;
	nd.name = "PAK";
	if(sys->wstat(tmp, nd) < 0){
		sys->remove(pakpath);
		if(sys->wstat(tmp, nd) < 0){
			e := sys->sprint("can't rename %s to PAK: %r", tmp);
			sys->remove(tmp);
			fatal(e);
		}
	}

	sys->fprint(stderr, "PAK verifier stored in %s\n", pakpath);
	sys->fprint(stderr, "setup complete\n");
}

Minpass: con 8;

promptpassword(prompt: string): string
{
	sys->fprint(stderr, "%s", prompt);

	consctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(consctl == nil || sys->fprint(consctl, "rawon") < 0)
		sys->fprint(stderr, "secstore-setup: warning: cannot hide the typed password\n");

	fd := sys->open("/dev/cons", Sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[256] of byte;
	pass := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s := string buf[0:n];
		for(i := 0; i < len s; i++){
			case s[i] {
			'\n' =>
				if(consctl != nil)
					sys->fprint(consctl, "rawoff");
				sys->fprint(stderr, "\n");
				return pass;
			'\r' =>
				;
			'\b' or 16r7f =>
				# raw mode edits nothing: a backspace was a
				# character of the password
				if(len pass > 0)
					pass = pass[0:len pass-1];
			16r15 =>
				pass = "";
			* =>
				pass[len pass] = s[i];
			}
		}
	}

	if(consctl != nil)
		sys->fprint(consctl, "rawoff");
	sys->fprint(stderr, "\n");
	if(len pass > 0)
		return pass;
	return nil;
}

hasslash(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 1;
	return 0;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	all := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}
	# Strip trailing newline
	while(len all > 0 && all[len all-1] == '\n')
		all = all[:len all-1];
	return all;
}

fatal(s: string)
{
	sys->fprint(stderr, "secstore-setup: %s\n", s);
	raise "fail:error";
}
