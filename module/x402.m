X402: module {
	PATH:	con "/dis/lib/x402.dis";

	init:	fn(): string;

	# x402 protocol version
	VERSION:	con 2;

	# Payment requirements from a 402 response
	PaymentReq: adt {
		scheme:		string;		# "exact"
		network:	string;		# CAIP-2 format, e.g. "eip155:8453"
		amount:		string;		# amount in base units (wei)
		asset:		string;		# token contract address
		payto:		string;		# recipient address
		timeout:	int;		# maxTimeoutSeconds
		# extra fields for EVM
		name:		string;		# token name (e.g. "USD Coin")
		version:	string;		# token version (e.g. "2")
		method:		string;		# "eip3009" or "permit2"
	};

	# Resource info from 402 response
	ResourceInfo: adt {
		url:		string;
		description:	string;
		mimetype:	string;
	};

	# Full 402 response
	PaymentRequired: adt {
		x402version:	int;
		errmsg:		string;
		resource:	ref ResourceInfo;
		accepts:	list of ref PaymentReq;
	};

	# Settlement response from server after payment
	SettlementResp: adt {
		success:	int;
		errorreason:	string;
		payer:		string;
		transaction:	string;
		network:	string;
	};

	# Parse a 402 response body (JSON) into PaymentRequired
	parse402:	fn(body: string): (ref PaymentRequired, string);

	# Select the best payment option from accepts list
	# Prefers EVM networks the wallet supports
	selectoption:	fn(pr: ref PaymentRequired, chain: string): ref PaymentReq;

	# Request a signed EIP-3009 payment authorization from wallet9p.
	# Writes a structured request to /n/wallet/{acct}/authorize where
	# budget and approval policy are enforced server-side, polls for up
	# to waitsecs while approval is pending, and returns the payment
	# payload JSON for the X-PAYMENT header (not yet base64-encoded).
	# Returns ("", "pending:<id>") if approval did not arrive in time.
	authorize:	fn(req: ref PaymentReq, resource: ref ResourceInfo,
			   acctname: string, waitsecs: int): (string, string);

	# Compute the EIP-712 digest of an EIP-3009 TransferWithAuthorization.
	# Used by wallet9p so the signer constructs — and therefore knows —
	# exactly what it is signing.  amount is a strict decimal string in
	# the asset's base units; nonce is 32 random bytes.
	authdigest:	fn(network, asset, payto, from, amount: string,
			   validafter, validbefore: big, nonce: array of byte,
			   tokenname, tokenversion: string): (array of byte, string);

	# Parse a settlement response from the server
	parsesettlement:	fn(body: string): (ref SettlementResp, string);

	# Map chain name to CAIP-2 network identifier
	chaintonetwork:	fn(chain: string): string;
	# "eip155:NNNN" -> NNNN; 0 if not a well-formed EIP-155 id.
	# Never defaults to a real chain: callers pin payments with it.
	networktochainid:	fn(network: string): int;
};
