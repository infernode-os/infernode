Ethcrypto: module {
	PATH:	con "/dis/lib/ethcrypto.dis";

	init:	fn(): string;

	# Address derivation (go-ethereum: crypto.PubkeyToAddress)
	# Takes 65-byte uncompressed pubkey, returns 20-byte address
	pubkeytoaddr:	fn(pub: array of byte): array of byte;

	# Hex-encode an address with EIP-55 mixed-case checksum
	addrtostr:	fn(addr: array of byte): string;

	# Parse a hex address string (with or without 0x prefix) to 20 bytes
	strtoaddr:	fn(s: string): array of byte;

	# RLP encoding (go-ethereum: rlp/encode.go)
	rlpencode_bytes:	fn(s: array of byte): array of byte;
	rlpencode_list:		fn(items: list of array of byte): array of byte;
	rlpencode_uint:		fn(v: big): array of byte;
	# RLP-encode an unsigned integer given as big-endian bytes (uint256)
	rlpencode_bigbe:	fn(b: array of byte): array of byte;

	# EIP-155 transaction
	EthTx: adt {
		nonce:		big;
		gasprice:	big;	# in wei
		gaslimit:	big;
		dst:		array of byte;	# 20 bytes, nil for contract creation
		value:		array of byte;	# wei as big-endian unsigned bytes (uint256); nil/empty = 0
		data:		array of byte;
		chainid:	int;	# 8453 for Base, 1 for mainnet
	};

	# Sign a transaction, returns RLP-encoded signed tx
	signtx:		fn(tx: ref EthTx, privkey: array of byte): array of byte;

	# EIP-712 typed data hash: keccak256(0x19 || 0x01 || domainSep || structHash)
	eip712hash:	fn(domainsep: array of byte, structhash: array of byte): array of byte;

	# Hex utilities
	hexencode:	fn(b: array of byte): string;
	hexdecode:	fn(s: string): array of byte;

	# Big-endian encoding of big int (minimal bytes, no leading zeros)
	bigtobytes:	fn(v: big): array of byte;

	# Strict decimal string -> big-endian unsigned bytes (uint256).
	# Rejects anything but [0-9]+ up to 78 digits or a value >= 2^256;
	# returns nil on error.  Zero returns a non-nil empty array.
	dectobe:	fn(s: string): array of byte;

	# Big-endian unsigned bytes -> decimal string (arbitrary precision).
	betodec:	fn(b: array of byte): string;

	# Compare two big-endian unsigned integers of any length.
	# Returns -1 if a < b, 0 if equal, 1 if a > b.
	becmp:	fn(a, b: array of byte): int;

	# Add two big-endian unsigned integers; result is minimal-length.
	# Returns nil if the sum would exceed 2^256-1.
	beadd:	fn(a, b: array of byte): array of byte;
};
