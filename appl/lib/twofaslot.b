implement Twofaslot;

#
# Twofaslot — per-account second-factor key-slots. See module/twofaslot.m and
# docs/second-factor-auth.md.
#
include "sys.m";
	sys: Sys;
include "dial.m";			# secstore.m references Dial->Connection
include "secstore.m";
	secstore: Secstore;
include "twofa.m";
	twofa: Twofa;
include "keyring.m";			# security.m references Keyring
include "security.m";
	random: Random;
include "twofaslot.m";

Slot: adt {
	path:	string;		# the slot's file
	kind:	string;		# "key" | "recovery"
	cred:	string;		# credential id hex (key slots)
	salt:	string;		# salt hex (key slots)
	wrap:	array of byte;	# encrypt3(DK, KEK)
};

init()
{
	sys = load Sys Sys->PATH;
	secstore = load Secstore Secstore->PATH;
	secstore->init();
	twofa = load Twofa Twofa->PATH;
	twofa->init();
	twofa->mount();			# best-effort; caller may already have bound #h
	random = load Random Random->PATH;
}

# ── helpers ────────────────────────────────────────────────────

eq(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hexc(v: int): int
{
	if(v < 10)
		return v + '0';
	return v - 10 + 'a';
}

tohex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = hexc((int a[i] >> 4) & 16rf);
		s[len s] = hexc(int a[i] & 16rf);
	}
	return s;
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

fromhex(s: string): array of byte
{
	if(s == nil || (len s & 1) != 0)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		hi := hexv(s[2*i]);
		lo := hexv(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte((hi << 4) | lo);
	}
	return a;
}

contains(s, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# ispinerr — the security key rejected the PIN itself (wrong PIN) or the PIN/UV
# factor is locked out. On any of these the SAME PIN will fail on every other
# key slot too, and each attempt decrements the key's hardware retry counter —
# so a 2-slot account would burn two of the eight lifetime PIN tries per login.
# The caller must stop iterating slots the instant it sees one. Deliberately
# excludes NO_CREDENTIALS / INVALID_CREDENTIAL and PIN_REQUIRED (blank PIN on a
# UV slot): those mean "this slot isn't for the present key / this PIN mode",
# where trying the next slot is correct and costs no retry.
ispinerr(e: string): int
{
	return contains(e, "PIN_INVALID") || contains(e, "PIN_AUTH_INVALID") ||
		contains(e, "PIN_BLOCKED") || contains(e, "PIN_AUTH_BLOCKED") ||
		contains(e, "UV_BLOCKED");
}

slotdir(user: string): string
{
	return Slotbase + "/" + user + "/2fa";
}

ensuredir(path: string): int
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return 1;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r700);
	if(fd == nil)
		return 0;
	return 1;
}

readslot(path: string): ref Slot
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := ref Slot(path, "", "", "", nil);
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(l := lines; l != nil; l = tl l){
		(nf, f) := sys->tokenize(hd l, " \t");
		if(nf < 1)
			continue;
		val := "";
		if(nf >= 2)
			val = hd tl f;
		case hd f {
		"kind" =>	s.kind = val;
		"cred" =>	s.cred = val;
		"salt" =>	s.salt = val;
		"wrap" =>	s.wrap = fromhex(val);
		}
	}
	return s;
}

listslots(dir: string): list of ref Slot
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	slots: list of ref Slot;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			if(d[i].mode & Sys->DMDIR)
				continue;
			s := readslot(dir + "/" + d[i].name);
			if(s != nil && s.kind != "")
				slots = s :: slots;
		}
	}
	return slots;
}

# ── public ─────────────────────────────────────────────────────

is2fa(user: string): int
{
	return listslots(slotdir(user)) != nil;
}

# The credential id of the key slot that last unlocked this account. It is a
# plaintext hint (the cred id is already stored in the slot files), used only to
# try the present key's slot first — see frontload/unlock. Absent on first use.
lastgoodpath(user: string): string
{
	return slotdir(user) + "/.lastgood";
}

