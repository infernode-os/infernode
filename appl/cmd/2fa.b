implement Cmd2fa;

#
# 2fa — enroll / manage YubiKey-gated secstore login (the strong, key-slot mode).
# See doc/second-factor-auth.md. Run after a normal login (secstored up).
#
#   2fa status     show whether this account is 2FA + whether a key is present
#   2fa enroll     bind the present security key + a recovery passphrase (strong:
#                  login then needs the key, or the recovery passphrase)
#   2fa disable    revert this account to password-only
#
# Single key + recovery for now; a second (backup) key and a Settings GUI are
# thin wrappers over twofaslot->enroll. The recovery passphrase is the
# anti-lockout net — store it in your vault.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
include "keyring.m";
include "security.m";
	random: Random;
include "secstore.m";
include "twofa.m";
	twofa: Twofa;
include "twofaslot.m";
	ts: Twofaslot;

Cmd2fa: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

prompt(msg: string): string
{
	sys->print("%s", msg);
	buf := array[512] of byte;
	n := sys->read(sys->fildes(0), buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	return s;
}

tohex(a: array of byte): string
{
	h := "0123456789abcdef";
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = h[(int a[i] >> 4) & 16rf];
		s[len s] = h[int a[i] & 16rf];
	}
	return s;
}

rf(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	while(n > 0 && (buf[n-1] == byte '\n' || buf[n-1] == byte ' '))
		n--;
	return string buf[0:n];
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	random = load Random Random->PATH;
	twofa = load Twofa Twofa->PATH;
	ts = load Twofaslot Twofaslot->PATH;
	if(ts == nil || twofa == nil){
		sys->fprint(stderr, "2fa: cannot load modules: %r\n");
		return;
	}
	twofa->init();
	ts->init();

	user := rf("/dev/user");
	if(user == nil)
		user = "inferno";

	cmd := "status";
	if(tl argv != nil)
		cmd = hd tl argv;

	case cmd {
	"status" =>
		sys->print("account %s: 2fa-enrolled=%d  key-present=%d\n",
			user, ts->is2fa(user), twofa->available());
	"disable" =>
		dpass := prompt("secstore password: ");
		drec := prompt("recovery passphrase (blank if the key is present): ");
		dpin := prompt("FIDO2 PIN (blank for touch-only): ");
		e := ts->disable(user, dpass, drec, dpin);
		if(e == nil)
			sys->print("2fa disabled for %s (password-only)\n", user);
		else
			sys->fprint(stderr, "2fa disable: %s\n", e);
	"enroll" =>
		doenroll(user);
	* =>
		sys->fprint(stderr, "usage: 2fa [status|enroll|disable]\n");
	}
}

doenroll(user: string)
{
	if(!twofa->available()){
		sys->fprint(stderr, "2fa: no security key present — insert your YubiKey first\n");
		return;
	}
	pass := prompt("secstore password: ");
	if(pass == ""){
		sys->fprint(stderr, "2fa: password required\n");
		return;
	}
	recpass := prompt("recovery passphrase (anti-lockout, store in vault): ");
	if(recpass == ""){
		sys->fprint(stderr, "2fa: recovery passphrase required\n");
		return;
	}
	fidopin := prompt("FIDO2 PIN (UV / AAL3; blank = touch-only): ");

	sys->print("Creating a credential on the present key — touch it when it blinks...\n");
	(cred, ce) := twofa->enroll(fidopin);
	if(ce != nil){
		sys->fprint(stderr, "2fa: enroll credential failed: %s\n", ce);
		return;
	}
	salt := random->randombuf(Random->ReallyRandom, 32);
	if(salt == nil || len salt != 32){
		sys->fprint(stderr, "2fa: cannot generate salt\n");
		return;
	}
	keys: list of (string, string, string);
	keys = ("key", cred, tohex(salt)) :: nil;

	sys->print("Binding the key and writing slots — touch the key again...\n");
	err := ts->enroll(user, pass, recpass, keys, fidopin);
	if(err != nil){
		sys->fprint(stderr, "2fa: enroll failed: %s\n", err);
		return;
	}
	sys->print("2FA enrolled for %s. Login now requires this key (or the recovery passphrase).\n", user);
}
