Ethrpc: module {
	PATH:	con "/dis/lib/ethrpc.dis";

	init:	fn(rpcurl: string): string;

	# Set the RPC endpoint: an https URL, or an http one to this
	# machine (127.0.0.1, localhost, [::1]).  Any other is refused,
	# with the reason, and the endpoint is as it was; init refuses
	# the same.
	setrpc:	fn(url: string): string;

	# Chain ID
	chainid:	fn(): (int, string);

	# Get native ETH balance (returns wei as decimal string)
	getbalance:	fn(addr: string): (string, string);

	# Get ERC-20 token balance (returns token units as decimal string)
	tokenbalance:	fn(token: string, addr: string): (string, string);

	# Get transaction count (nonce) for address
	getnonce:	fn(addr: string): (int, string);

	# Send raw signed transaction (hex-encoded)
	sendrawtx:	fn(rawtx: string): (string, string);
		# returns (txhash, error)

	# Generic eth_call (for arbitrary contract reads)
	ethcall:	fn(calldata: string, contract: string): (string, string);
		# returns (hex result, error)

	# Get current gas price (returns wei as decimal string)
	gasprice:	fn(): (string, string);

	# Hex/decimal conversions for wei values
	hextowei:	fn(hex: string): string;	# 0x... → decimal string
	weitohex:	fn(wei: string): string;	# decimal string → 0x...
	weitoeth:	fn(wei: string): string;	# wei → ETH with 18 decimals
	weitotoken:	fn(wei: string, decimals: int): string;	# wei → token units
};