readlastgood(user: string): string
{
	fd := sys->open(lastgoodpath(user), Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

writelastgood(user, cred: string)
{
	fd := sys->create(lastgoodpath(user), Sys->OWRITE, 8r600);
	if(fd == nil)
		return;			# best-effort hint; a miss just costs one slow login
	b := array of byte (cred + "\n");
	sys->write(fd, b, len b);
}

# Move the key slot whose credential last unlocked to the head of the list, so
# the common case (same physical key every login) tries exactly one slot and
# touches once instead of probing every absent backup credential in turn.
frontload(slots: list of ref Slot, cred: string): list of ref Slot
{
	if(cred == nil || cred == "")
		return slots;
	match: ref Slot;
	for(l := slots; l != nil; l = tl l){
		s := hd l;
		if(s.kind == "key" && s.cred == cred){
			match = s;
			break;
		}
	}
	if(match == nil)
		return slots;		# last-good key no longer enrolled
	# Rebuild original order with the match removed, then prepend it.
	rev: list of ref Slot;
	for(l = slots; l != nil; l = tl l)
		if(hd l != match)
			rev = hd l :: rev;
	ord: list of ref Slot;
	for(l = rev; l != nil; l = tl l)
		ord = hd l :: ord;
	return match :: ord;
}

#
# A slot's file, written again with its data key wrapped under kek
# (verified first, and written beside and renamed): a slot made before
# version 6 of the store (secstore(2)), its key from the old root by
# HMAC-SHA256, is wrapped again under the version 6 root the first time
# it unlocks.  A slot that cannot be written is left as it was, and
# still opens.
#
rewrap(s: ref Slot, DK, kek: array of byte)
{
	wrap := secstore->encrypt3(DK, kek);
	if(wrap == nil || !eq(secstore->decrypt3(wrap, kek, nil, nil), DK))
		return;
	content: array of byte;
	if(s.kind == "key")
		content = array of byte ("kind key\ncred " + s.cred + "\nsalt " + s.salt + "\nwrap " + tohex(wrap) + "\n");
	else
		content = array of byte ("kind recovery\ncred -\nsalt -\nwrap " + tohex(wrap) + "\n");
	tmp := s.path + ".new";
	fd := sys->create(tmp, Sys->OWRITE, 8r600);
	if(fd == nil || sys->write(fd, content, len content) != len content){
		fd = nil;
		sys->remove(tmp);
		return;
	}
	fd = nil;
	d := sys->nulldir;
	(nil, name) := splitpath(s.path);
	d.name = name;
	sys->remove(s.path);
	if(sys->wstat(tmp, d) < 0)
		sys->fprint(sys->fildes(2), "2fa: can't rename %s to %s: %r\n", tmp, s.path);
	else
		sys->fprint(sys->fildes(2), "2fa: slot %s wrapped again under the version 6 root\n", name);
}

splitpath(p: string): (string, string)
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return (p[0:i], p[i+1:]);
	return ("", p);
}

unlock(user: string, c: ref Secstore->Creds, recoverypass, pin: string): (array of byte, string)
{
	stderr := sys->fildes(2);
	tl0 := sys->millisec();
	slots := listslots(slotdir(user));
	if(slots == nil)
		return (nil, "account has no 2fa slots");
	# Try the slot that unlocked last time first — one touch in the common case.
	slots = frontload(slots, readlastgood(user));

	# Try key slots first (needs a present YubiKey + touch).
	# Track the last derive failure so the caller can surface it; silently
	# swallowing here makes a wrong PIN look identical to "no working slot"
	# and the user always ends up at the recovery prompt with no diagnosis.
	lastderr := "";
	si := 0;
	for(l := slots; l != nil; l = tl l){
		s := hd l;
		if(s.kind != "key" || s.wrap == nil)
			continue;
		si++;
		sid := s.cred;
		if(len sid > 8)
			sid = sid[0:8];
		salt := fromhex(s.salt);
		if(salt == nil || len salt != 32){
			lastderr = "bad salt in slot";
			continue;
		}
		# No available() pre-check: it runs a full USB enumeration on top of the
		# one derive() already does, needlessly delaying the touch prompt. derive()
		# returns "no FIDO device present" by itself when the key is absent.
		(R, e) := twofa->derive(s.cred, salt, pin);	# touch (+PIN if UV)
		if(e != nil){
			lastderr = e;
			# A rejected/blocked PIN fails identically on every other slot
			# and each retry costs one of the key's 8 lifetime PIN attempts.
			# Stop now rather than cascade the same bad PIN across slots.
			if(ispinerr(e))
				break;
			continue;
		}
		if(R == nil){
			lastderr = "empty derive result";
			continue;
		}
		kek := secstore->mkkek2fa(c.root6, R);
		DK := secstore->decrypt3(s.wrap, kek, nil, nil);
		if(DK == nil){
			# a slot made before version 6
			DK = secstore->decrypt3(s.wrap, secstore->oldkek2fa(c.root3, R), nil, nil);
			if(DK != nil)
				rewrap(s, DK, kek);
		}
		if(DK != nil){
			writelastgood(user, s.cred);	# try this slot first next time
			sys->fprint(stderr, "2fa: unlocked (slot %s, tried %d, %dms)\n", sid, si, sys->millisec()-tl0);
			return (DK, nil);
		}
		lastderr = "slot wrap did not decrypt with derived key";
	}

	# Recovery passphrase slot (no hardware).
	if(recoverypass != nil && recoverypass != ""){
		for(l = slots; l != nil; l = tl l){
			s := hd l;
			if(s.kind != "recovery" || s.wrap == nil)
				continue;
			kek := secstore->mkfilekey6(user, recoverypass);
			DK := secstore->decrypt3(s.wrap, kek, nil, nil);
			if(DK == nil){
				# a recovery slot made before version 6
				DK = secstore->decrypt3(s.wrap, secstore->mkfilekey3(user, recoverypass), nil, nil);
				if(DK != nil)
					rewrap(s, DK, kek);
			}
			if(DK != nil)
				return (DK, nil);
		}
	}
	if(lastderr != "")
		return (nil, "security key: " + lastderr);
	return (nil, "no slot could unlock (key absent or wrong recovery passphrase)");
}

writeslots(user: string, root6, DK: array of byte, keys: list of (string, string, string), recoverypass, pin: string): string
{
	# Build + verify every slot in memory before touching disk (never-brick).
	recs: list of (string, array of byte);

	for(l := keys; l != nil; l = tl l){
		(name, credhex, salthex) := hd l;
		salt := fromhex(salthex);
		if(salt == nil || len salt != 32)
			return "bad salt for slot " + name;
		(R, e) := twofa->derive(credhex, salt, pin);	# touch (+PIN if UV)
		if(e != nil)
			return "derive " + name + ": " + e;
		kek := secstore->mkkek2fa(root6, R);
		wrap := secstore->encrypt3(DK, kek);
		if(wrap == nil)
			return "wrap " + name + " failed";
		if(!eq(secstore->decrypt3(wrap, kek, nil, nil), DK))
			return "verify " + name + " failed";
		content := "kind key\ncred " + credhex + "\nsalt " + salthex + "\nwrap " + tohex(wrap) + "\n";
		recs = (name, array of byte content) :: recs;
	}

	if(recoverypass != nil && recoverypass != ""){
		kek := secstore->mkfilekey6(user, recoverypass);
		wrap := secstore->encrypt3(DK, kek);
		if(wrap == nil)
			return "wrap recovery failed";
		if(!eq(secstore->decrypt3(wrap, kek, nil, nil), DK))
			return "verify recovery failed";
		content := "kind recovery\ncred -\nsalt -\nwrap " + tohex(wrap) + "\n";
		recs = ("recovery", array of byte content) :: recs;
	}

	if(recs == nil)
		return "no slots requested";

	ensuredir(Slotbase);
	ensuredir(Slotbase + "/" + user);
	dir := slotdir(user);
	if(!ensuredir(dir))
		return sys->sprint("create %s: %r", dir);

	for(r := recs; r != nil; r = tl r){
		(name, content) := hd r;
		path := dir + "/" + name;
		fd := sys->create(path, Sys->OWRITE, 8r600);
		if(fd == nil)
			return sys->sprint("create %s: %r", path);
		if(sys->write(fd, content, len content) != len content)
			return sys->sprint("write %s: %r", path);
	}
	return nil;
}

enroll(user, pass, recoverypass: string, keys: list of (string, string, string), pin: string): string
{
	c := secstore->mkcreds(user, pass);
	err := enroll1(user, c, recoverypass, keys, pin);
	secstore->erasecreds(c);
	return err;
}

enroll1(user: string, c: ref Secstore->Creds, recoverypass: string, keys: list of (string, string, string), pin: string): string
{
	(conn, nil, diag) := secstore->connect6(Addr, c);
	if(conn == nil){
		if(diag != nil)
			return "secstore connect: " + diag;
		return sys->sprint("secstore connect: %r");
	}
	# The account's keys as they are: none yet (the server says it has
	# no such file), or a file that decrypts.  A file that could not
	# be read was taken for none, and the account's new vault was then
	# an empty one, stored over the file that had not been read.
	(file, absent, ferr) := secstore->fetch(conn, "factotum", 0);
	plaintext: array of byte;
	if(absent)
		plaintext = array[0] of byte;
	else if(ferr != nil || len file == 0){
		secstore->bye(conn);
		if(ferr == nil)
			ferr = "the file is empty (damaged)";
		return "cannot read the current factotum: " + ferr;
	}else{
		(plaintext, nil) = secstore->openfile(file, c);
		if(plaintext == nil){
			secstore->bye(conn);
			return "wrong password, or a format only auth/secstore m moves (cannot decrypt current factotum)";
		}
	}

	DK: array of byte;
	{
		DK = random->randombuf(Random->ReallyRandom, 32);
	} exception e {
	"random:*" =>
		secstore->bye(conn);
		return "cannot generate data key: " + e;
	}
	if(DK == nil || len DK != 32){
		secstore->bye(conn);
		return "cannot generate data key";
	}

	# Verify the new blob decrypts under DK before touching anything.
	newfile := secstore->encrypt3(plaintext, DK);
	if(newfile == nil || !eq(secstore->decrypt3(newfile, DK, nil, nil), plaintext)){
		secstore->bye(conn);
		return "re-encrypt verification failed";
	}

	# Write slots first (verify-before-commit inside); only then swap the blob.
	err := writeslots(user, c.root6, DK, keys, recoverypass, pin);
	if(err != nil){
		secstore->bye(conn);
		return "writeslots: " + err;
	}
	if(secstore->putfile(conn, "factotum", newfile) < 0){
		e := sys->sprint("%r");
		removeslots(user);		# rollback: blob unchanged, just drop slots
		secstore->bye(conn);
		return "putfile factotum failed (rolled back): " + e;
	}
	# The vault is under the data key: from here the server changes
	# the account's files only for a session that shows the vault key,
	# and this machine takes no file that is not under the data key.
	err = secstore->enrolvault(conn, secstore->vaultkey(DK));
	secstore->bye(conn);
	if(err != nil)
		return "the vault is stored, but the server did not lock it to the second factor: " + err;
	return markenrolled(user);
}

#
# The states of an account's second factor, on this machine:
#	none		no slots: the password alone
#	enrolling	slots, and no mark yet: the vault may still be under
#			the password (an enrolment that stopped before its
#			last step, or one made before the mark was kept)
#	enrolled	slots and the mark: the vault is under the data key,
#			and a file under the password is not the vault
#	disabling	a disable has begun: the vault may be back under
#			the password, with the slots still there
# Only in the two between is a file under the password alone taken at
# a login (wm/logon).  It was taken whenever it decrypted, so whoever
# had the password could put a vault of their own making in the store
# and have it loaded with no second factor; the server now refuses
# such a store too, once enrolled (secstored(8)).
#
state(user: string): string
{
	if(!is2fa(user))
		return "none";
	(ok, nil) := sys->stat(slotdir(user) + "/.disabling");
	if(ok >= 0)
		return "disabling";
	(ok, nil) = sys->stat(slotdir(user) + "/.enrolled");
	if(ok >= 0)
		return "enrolled";
	return "enrolling";
}

markenrolled(user: string): string
{
	return mark(user, ".enrolled");
}

mark(user, name: string): string
{
	path := slotdir(user) + "/" + name;
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return nil;
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't mark %s: %r", path);
	return nil;
}


addkey(user, pass, recoverypass: string, cred, salthex, newpin: string): string
{
	if(recoverypass == nil || recoverypass == "")
		return "addkey needs the recovery passphrase";
	c := secstore->mkcreds(user, pass);
	(DK, e) := unlock(user, c, recoverypass, "");	# recovery slot (no primary key needed)
	root6 := c.root6;
	if(DK == nil)
		return "cannot unlock with the recovery passphrase: " + e;
	# Unique slot name per credential so a backup never overwrites the primary
	# (or another backup); re-adding the same key is idempotent.
	name := "key-";
	if(len cred >= 16)
		name += cred[0:16];
	else
		name += cred;
	# recoverypass "" => writeslots does not rewrite the recovery slot, and it
	# never deletes existing slots — it only adds this one.
	err := writeslots(user, root6, DK, (name, cred, salthex) :: nil, "", newpin);
	secstore->erasecreds(c);
	return err;
}

removeslots(user: string): string
{
	dir := slotdir(user);
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;			# nothing to remove
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			sys->remove(dir + "/" + d[i].name);
	}
	fd = nil;
	sys->remove(dir);
	return nil;
}

