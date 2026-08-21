implement Wallet;

#
# Wallet library: account management with factotum-backed key storage.
#
# Keys are stored in factotum as:
#   key proto=pass service=wallet-eth-{name} user=key !password={hex-privkey}
#   key proto=pass service=wallet-sol-{name} user=key !password={hex-ed25519-seed}
#   key proto=pass service=wallet-stripe-{name} user=key !password={stripe-secret-key}
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;

include "factotum.m";
	factotum: Factotum;

include "lock.m";
	lock: Lock;
	Semaphore: import lock;

include "ethcrypto.m";
	ethcrypto: Ethcrypto;

include "wallet.m";

# Per-account budget storage (in-memory, keyed by account name)
budgets: list of (string, ref Budget);
feebudgets: list of (string, ref FeeBudget);
budgetsema: ref Semaphore;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "cannot load Keyring";
	ethcrypto = load Ethcrypto Ethcrypto->PATH;
	if(ethcrypto == nil)
		return "cannot load Ethcrypto";
	err := ethcrypto->init();
	if(err != nil)
		return "ethcrypto: " + err;
	factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		return "cannot load Factotum";
	factotum->init();
	lock = load Lock Lock->PATH;
	if(lock == nil)
		return "cannot load Lock";
	budgetsema = Semaphore.new();
	return nil;
}

#
# Create a new account: generate keys, store in factotum, return Account.
#
createaccount(name: string, accttype: int, chain: string): (ref Account, string)
{
	if(!validname(name))
		return (nil, "invalid account name (use a-z A-Z 0-9 - _ .)");
	if(!validname(chain))
		return (nil, "invalid chain name");

	if(accttype == ACCT_ETH) {
		(priv, pub) := kr->secp256k1_keygen();
		if(priv == nil || pub == nil)
			return (nil, "key generation failed");

		addr := ethcrypto->pubkeytoaddr(pub);
		if(addr == nil) {
			zeroarray(priv);
			return (nil, "address derivation failed");
		}

		err := storekey(name, accttype, priv, chain);
		if(err != nil) {
			zeroarray(priv);
			return (nil, err);
		}
		addrstr := ethcrypto->addrtostr(addr);
		zeroarray(priv);
		return (ref Account(name, accttype, chain, addrstr), nil);
	}

	if(accttype == ACCT_SOL) {
		# Solana uses Ed25519 — 32-byte seed
		seed := array[32] of byte;
		if(randread(seed) < 0)
			return (nil, "no entropy source for key generation");
		err := storekey(name, accttype, seed, chain);
		if(err != nil) {
			zeroarray(seed);
			return (nil, err);
		}
		zeroarray(seed);
		return (ref Account(name, accttype, chain, ""), nil);
	}

	if(accttype == ACCT_STRIPE)
		return (nil, "use importaccount for Stripe (API key required)");

	return (nil, "unknown account type");
}

#
# Import an existing account with a known private key.
#
importaccount(name: string, accttype: int, chain: string, privkey: array of byte): (ref Account, string)
{
	if(!validname(name))
		return (nil, "invalid account name (use a-z A-Z 0-9 - _ .)");
	if(!validname(chain))
		return (nil, "invalid chain name");
	if(privkey == nil || len privkey == 0)
		return (nil, "empty private key");

	addrstr := "";

	if(accttype == ACCT_ETH) {
		if(len privkey != 32)
			return (nil, "ETH private key must be 32 bytes");
		# secp256k1_pubkey validates 0 < key < n and returns nil otherwise
		pub := kr->secp256k1_pubkey(privkey);
		if(pub == nil)
			return (nil, "invalid private key (zero or out of curve order range)");
		addr := ethcrypto->pubkeytoaddr(pub);
		if(addr == nil)
			return (nil, "address derivation failed");
		addrstr = ethcrypto->addrtostr(addr);
	} else if(accttype == ACCT_SOL) {
		if(len privkey != 32)
			return (nil, "Solana seed must be 32 bytes");
	} else if(accttype == ACCT_STRIPE) {
		addrstr = "stripe:" + name;
	} else
		return (nil, "unknown account type");

	err := storekey(name, accttype, privkey, chain);
	if(err != nil)
		return (nil, err);

	return (ref Account(name, accttype, chain, addrstr), nil);
}

