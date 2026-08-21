implement Ethrpc;

#
# Ethereum JSON-RPC client.
#
# Speaks the standard Ethereum JSON-RPC API over HTTPS.
# Used by wallet9p for balance queries and transaction submission.
#
# Default endpoint: https://sepolia.base.org (Base Sepolia testnet)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "webclient.m";
	webclient: Webclient;
	Header, Response: import webclient;

include "ethrpc.m";

rpcurl: string;
reqid: int;

init(url: string): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "cannot load Keyring";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	json = load JSON JSON->PATH;
	if(json == nil)
		return "cannot load JSON";
	json->init(bufio);
	webclient = load Webclient Webclient->PATH;
	if(webclient == nil)
		return "cannot load Webclient";
	err := webclient->init();
	if(err != nil)
		return "webclient: " + err;

	if(url == nil || url == "")
		url = "https://sepolia.base.org";
	rpcurl = url;
	reqid = 1;
	return nil;
}

setrpc(url: string)
{
	rpcurl = url;
}

#
# eth_chainId
#
chainid(): (int, string)
{
	(result, err) := rpccall("eth_chainId", "[]");
	if(err != nil)
		return (0, err);
	# Parse at full precision first so a chain id beyond int range is
	# reported as the (unsupported) number it is, rather than as a
	# malformed response — the network table only holds ids that fit
	# an int, so such a chain simply is not one we can sign for.
	raw := getresultstr(result);
	dec := hextowei(raw);
	if(dec == nil)
		return (0, "eth_chainId: malformed response");
	id := hexnum(raw);
	if(id < 0)
		return (0, "eth_chainId: unsupported chain id " + dec);
	return (id, nil);
}

#
# eth_getBalance
# Returns wei as decimal string
#
getbalance(addr: string): (string, string)
{
	if(!validaddress(addr))
		return (nil, "eth_getBalance: invalid address");
	params := "[\"" + addr + "\",\"latest\"]";
	(result, err) := rpccall("eth_getBalance", params);
	if(err != nil)
		return (nil, err);
	dec := hextowei(getresultstr(result));
	if(dec == nil)
		return (nil, "eth_getBalance: malformed balance in response");
	return (dec, nil);
}

#
# ERC-20 balanceOf via eth_call
# Returns token units as decimal string
#
tokenbalance(token: string, addr: string): (string, string)
{
	if(!validaddress(token) || !validaddress(addr))
		return (nil, "tokenbalance: invalid address");
	# balanceOf(address) = 0x70a08231 + address padded to 32 bytes
	paddedaddr := padaddr(addr);
	calldata := "0x70a08231" + paddedaddr;

	(result, err) := ethcall(calldata, token);
	if(err != nil)
		return (nil, err);
	dec := hextowei(result);
	if(dec == nil)
		return (nil, "tokenbalance: malformed balance in response");
	return (dec, nil);
}

#
# eth_getTransactionCount (nonce)
#
getnonce(addr: string): (int, string)
{
	if(!validaddress(addr))
		return (0, "eth_getTransactionCount: invalid address");
	# Include locally pending transactions so sequential wallet sends do not
	# reuse a nonce while the preceding transaction is still unmined.
	params := "[\"" + addr + "\",\"pending\"]";
	(result, err) := rpccall("eth_getTransactionCount", params);
	if(err != nil)
		return (0, err);
	n := hexnum(getresultstr(result));
	if(n < 0)
		return (0, "eth_getTransactionCount: malformed response");
	return (n, nil);
}

#
# eth_sendRawTransaction
#
sendrawtx(rawtx: string): (string, string)
{
	hexdata := rawtx;
	if(len hexdata < 2 || hexdata[0:2] != "0x")
		hexdata = "0x" + hexdata;
	if(!validhex(hexdata[2:]))
		return (nil, "eth_sendRawTransaction: raw tx is not hex");
	params := "[\"" + hexdata + "\"]";
	(result, err) := rpccall("eth_sendRawTransaction", params);
	if(err != nil)
		return (nil, err);
	txhash := getresultstr(result);
	if(!validtxhash(txhash))
		return (nil, "eth_sendRawTransaction: malformed transaction hash");
	return (txhash, nil);
}

