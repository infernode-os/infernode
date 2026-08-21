implement ToolWallet;

#
# wallet - Veltro tool for cryptocurrency and fiat payments
#
# Provides wallet operations to Veltro agents via the wallet9p
# filesystem at /n/wallet/.  The agent writes commands, the tool
# reads/writes the appropriate wallet9p files.
#
# The agent NEVER sees private keys — signing happens inside
# wallet9p, which retrieves keys from factotum.  There is
# deliberately no raw signing command: agents queue payment
# proposals (pay) or structured x402 authorizations (payfetch);
# budget and approval policy are enforced inside wallet9p.
#
# Usage:
#   wallet accounts                    List all wallet accounts
#   wallet address <account>           Show public address
#   wallet balance <account>           Show balance
#   wallet chain <account>             Show chain name
#   wallet history <account>           Show recent transactions
#   wallet network                     Show the active network
#   wallet pay <account> <args>        Queue a payment proposal
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolWallet: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

WALLET_MOUNT: con "/n/wallet";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "wallet";
}

doc(): string
{
	return "Wallet - Cryptocurrency and fiat payment operations\n\n" +
		"Usage:\n" +
		"  wallet accounts                              List all wallet accounts\n" +
		"  wallet address <account>                     Show public address\n" +
		"  wallet balance <account>                     Show balance (USDC + ETH)\n" +
		"  wallet chain <account>                       Show blockchain network\n" +
		"  wallet history <account>                     Show recent transactions\n" +
		"  wallet network                               Show the active network\n" +
		"  wallet pay <account> <wei> <address>         Queue ETH payment proposal\n" +
		"  wallet pay <account> usdc <amount> <address> Queue USDC payment proposal\n\n" +
		"Examples:\n" +
		"  wallet accounts\n" +
		"  wallet balance myaccount\n" +
		"  wallet pay myaccount 1000 0xRecipientAddress          Send 1000 wei\n" +
		"  wallet pay myaccount usdc 1000000 0xRecipientAddress  Send 1 USDC\n" +
		"  wallet pay stripe-acct 500 'Payment for service'     Stripe: $5.00\n\n" +
		"Account types:\n" +
		"  eth/ethereum  — Ethereum/Base crypto wallet (secp256k1)\n" +
		"  stripe/fiat   — Stripe fiat payments (requires API key in factotum)\n\n" +
		"Notes:\n" +
		"  - Amounts must be plain integers in base units: wei for ETH\n" +
		"    (1 ETH = 10^18 wei), 1 USDC = 1000000, cents for Stripe\n" +
		"  - Payments are proposals: they wait for trusted approval unless\n" +
		"    the account was explicitly configured otherwise\n" +
		"  - Private keys are never exposed to the agent\n" +
		"  - Budget limits are enforced server-side in wallet9p\n" +
		"  - Switching networks is a trusted operation (wallet GUI or\n" +
		"    /n/wallet/ctl), not available to agents\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"wallet\"," +
		"\"description\":\"Cryptocurrency and fiat payment operations via /n/wallet. Private keys are never exposed; payments are proposals that need trusted approval; budget limits are enforced server-side.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: accounts, address, balance, chain, history, network, pay.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"For address/balance/chain/history: account name. For network: omit (read-only). For pay: <account> <wei> <to-address> for ETH, or <account> usdc <amount> <to-address> for USDC; amounts are plain integers in base units. Omit for accounts.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	# Normalize: strip wrapping quotes, collapse whitespace
	args = stripquotes(args);
	(nil, toks) := sys->tokenize(args, " \t\n");
	if(toks == nil)
		return "usage: wallet <command> [args]\nRun 'wallet' with no args for help.";

	cmd := hd toks;
	rest := tl toks;

	# Handle doubled command name: "wallet wallet accounts" → "wallet accounts"
	if(cmd == "wallet" && rest != nil) {
		cmd = hd rest;
		rest = tl rest;
	}

	case cmd {
	"accounts" =>
		return doaccounts();
	"address" =>
		if(rest == nil)
			return "error: missing account name\nexample: wallet address myaccount";
		return doread(stripquotes(hd rest), "address");
	"balance" =>
		if(rest == nil)
			return "error: missing account name\nexample: wallet balance myaccount";
		return doread(stripquotes(hd rest), "balance");
	"chain" =>
		if(rest == nil)
			return "error: missing account name\nexample: wallet chain myaccount";
		return doread(stripquotes(hd rest), "chain");
	"history" =>
		if(rest == nil)
			return "error: missing account name\nexample: wallet history myaccount";
		return doread(stripquotes(hd rest), "history");
	"pay" =>
		if(rest == nil || tl rest == nil)
			return "error: need account, amount, and recipient\n" +
				"example: wallet pay myaccount 1000 0x742d35Cc6634C0532925a3b844Bc9\n" +
				"example: wallet pay myaccount usdc 1000000 0x742d35Cc6634C0532925a3b844Bc9";
		return dopay(stripquotes(hd rest), tl rest);
	"network" =>
		if(rest != nil)
			return "error: switching networks is a trusted operation (use the wallet GUI); 'wallet network' shows the active network";
		return donetwork();
	"help" =>
		if(rest == nil)
			return doc();
		return cmdhelp(hd rest);
	* =>
		return "error: unknown command '" + cmd + "'\n" +
			"valid commands: accounts, address, balance, chain, history, pay, network\n" +
			"example: wallet accounts";
	}
}