#
# Load an account from factotum (verify key exists, derive address).
#
loadaccount(name: string): (ref Account, string)
{
	if(name == nil || name == "")
		return (nil, "empty account name");

	# Try each account type
	for(atype := ACCT_ETH; atype <= ACCT_STRIPE; atype++) {
		svc := servicekey(name, atype);
		(nil, password) := factotum->getuserpasswd("proto=pass service=" + svc);
		if(password != nil && password != "") {
			chain := storedchain(svc);
			addrstr := "";
			if(atype == ACCT_ETH) {
				if(chain == "")
					chain = "ethereum";
				privkey := ethcrypto->hexdecode(password);
				if(privkey != nil && len privkey == 32) {
					pub := kr->secp256k1_pubkey(privkey);
					if(pub == nil) {
						zeroarray(privkey);
						return (nil, "stored key for " + name + " is invalid");
					}
					addr := ethcrypto->pubkeytoaddr(pub);
					if(addr != nil)
						addrstr = ethcrypto->addrtostr(addr);
					zeroarray(privkey);
				} else {
					zeroarray(privkey);
					return (nil, "stored key for " + name + " is malformed");
				}
			} else if(atype == ACCT_SOL) {
				if(chain == "")
					chain = "solana";
			} else if(atype == ACCT_STRIPE) {
				chain = "stripe";
				addrstr = "stripe:" + name;
			}
			return (ref Account(name, atype, chain, addrstr), nil);
		}
	}
	return (nil, "account not found: " + name);
}

#
# Read the chain= attribute stored alongside a wallet key in factotum.
# Returns "" if not recorded (pre-existing keys).
#
storedchain(svc: string): string
{
	fd := sys->open("/mnt/factotum/ctl", Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[8192] of byte;
	all := "";
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}
	(nil, lines) := sys->tokenize(all, "\n");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(findattr(line, "service") == svc) {
			c := findattr(line, "chain");
			if(c != nil && validname(c))
				return c;
			return "";
		}
	}
	return "";
}

#
# List all wallet accounts from factotum.
#
listaccounts(): list of ref Account
{
	accounts: list of ref Account;

	fd := sys->open("/mnt/factotum/ctl", Sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[8192] of byte;
	all := "";
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}

	# Parse lines looking for service=wallet-*
	line := "";
	for(i := 0; i < len all; i++) {
		if(all[i] == '\n') {
			acct := parsefactotumline(line);
			if(acct != nil)
				accounts = acct :: accounts;
			line = "";
		} else
			line[len line] = all[i];
	}
	if(line != "") {
		acct := parsefactotumline(line);
		if(acct != nil)
			accounts = acct :: accounts;
	}

	return accounts;
}

parsefactotumline(line: string): ref Account
{
	svc := findattr(line, "service");
	if(svc == nil || len svc < 12)
		return nil;

	if(svc[0:7] != "wallet-")
		return nil;

	rest := svc[7:];
	atype := -1;
	name := "";

	if(len rest > 4 && rest[0:4] == "eth-") {
		atype = ACCT_ETH;
		name = rest[4:];
	} else if(len rest > 4 && rest[0:4] == "sol-") {
		atype = ACCT_SOL;
		name = rest[4:];
	} else if(len rest > 7 && rest[0:7] == "stripe-") {
		atype = ACCT_STRIPE;
		name = rest[7:];
	}

	if(atype < 0)
		return nil;
	if(!validname(name)) {
		# A wallet key exists but its name can't be exposed through
		# the 9P tree — warn rather than silently hiding the account
		# (and whatever funds sit behind it).
		sys->fprint(sys->fildes(2),
			"wallet: skipping factotum key service=%s: unsupported account name (allowed: a-z A-Z 0-9 - _ .)\n", svc);
		return nil;
	}

	chain := findattr(line, "chain");
	if(chain == nil || !validname(chain)) {
		chain = "";
		if(atype == ACCT_ETH)
			chain = "ethereum";
		else if(atype == ACCT_SOL)
			chain = "solana";
		else if(atype == ACCT_STRIPE)
			chain = "stripe";
	}

	return ref Account(name, atype, chain, "");
}

findattr(line: string, attr: string): string
{
	target := attr + "=";
	for(i := 0; i <= len line - len target; i++) {
		if(line[i:i+len target] == target) {
			start := i + len target;
			end := start;
			while(end < len line && line[end] != ' ' && line[end] != '\t')
				end++;
			return line[start:end];
		}
	}
	return nil;
}

