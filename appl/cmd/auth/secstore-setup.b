implement SecstoreSetup;

#
# secstore-setup - Create secstore user accounts
#
# Prompts for a username and password, computes the PAK verifier,
# and stores it in the secstore directory.  Optionally imports
# current factotum keys into the new secstore account.
#
# Usage:
#   auth/secstore-setup [-s storedir] [-u user] [-i] [-V secstore|secstore2]
#
# Options:
#   -s storedir   secstore data directory (default: /usr/inferno/secstore)
#   -u user       username (default: current user from /dev/user)
#   -i            import current factotum keys into secstore
#   -V version    PAK verifier version (default: secstore2)
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
	importkeys := 0;
	pass: string;
	version := "secstore2";

	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("auth/secstore-setup [-i] [-k password] [-s storedir] [-u user] [-V secstore|secstore2]");
		while((o := arg->opt()) != 0)
			case o {
			'i' =>	importkeys = 1;
			'k' =>	pass = arg->earg();
			's' =>	storedir = arg->earg();
			'u' =>	user = arg->earg();
			'V' =>	version = arg->earg();
			* =>	arg->usage();
			}
	}

	if(user == nil || user == "")
		fatal("no username");

	sys->fprint(stderr, "secstore setup for user: %s\n", user);
	sys->fprint(stderr, "store directory: %s\n", storedir);

	# Prompt for password if not provided via -k
	if(pass == nil || pass == "") {
		pass = promptpassword("secstore password: ");
		if(pass == nil || pass == "")
			fatal("no password");
		pass2 := promptpassword("confirm password: ");
		if(pass2 != pass)
			fatal("passwords don't match");
	}

	if(version != "secstore" && version != "secstore2")
		fatal("unsupported verifier version");

	# Compute PAK verifier
	pwhash := secstore->mkseckey(pass);
	if(version == "secstore2"){
		secstore->erasekey(pwhash);
		pwhash = secstore->mkseckey2(pass);
	}
	hexHi := secstore->mkverifier(user, version, pwhash);
	secstore->erasekey(pwhash);

	# Create user directory
	userdir := storedir + "/" + user;
	sys->create(storedir, Sys->OREAD, Sys->DMDIR | 8r700);
	sys->create(userdir, Sys->OREAD, Sys->DMDIR | 8r700);

	# Write verifier
	pakpath := userdir + "/PAK";
	fd := sys->create(pakpath, Sys->OWRITE, 8r600);
	if(fd == nil)
		fatal(sys->sprint("can't create %s: %r", pakpath));
	b := array of byte secstore->formatverifier(version, hexHi);
	sys->write(fd, b, len b);
	fd = nil;

	sys->fprint(stderr, "PAK verifier stored in %s\n", pakpath);

	# Optionally import factotum keys
	if(importkeys){
		keys := readfile("/mnt/factotum/ctl");
		if(keys == nil || keys == ""){
			sys->fprint(stderr, "no keys in factotum to import\n");
		} else {
			# Encrypt with modern AES-GCM file key
			filekey := secstore->mkfilekey3(user, pass);
			plaintext := array of byte keys;
			encrypted := secstore->encrypt3(plaintext, filekey);
			secstore->erasekey(filekey);
			secstore->erasekey(plaintext);

			if(encrypted == nil)
				fatal("encryption failed");

			fpath := userdir + "/factotum";
			fd = sys->create(fpath, Sys->OWRITE, 8r600);
			if(fd == nil)
				fatal(sys->sprint("can't create %s: %r", fpath));
			sys->write(fd, encrypted, len encrypted);
			fd = nil;
			sys->fprint(stderr, "imported factotum keys to %s\n", fpath);
		}
	}

	sys->fprint(stderr, "setup complete\n");
}

promptpassword(prompt: string): string
{
	sys->fprint(stderr, "%s", prompt);

	consctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(consctl != nil)
		sys->fprint(consctl, "rawon");

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
			if(s[i] == '\n' || s[i] == '\r'){
				if(consctl != nil)
					sys->fprint(consctl, "rawoff");
				sys->fprint(stderr, "\n");
				return pass;
			}
			pass[len pass] = s[i];
		}
	}

	if(consctl != nil)
		sys->fprint(consctl, "rawoff");
	sys->fprint(stderr, "\n");
	if(len pass > 0)
		return pass;
	return nil;
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