# Strip wrapping double or single quotes from a string
stripquotes(s: string): string
{
	if(s == nil || len s < 2)
		return s;
	if((s[0] == '"' && s[len s - 1] == '"') ||
	   (s[0] == '\'' && s[len s - 1] == '\''))
		return s[1:len s - 1];
	return s;
}

# Focused help for a specific command
cmdhelp(cmd: string): string
{
	case cmd {
	"accounts" =>
		return "wallet accounts\n\nList all wallet account names, one per line.";
	"balance" =>
		return "wallet balance <account>\n\nShow USDC and ETH balance for the named account.\nexample: wallet balance myaccount";
	"pay" =>
		return "wallet pay <account> <wei> <address>\n" +
			"wallet pay <account> usdc <amount> <address>\n\n" +
			"Queue an ETH or USDC payment proposal for trusted approval.\n" +
			"examples:\n" +
			"  wallet pay myaccount 1000 0x742d35Cc...\n" +
			"  wallet pay myaccount usdc 1000000 0x742d35Cc...";
	"network" =>
		return "wallet network\n\n" +
			"Show the active network (name, chain id, USDC contract).\n" +
			"Switching networks is a trusted operation done from the\n" +
			"wallet GUI or /n/wallet/ctl, not from this tool.";
	* =>
		return "no specific help for '" + cmd + "'\n" + doc();
	}
}

doaccounts(): string
{
	s := readfile(WALLET_MOUNT + "/accounts");
	if(s == nil || s == "")
		return "no accounts configured. Use 'keyring' to add wallet credentials.";
	return s;
}

doread(acct: string, file: string): string
{
	if(!validaccount(acct))
		return "error: unsafe account name";
	path := WALLET_MOUNT + "/" + acct + "/" + file;
	s := readfile(path);
	if(s == nil)
		return sys->sprint("cannot read %s: %r", path);
	return str->take(s, "^\n") ;
}

dopay(acct: string, args: list of string): string
{
	if(!validaccount(acct))
		return "error: unsafe account name";
	# Build pay command: join remaining args
	cmd := "";
	for(; args != nil; args = tl args) {
		if(cmd != "")
			cmd += " ";
		cmd += hd args;
	}

	# Single fd for write then read: wallet9p binds the result to the
	# writing fid, so the read must happen on the same one.
	path := WALLET_MOUNT + "/" + acct + "/pay";
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("pay failed: cannot open %s: %r", path);
	b := array of byte cmd;
	n := sys->write(fd, b, len b);
	if(n <= 0)
		return sys->sprint("pay failed: %r");
	rbuf := array[1024] of byte;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	rn := sys->read(fd, rbuf, len rbuf);
	if(rn <= 0)
		return "payment proposal submitted";

	result := str->take(string rbuf[0:rn], "^\n");
	if(len result >= 8 && result[0:8] == "pending:")
		return "payment pending approval: " + result[8:] +
			"\nA trusted controller must approve it before it executes.";
	return "tx: " + result;
}

donetwork(): string
{
	s := readfile(WALLET_MOUNT + "/network");
	if(s == nil)
		return "cannot read wallet network";
	return s;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

writefile(path: string, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

validaccount(s: string): int
{
	if(s == "" || s == "." || s == "..")
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

validnetwork(s: string): int
{
	case s {
	"Ethereum Sepolia" or "Base Sepolia" or "Ethereum Mainnet" or "Base" =>
		return 1;
	}
	return 0;
}