#
# eth_getTransactionReceipt
#
getreceipt(txhash: string): (ref TxReceipt, string)
{
	if(!validtxhash(txhash))
		return (nil, "eth_getTransactionReceipt: invalid tx hash");
	params := "[\"" + txhash + "\"]";
	(result, err) := rpccall("eth_getTransactionReceipt", params);
	if(err != nil)
		return (nil, err);

	rv := getresult(result);
	if(rv == nil || rv.isnull())
		return (nil, nil);	# pending — no receipt yet

	# status must parse to the documented {0,1} domain; a missing or
	# malformed field is an error, never a value a fail-open caller
	# could mistake for success
	status := hexnum(jvgetstr(rv, "status"));
	if(status < 0 || status > 1)
		return (nil, "eth_getTransactionReceipt: malformed status in receipt");
	blocknumber := jvgetstr(rv, "blockNumber");
	gasused := jvgetstr(rv, "gasUsed");

	return (ref TxReceipt(status, txhash, blocknumber, gasused), nil);
}

#
# Poll for receipt
#
waitreceipt(txhash: string, timeoutsec: int): (ref TxReceipt, string)
{
	# Poll every 2 seconds
	polls := timeoutsec / 2;
	if(polls < 1)
		polls = 1;

	for(i := 0; i < polls; i++) {
		(receipt, err) := getreceipt(txhash);
		if(err != nil)
			return (nil, err);
		if(receipt != nil)
			return (receipt, nil);
		sys->sleep(2000);
	}
	return (nil, "timeout waiting for receipt: " + txhash);
}

#
# eth_call (generic contract read)
#
ethcall(calldata: string, contract: string): (string, string)
{
	if(!validaddress(contract))
		return (nil, "eth_call: invalid contract address");
	cd := calldata;
	if(len cd >= 2 && cd[0:2] == "0x")
		cd = cd[2:];
	if(!validhex(cd))
		return (nil, "eth_call: calldata is not hex");
	params := "[{\"to\":\"" + contract + "\",\"data\":\"0x" + cd + "\"},\"latest\"]";
	(result, err) := rpccall("eth_call", params);
	if(err != nil)
		return (nil, err);
	return (getresultstr(result), nil);
}

#
# eth_gasPrice
# Returns current gas price in wei as decimal string
#
gasprice(): (string, string)
{
	(result, err) := rpccall("eth_gasPrice", "[]");
	if(err != nil)
		return (nil, err);
	hex := getresultstr(result);
	if(hex == nil || hex == "")
		return (nil, "no gas price in response");
	dec := hextowei(hex);
	if(dec == nil)
		return (nil, "eth_gasPrice: malformed response");
	return (dec, nil);
}

#
# Hex/decimal conversions.
# Arbitrary precision (mainnet balances routinely exceed 2^63 wei);
# strict parsing — malformed input returns nil, never a wrong number.
#

# 0x hex → decimal string
hextowei(hex: string): string
{
	if(hex == nil || hex == "")
		return nil;
	s := hex;
	if(len s >= 2 && s[0:2] == "0x")
		s = s[2:];
	if(s == "")
		return "0";
	if(!validhexdigits(s) || len s > 64)
		return nil;
	# Strip leading zeros
	while(len s > 1 && s[0] == '0')
		s = s[1:];
	ip := IPint.strtoip(s, 16);
	if(ip == nil)
		return nil;
	return ip.iptostr(10);
}

# Decimal string → 0x hex
weitohex(wei: string): string
{
	if(wei == nil || wei == "" || len wei > 78)
		return nil;
	for(i := 0; i < len wei; i++)
		if(!(wei[i] >= '0' && wei[i] <= '9'))
			return nil;
	s := wei;
	while(len s > 1 && s[0] == '0')
		s = s[1:];
	if(s == "0")
		return "0x0";
	ip := IPint.strtoip(s, 10);
	if(ip == nil)
		return nil;
	# iptostr emits uppercase hex; Ethereum canonical form is lowercase
	h := ip.iptostr(16);
	lh := "";
	for(i = 0; i < len h; i++) {
		c := h[i];
		if(c >= 'A' && c <= 'F')
			c += 'a' - 'A';
		lh[len lh] = c;
	}
	return "0x" + lh;
}

# Wei → ETH string (18 decimal places, trimmed)
weitoeth(wei: string): string
{
	return weitotoken(wei, 18);
}