#
# Sign a hash using the account's private key.
#
signhash(acct: ref Account, hash: array of byte): (array of byte, string)
{
	if(acct == nil)
		return (nil, "nil account");
	if(hash == nil || len hash == 0)
		return (nil, "empty hash");

	svc := servicekey(acct.name, acct.accttype);
	(nil, password) := factotum->getuserpasswd("proto=pass service=" + svc);
	if(password == nil || password == "")
		return (nil, "no key in factotum for " + acct.name);

	if(acct.accttype == ACCT_ETH) {
		privkey := ethcrypto->hexdecode(password);
		if(privkey == nil || len privkey != 32) {
			zeroarray(privkey);
			return (nil, "invalid key in factotum");
		}
		sig := kr->secp256k1_sign(privkey, hash);
		zeroarray(privkey);
		if(sig == nil)
			return (nil, "signing failed");
		return (sig, nil);
	}

	if(acct.accttype == ACCT_SOL) {
		seed := ethcrypto->hexdecode(password);
		if(seed == nil || len seed != 32) {
			zeroarray(seed);
			return (nil, "invalid key in factotum");
		}
		sig := kr->ed25519_sign(seed, hash);
		zeroarray(seed);
		if(sig == nil)
			return (nil, "signing failed");
		return (sig, nil);
	}

	if(acct.accttype == ACCT_STRIPE)
		return (nil, "Stripe accounts don't sign hashes");

	return (nil, "unknown account type");
}

#
# Budget enforcement
#

setbudget(acct: ref Account, b: ref Budget)
{
	if(acct == nil || b == nil)
		return;
	newlist: list of (string, ref Budget);
	for(l := budgets; l != nil; l = tl l) {
		(bname, nil) := hd l;
		if(bname != acct.name)
			newlist = hd l :: newlist;
	}
	budgets = (acct.name, b) :: newlist;
}

checkbudget(acct: ref Account, amount: array of byte): string
{
	if(acct == nil)
		return "nil account";
	if(amount == nil)
		return "nil amount";

	b := getbudget(acct.name);
	if(b == nil)
		return nil;

	# a zero/empty limit means "no limit" for that dimension
	if(ethcrypto->becmp(b.maxpertx, nil) > 0 &&
	   ethcrypto->becmp(amount, b.maxpertx) > 0)
		return sys->sprint("amount %s exceeds per-tx limit %s %s",
			ethcrypto->betodec(amount), ethcrypto->betodec(b.maxpertx),
			b.currency);

	if(ethcrypto->becmp(b.maxpersess, nil) > 0) {
		total := ethcrypto->beadd(b.spent, amount);
		if(total == nil)
			return "session total would overflow uint256";
		if(ethcrypto->becmp(total, b.maxpersess) > 0)
			return sys->sprint("amount %s would exceed session limit %s %s (spent: %s)",
				ethcrypto->betodec(amount),
				ethcrypto->betodec(b.maxpersess), b.currency,
				ethcrypto->betodec(b.spent));
	}

	return nil;
}

recordspend(acct: ref Account, amount: array of byte)
{
	if(acct == nil || amount == nil)
		return;
	b := getbudget(acct.name);
	if(b == nil)
		return;
	total := ethcrypto->beadd(b.spent, amount);
	if(total != nil)
		b.spent = total;
}

reserve(acct: ref Account, amount: array of byte): string
{
	budgetsema.obtain();
	err := checkbudget(acct, amount);
	if(err != nil) {
		budgetsema.release();
		return err;
	}
	b := getbudget(acct.name);
	if(b == nil) {
		budgetsema.release();
		return nil;
	}
	total := ethcrypto->beadd(b.spent, amount);
	if(total == nil) {
		budgetsema.release();
		return "session total would overflow uint256";
	}
	b.spent = total;
	budgetsema.release();
	return nil;
}

budgetfor(acct: ref Account): ref Budget
{
	if(acct == nil)
		return nil;
	return getbudget(acct.name);
}

setfeebudget(acct: ref Account, b: ref FeeBudget)
{
	if(acct == nil || b == nil)
		return;
	newlist: list of (string, ref FeeBudget);
	for(l := feebudgets; l != nil; l = tl l) {
		(bname, nil) := hd l;
		if(bname != acct.name)
			newlist = hd l :: newlist;
	}
	feebudgets = (acct.name, b) :: newlist;
}

