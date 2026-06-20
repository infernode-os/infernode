implement Twofaslot;

#
# Twofaslot — per-account second-factor key-slots. See module/twofaslot.m and
# doc/second-factor-auth.md.
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
	twofa->mount();			# best-effort; caller may already have bound #F
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
	s := ref Slot("", "", "", nil);
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

unlock(user: string, rootkey: array of byte, recoverypass, pin: string): (array of byte, string)
{
	slots := listslots(slotdir(user));
	if(slots == nil)
		return (nil, "account has no 2fa slots");

	# Try key slots first (needs a present YubiKey + touch).
	for(l := slots; l != nil; l = tl l){
		s := hd l;
		if(s.kind != "key" || s.wrap == nil)
			continue;
		if(!twofa->available())
			continue;
		salt := fromhex(s.salt);
		if(salt == nil || len salt != 32)
			continue;
		(R, e) := twofa->derive(s.cred, salt, pin);	# touch (+PIN if UV)
		if(e != nil || R == nil)
			continue;
		kek := secstore->mkkek2fa(rootkey, R);
		DK := secstore->decrypt3(s.wrap, kek, nil, nil);
		if(DK != nil)
			return (DK, nil);
	}

	# Recovery passphrase slot (no hardware).
	if(recoverypass != nil && recoverypass != ""){
		for(l = slots; l != nil; l = tl l){
			s := hd l;
			if(s.kind != "recovery" || s.wrap == nil)
				continue;
			kek := secstore->mkfilekey3(user, recoverypass);
			DK := secstore->decrypt3(s.wrap, kek, nil, nil);
			if(DK != nil)
				return (DK, nil);
		}
	}
	return (nil, "no slot could unlock (key absent or wrong recovery passphrase)");
}

writeslots(user: string, rootkey, DK: array of byte, keys: list of (string, string, string), recoverypass, pin: string): string
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
		kek := secstore->mkkek2fa(rootkey, R);
		wrap := secstore->encrypt3(DK, kek);
		if(wrap == nil)
			return "wrap " + name + " failed";
		if(!eq(secstore->decrypt3(wrap, kek, nil, nil), DK))
			return "verify " + name + " failed";
		content := "kind key\ncred " + credhex + "\nsalt " + salthex + "\nwrap " + tohex(wrap) + "\n";
		recs = (name, array of byte content) :: recs;
	}

	if(recoverypass != nil && recoverypass != ""){
		kek := secstore->mkfilekey3(user, recoverypass);
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
	rootkey := secstore->mkfilekey3(user, pass);
	filekey := secstore->mkfilekey2(pass);
	legacykey := secstore->mkfilekey(pass);
	pwhash := secstore->mkseckey(pass);
	pwhash2 := secstore->mkseckey2(pass);

	(conn, nil, diag) := secstore->connect2(Addr, user, pwhash, pwhash2);
	if(conn == nil){
		if(diag != nil)
			return "secstore connect: " + diag;
		return sys->sprint("secstore connect: %r");
	}

	file := secstore->getfile(conn, "factotum", 0);
	plaintext: array of byte;
	if(file != nil){
		plaintext = secstore->decrypt3(file, rootkey, filekey, legacykey);
		if(plaintext == nil){
			secstore->bye(conn);
			return "wrong password (cannot decrypt current factotum)";
		}
	}else
		plaintext = array[0] of byte;

	# Fresh data key; re-encrypt the blob under it and verify it round-trips.
	DK := random->randombuf(Random->ReallyRandom, 32);
	if(DK == nil || len DK != 32){
		secstore->bye(conn);
		return "cannot generate data key";
	}
	newfile := secstore->encrypt3(plaintext, DK);
	if(newfile == nil || !eq(secstore->decrypt3(newfile, DK, nil, nil), plaintext)){
		secstore->bye(conn);
		return "re-encrypt verification failed";
	}

	# Write + verify all slots BEFORE replacing the blob (touch per key slot).
	err := writeslots(user, rootkey, DK, keys, recoverypass, pin);
	if(err != nil){
		secstore->bye(conn);
		return "writeslots: " + err;
	}

	# Commit: swap the factotum blob for the DK-encrypted version.
	if(secstore->putfile(conn, "factotum", newfile) < 0){
		removeslots(user);		# rollback: blob unchanged, just drop slots
		secstore->bye(conn);
		return sys->sprint("putfile factotum failed (rolled back): %r");
	}
	secstore->bye(conn);
	return nil;
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

	rootkey := secstore->mkfilekey3(user, pass);
	(DK, e) := unlock(user, rootkey, recoverypass, pin);
	if(DK == nil)
		return "cannot recover data key to disable: " + e;

	pwhash := secstore->mkseckey(pass);
	pwhash2 := secstore->mkseckey2(pass);
	(conn, nil, diag) := secstore->connect2(Addr, user, pwhash, pwhash2);
	if(conn == nil){
		if(diag != nil)
			return "secstore connect: " + diag;
		return sys->sprint("secstore connect: %r");
	}
	file := secstore->getfile(conn, "factotum", 0);
	if(file == nil){
		secstore->bye(conn);
		return "no factotum blob to revert";
	}
	plaintext := secstore->decrypt3(file, DK, nil, nil);
	if(plaintext == nil){
		secstore->bye(conn);
		return "decrypt factotum with data key failed";
	}
	newfile := secstore->encrypt3(plaintext, rootkey);	# back under password
	if(newfile == nil || !eq(secstore->decrypt3(newfile, rootkey, nil, nil), plaintext)){
		secstore->bye(conn);
		return "re-encrypt to password failed";
	}
	# Commit password blob first; logon's cross-fallback covers the brief window
	# where slots still exist but the blob is already password-encrypted.
	if(secstore->putfile(conn, "factotum", newfile) < 0){
		secstore->bye(conn);
		return sys->sprint("putfile factotum failed: %r");
	}
	secstore->bye(conn);
	return removeslots(user);
}