# Wei → token string with given decimals
weitotoken(wei: string, decimals: int): string
{
	if(wei == nil || wei == "" || wei == "0")
		return "0";
	if(decimals < 0 || decimals > 77)
		return "";
	for(i := 0; i < len wei; i++)
		if(!(wei[i] >= '0' && wei[i] <= '9'))
			return "";

	# Pad to at least decimals+1 digits
	s := wei;
	while(len s <= decimals)
		s = "0" + s;

	# Insert decimal point
	intpart := s[0:len s - decimals];
	fracpart := s[len s - decimals:];

	# Trim trailing zeros from fraction
	while(len fracpart > 1 && fracpart[len fracpart - 1] == '0')
		fracpart = fracpart[0:len fracpart - 1];

	if(fracpart == "0")
		return intpart;
	return intpart + "." + fracpart;
}

#
# JSON-RPC call
#
rpccall(method: string, params: string): (ref JValue, string)
{
	id := reqid++;
	body := "{\"jsonrpc\":\"2.0\",\"method\":\"" + method +
		"\",\"params\":" + params +
		",\"id\":" + string id + "}";

	hdrs := Header("Content-Type", "application/json") :: nil;
	(resp, err) := webclient->request("POST", rpcurl, hdrs, array of byte body);
	if(err != nil)
		return (nil, method + ": " + err);
	if(resp.statuscode != 200)
		return (nil, sys->sprint("%s: HTTP %d", method, resp.statuscode));

	jv := parsejson(string resp.body);
	if(jv == nil)
		return (nil, method + ": invalid JSON response");

	# Check for JSON-RPC error
	errobj := jv.get("error");
	if(errobj != nil && errobj.isobject()) {
		emsg := jvgetstr(errobj, "message");
		return (nil, method + ": " + emsg);
	}

	return (jv, nil);
}

#
# JSON helpers
#

parsejson(s: string): ref JValue
{
	iob := bufio->sopen(s);
	if(iob == nil)
		return nil;
	(jv, nil) := json->readjson(iob);
	return jv;
}

getresult(jv: ref JValue): ref JValue
{
	if(jv == nil)
		return nil;
	return jv.get("result");
}

getresultstr(jv: ref JValue): string
{
	rv := getresult(jv);
	if(rv == nil)
		return "";
	if(rv.isstring()) {
		pick sv := rv {
		String => return sv.s;
		}
	}
	return rv.text();
}

jvgetstr(jv: ref JValue, field: string): string
{
	v := jv.get(field);
	if(v == nil)
		return "";
	if(v.isstring()) {
		pick sv := v {
		String => return sv.s;
		}
	}
	return v.text();
}

# Parse 0x hex to int; strict — returns -1 on malformed input or
# values that do not fit a non-negative int
hexnum(s: string): int
{
	if(s == nil || s == "")
		return -1;
	if(len s >= 2 && s[0:2] == "0x")
		s = s[2:];
	if(s == "" || !validhexdigits(s))
		return -1;
	while(len s > 1 && s[0] == '0')
		s = s[1:];
	if(len s > 8)
		return -1;	# > 32 bits
	v := big 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		d := 0;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else
			d = c - 'A' + 10;
		v = v * big 16 + big d;
	}
	if(v > big 16r7fffffff)
		return -1;
	return int v;
}

validhexdigits(s: string): int
{
	if(s == nil || s == "")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
			return 0;
	}
	return 1;
}

# Hex string (no 0x prefix); empty allowed
validhex(s: string): int
{
	if(s == nil)
		return 0;
	if(s == "")
		return 1;
	if(len s % 2 != 0)
		return 0;
	return validhexdigits(s);
}

# 0x + 40 hex digits
validaddress(s: string): int
{
	if(s == nil || len s != 42)
		return 0;
	if(s[0:2] != "0x")
		return 0;
	return validhexdigits(s[2:]);
}

# 0x + 64 hex digits
validtxhash(s: string): int
{
	if(s == nil || len s != 66)
		return 0;
	if(s[0:2] != "0x")
		return 0;
	return validhexdigits(s[2:]);
}

# Pad an address to 32 bytes (64 hex chars), left-padded with zeros
# Input: "0xABCD..." → output: "000000000000000000000000ABCD..."
padaddr(addr: string): string
{
	s := addr;
	if(len s >= 2 && s[0:2] == "0x")
		s = s[2:];
	while(len s < 64)
		s = "0" + s;
	return s;
}