checkfee(acct: ref Account, amount: array of byte): string
{
	if(acct == nil)
		return "nil account";
	if(amount == nil)
		return "nil fee";
	b := getfeebudget(acct.name);
	if(b == nil)
		return "no ETH fee budget configured";
	if(ethcrypto->becmp(b.maxpertx, nil) > 0 &&
	   ethcrypto->becmp(amount, b.maxpertx) > 0)
		return sys->sprint("fee %s exceeds per-tx fee limit %s ETH wei",
			ethcrypto->betodec(amount), ethcrypto->betodec(b.maxpertx));
	if(ethcrypto->becmp(b.maxpersess, nil) > 0) {
		total := ethcrypto->beadd(b.spent, amount);
		if(total == nil)
			return "fee session total would overflow uint256";
		if(ethcrypto->becmp(total, b.maxpersess) > 0)
			return sys->sprint("fee %s would exceed session fee limit %s ETH wei (spent: %s)",
				ethcrypto->betodec(amount), ethcrypto->betodec(b.maxpersess),
				ethcrypto->betodec(b.spent));
	}
	return nil;
}

reservefee(acct: ref Account, amount: array of byte): string
{
	budgetsema.obtain();
	err := checkfee(acct, amount);
	if(err != nil) {
		budgetsema.release();
		return err;
	}
	b := getfeebudget(acct.name);
	total := ethcrypto->beadd(b.spent, amount);
	if(total == nil) {
		budgetsema.release();
		return "fee session total would overflow uint256";
	}
	b.spent = total;
	budgetsema.release();
	return nil;
}

feebudgetfor(acct: ref Account): ref FeeBudget
{
	if(acct == nil)
		return nil;
	return getfeebudget(acct.name);
}

getfeebudget(name: string): ref FeeBudget
{
	for(l := feebudgets; l != nil; l = tl l) {
		(n, b) := hd l;
		if(n == name)
			return b;
	}
	return nil;
}

getbudget(name: string): ref Budget
{
	for(l := budgets; l != nil; l = tl l) {
		(n, b) := hd l;
		if(n == name)
			return b;
	}
	return nil;
}

#
# Internal helpers
#

servicekey(name: string, accttype: int): string
{
	if(accttype == ACCT_ETH)
		return "wallet-eth-" + name;
	if(accttype == ACCT_SOL)
		return "wallet-sol-" + name;
	if(accttype == ACCT_STRIPE)
		return "wallet-stripe-" + name;
	return "wallet-unknown-" + name;
}

storekey(name: string, accttype: int, key: array of byte, chain: string): string
{
	svc := servicekey(name, accttype);

	# Binary keys (ETH, Solana) are hex-encoded; Stripe API keys are
	# text and stored as-is (consumers read them back verbatim).
	storedkey: string;
	if(accttype == ACCT_STRIPE)
		storedkey = string key;
	else
		storedkey = ethcrypto->hexencode(key);

	attrs := "key proto=pass service=" + svc + " user=key";
	if(chain != nil && chain != "" && validname(chain))
		attrs += " chain=" + chain;
	cmd := attrs + " !password=" + storedkey;
	fd := sys->open("/mnt/factotum/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open factotum: %r");

	b := array of byte cmd;
	n := sys->write(fd, b, len b);
	if(n != len b)
		return sys->sprint("factotum write failed: %r");

	return nil;
}

#
# Account and chain names appear in factotum attributes, 9P file
# names, and ctl commands; restrict them to a safe character set.
#
validname(s: string): int
{
	if(s == nil || s == "" || s == "." || s == ".." || len s > 64)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')
			continue;
		return 0;
	}
	return 1;
}

zeroarray(a: array of byte)
{
	if(a == nil)
		return;
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

#
# Fill buf completely with cryptographically secure random bytes.
# Prefers /dev/notquiterandom (host CSPRNG under emu — fast, well
# seeded); falls back to /dev/random (timing-based entropy, works on
# bare metal).  Returns 0 on success, -1 if the buffer could not be
# filled — callers MUST treat -1 as fatal, never use a partial buffer.
#
randread(buf: array of byte): int
{
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil)
		fd = sys->open("/dev/random", Sys->OREAD);
	if(fd == nil)
		return -1;
	off := 0;
	while(off < len buf) {
		n := sys->read(fd, buf[off:], len buf - off);
		if(n <= 0)
			return -1;
		off += n;
	}
	return 0;
}