disable(user, pass, recoverypass, pin: string): string
{
	if(!is2fa(user))
		return nil;			# already password-only

	c := secstore->mkcreds(user, pass);
	err := disable1(user, c, recoverypass, pin);
	secstore->erasecreds(c);
	return err;
}

disable1(user: string, c: ref Secstore->Creds, recoverypass, pin: string): string
{
	rootkey := c.root6;
	(DK, e) := unlock(user, c, recoverypass, pin);
	if(DK == nil)
		return "cannot recover data key to disable: " + e;

	(conn, nil, diag) := secstore->connect6(Addr, c);
	if(conn == nil){
		if(diag != nil)
			return "secstore connect: " + diag;
		return sys->sprint("secstore connect: %r");
	}
	# the second factor, shown to the server: it stores nothing for an
	# enrolled account otherwise
	(nil, verr) := secstore->showvault(conn, secstore->vaultkey(DK));
	if(verr != nil){
		secstore->bye(conn);
		return "the server did not take the vault key: " + verr;
	}
	# from here until the slots are gone, a vault under the password
	# is what a login may find
	if((merr := mark(user, ".disabling")) != nil){
		secstore->bye(conn);
		return merr;
	}
	# A file that could not be read is an error: it was "no factotum
	# blob to revert", as an account with none is.  With none there is
	# nothing to put back under the password.
	(file, absent, ferr) := secstore->fetch(conn, "factotum", 0);
	if(!absent){
		if(ferr != nil || len file == 0){
			secstore->bye(conn);
			if(ferr == nil)
				ferr = "the file is empty (damaged)";
			return "cannot read the factotum to revert: " + ferr;
		}
		plaintext := secstore->decrypt3(file, DK, nil, nil);
		if(plaintext == nil)
			# a disable that stopped after its store: already under the password
			(plaintext, nil) = secstore->openfile(file, c);
		if(plaintext == nil){
			secstore->bye(conn);
			return "decrypt factotum with data key failed";
		}
		newfile := secstore->encrypt3(plaintext, rootkey);	# back under password
		if(newfile == nil || !eq(secstore->decrypt3(newfile, rootkey, nil, nil), plaintext)){
			secstore->bye(conn);
			return "re-encrypt to password failed";
		}
		if(secstore->putfile(conn, "factotum", newfile) < 0){
			e = sys->sprint("%r");
			secstore->bye(conn);
			return "putfile factotum failed: " + e;
		}
	}
	verr = secstore->unenrolvault(conn);
	secstore->bye(conn);
	if(verr != nil)
		return "the vault is under the password again, but the server still asks for the second factor: " + verr;
	return removeslots(user);
}
