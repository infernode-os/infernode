Wallet: module {
	PATH:	con "/dis/lib/wallet.dis";

	init:	fn(): string;

	# Account types
	ACCT_ETH:	con 0;	# Ethereum/Base (secp256k1)
	ACCT_SOL:	con 1;	# Solana (Ed25519)
	ACCT_STRIPE:	con 2;	# Fiat (Stripe API key)

	Account: adt {
		name:		string;
		accttype:	int;
		chain:		string;	# "base", "ethereum", "solana"
		address:	string;	# public address (hex with 0x or base58)
	};

	# Account management (keys in factotum)
	createaccount:	fn(name: string, accttype: int, chain: string): (ref Account, string);
	importaccount:	fn(name: string, accttype: int, chain: string, privkey: array of byte): (ref Account, string);
	loadaccount:	fn(name: string): (ref Account, string);
	listaccounts:	fn(): list of ref Account;

	# Signing (retrieves key from factotum, signs, zeroes key)
	signhash:	fn(acct: ref Account, hash: array of byte): (array of byte, string);

	# Budget enforcement.
	#
	# Amounts are uint256 big-endian byte strings (as produced by
	# Ethcrypto->dectobe), NOT big: a budget denominated in wei
	# exceeds 2^63 at just 9.3 ETH, so an int64 representation
	# cannot express — and silently mis-evaluates — a limit on the
	# mainnet ETH accounts budgets exist to protect.
	# An empty/nil limit means "no limit" for that dimension.
	Budget: adt {
		maxpertx:	array of byte;	# max per transaction (smallest unit)
		maxpersess:	array of byte;	# max per session
		spent:		array of byte;	# spent this session
		currency:	string;		# "USDC", "ETH", "USD"
	};

	setbudget:	fn(acct: ref Account, b: ref Budget);
	checkbudget:	fn(acct: ref Account, amount: array of byte): string;
		# returns nil if OK, error string if over budget
	recordspend:	fn(acct: ref Account, amount: array of byte);
	budgetfor:	fn(acct: ref Account): ref Budget;
		# returns the configured budget, or nil if none

	# Canonical account/chain name rule.  Names reach factotum
	# attributes, 9P file names, and ctl commands, so every surface
	# that validates one must use THIS predicate rather than its own
	# copy — a more permissive copy upstream means a name that is
	# accepted at write time and dropped on persistence.
	validname:	fn(s: string): int;
};
