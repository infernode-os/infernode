implement X402;

#
# x402 payment protocol library.
#
# Implements the x402 v2 specification for HTTP 402 payment flows.
# Parses 402 responses, constructs signed payment payloads,
# and formats PAYMENT-SIGNATURE headers.
#
# References:
#   https://github.com/coinbase/x402
#   specs/x402-specification-v2.md
#   specs/schemes/exact/scheme_exact_evm.md
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "ethcrypto.m";
	ethcrypto: Ethcrypto;

include "x402.m";

init(): string
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
	ethcrypto = load Ethcrypto Ethcrypto->PATH;
	if(ethcrypto == nil)
		return "cannot load Ethcrypto";
	err := ethcrypto->init();
	if(err != nil)
		return "ethcrypto: " + err;
	return nil;
}

#
# Parse a 402 response body into PaymentRequired.
#
parse402(body: string): (ref PaymentRequired, string)
{
	jv := parsestr(body);
	if(jv == nil)
		return (nil, "invalid JSON in 402 response");

	x402ver := getint(jv, "x402Version");
	errmsg := getstr(jv, "error");

	# Parse resource
	rjv := jv.get("resource");
	resource: ref ResourceInfo;
	if(rjv != nil && rjv.isobject())
		resource = ref ResourceInfo(
			getstr(rjv, "url"),
			getstr(rjv, "description"),
			getstr(rjv, "mimeType")
		);

	# Parse accepts array
	ajv := jv.get("accepts");
	accepts: list of ref PaymentReq;
	if(ajv != nil && ajv.isarray()) {
		pick a := ajv {
		Array =>
			for(i := len a.a - 1; i >= 0; i--) {
				pjv := a.a[i];
				if(pjv != nil && pjv.isobject()) {
					# Parse extra fields
					ejv := pjv.get("extra");
					method := "";
					tname := "";
					tversion := "";
					if(ejv != nil && ejv.isobject()) {
						method = getstr(ejv, "assetTransferMethod");
						tname = getstr(ejv, "name");
						tversion = getstr(ejv, "version");
					}
					pr := ref PaymentReq(
						getstr(pjv, "scheme"),
						getstr(pjv, "network"),
						getstr(pjv, "amount"),
						getstr(pjv, "asset"),
						getstr(pjv, "payTo"),
						getint(pjv, "maxTimeoutSeconds"),
						tname,
						tversion,
						method
					);
					accepts = pr :: accepts;
				}
			}
		}
	}

	return (ref PaymentRequired(x402ver, errmsg, resource, accepts), nil);
}

#
# Select the best payment option matching the given chain.
#
selectoption(pr: ref PaymentRequired, chain: string): ref PaymentReq
{
	if(pr == nil)
		return nil;

	network := chaintonetwork(chain);

	# First pass: exact network match
	for(l := pr.accepts; l != nil; l = tl l) {
		req := hd l;
		if(req.network == network)
			return req;
	}

	# Second pass: any EVM network
	for(l = pr.accepts; l != nil; l = tl l) {
		req := hd l;
		if(len req.network > 7 && req.network[0:7] == "eip155:")
			return req;
	}

	# Fallback: first option
	if(pr.accepts != nil)
		return hd pr.accepts;

	return nil;
}

#
# Request a signed payment authorization from wallet9p.
#
# The wallet server owns the whole EIP-3009 construction: it generates
# the nonce and validity window, computes the EIP-712 digest itself
# (so it knows exactly what it signs), enforces budget and approval
# policy, and returns the signature.  This function only formats the
# request, polls while approval is pending, and assembles the payment
# payload JSON.
#
authorize(req: ref PaymentReq, resource: ref ResourceInfo,
	  acctname: string, waitsecs: int): (string, string)
{
	if(req == nil)
		return (nil, "nil payment requirement");
	if(!validacct(acctname))
		return (nil, "unsafe wallet account name");

	# EVERY field below comes from the server's 402 response and is
	# about to be concatenated into a newline-delimited, key-value
	# protocol.  A field containing a newline would inject additional
	# keys — and wallet9p's parser would let them override payto and
	# amount — so the payload is signed for an attacker's recipient.
	# Validate shape here and reject control characters outright;
	# wallet9p independently re-validates and rejects duplicate keys.
	if(req.scheme != "exact")
		return (nil, "unsupported payment scheme: " + clean(req.scheme));
	if(!validnetwork(req.network))
		return (nil, "malformed network in 402 response: " + clean(req.network));
	if(ethcrypto->strtoaddr(req.asset) == nil)
		return (nil, "malformed asset address in 402 response: " + clean(req.asset));
	if(ethcrypto->strtoaddr(req.payto) == nil)
		return (nil, "malformed payTo address in 402 response: " + clean(req.payto));
	if(ethcrypto->dectobe(req.amount) == nil)
		return (nil, "malformed amount in 402 response: " + clean(req.amount));
	if(req.timeout < 0)
		return (nil, "malformed timeout in 402 response");
	if(!validtoken(req.name) || !validtoken(req.version))
		return (nil, "malformed token name/version in 402 response");

	reqtext := "scheme " + req.scheme + "\n" +
		"network " + req.network + "\n" +
		"asset " + req.asset + "\n" +
		"payto " + req.payto + "\n" +
		"amount " + req.amount + "\n" +
		"timeout " + string req.timeout + "\n" +
		"name " + req.name + "\n" +
		"version " + req.version + "\n";
	if(resource != nil && resource.url != "") {
		if(!validurlfield(resource.url))
			return (nil, "malformed resource url in 402 response");
		reqtext += "resource " + resource.url + "\n";
	}

	authpath := "/n/wallet/" + acctname + "/authorize";
	fd := sys->open(authpath, Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", authpath));
	wb := array of byte reqtext;
	n := sys->write(fd, wb, len wb);
	if(n <= 0)
		return (nil, sys->sprint("authorize request failed: %r"));

	# Poll the same fid: wallet9p returns "pending:<id>" until the
	# payment is approved (or denied/expired) by a trusted controller.
	result := "";
	waited := 0;
	for(;;) {
		rbuf := array[2048] of byte;
		sys->seek(fd, big 0, Sys->SEEKSTART);
		rn := sys->read(fd, rbuf, len rbuf);
		if(rn <= 0)
			return (nil, "no authorization returned");
		result = strip(string rbuf[0:rn]);
		if(len result >= 8 && result[0:8] == "pending:") {
			if(waited >= waitsecs)
				return ("", result);	# still pending; caller may retry later
			sys->sleep(2000);
			waited += 2;
			continue;
		}
		break;
	}
	if(result == "denied")
		return (nil, "payment denied by wallet controller");
	if(result == "expired")
		return (nil, "payment approval window expired");
	if(len result >= 6 && result[0:6] == "error:")
		return (nil, result[6:]);

	# Parse: "sig <hex> from <addr> nonce <hex> validafter <n> validbefore <n>"
	sigstr := "";
	addrstr := "";
	nonce := "";
	validafter := "";
	validbefore := "";
	(nil, toks) := sys->tokenize(result, " \t\n");
	while(toks != nil && tl toks != nil) {
		k := hd toks;
		v := hd tl toks;
		toks = tl tl toks;
		case k {
		"sig" =>		sigstr = v;
		"from" =>	addrstr = v;
		"nonce" =>	nonce = v;
		"validafter" =>	validafter = v;
		"validbefore" =>	validbefore = v;
		}
	}
	if(sigstr == "" || addrstr == "" || nonce == "" ||
	   validafter == "" || validbefore == "")
		return (nil, "malformed authorization from wallet: " + result);

	# Build PaymentPayload JSON
	authobj := json->jvobject(
		("from", json->jvstring(addrstr)) ::
		("to", json->jvstring(req.payto)) ::
		("value", json->jvstring(req.amount)) ::
		("validAfter", json->jvstring(validafter)) ::
		("validBefore", json->jvstring(validbefore)) ::
		("nonce", json->jvstring(nonce)) ::
		nil
	);

	payloadobj := json->jvobject(
		("signature", json->jvstring("0x" + sigstr)) ::
		("authorization", authobj) ::
		nil
	);

	resourceobj := json->jvobject(nil);
	if(resource != nil) {
		resourceobj = json->jvobject(
			("url", json->jvstring(resource.url)) ::
			nil
		);
	}

	# Build accepted (echo back the requirement we're paying)
	acceptedobj := json->jvobject(
		("scheme", json->jvstring(req.scheme)) ::
		("network", json->jvstring(req.network)) ::
		("amount", json->jvstring(req.amount)) ::
		("asset", json->jvstring(req.asset)) ::
		("payTo", json->jvstring(req.payto)) ::
		("maxTimeoutSeconds", json->jvint(req.timeout)) ::
		nil
	);

	fullpayload := json->jvobject(
		("x402Version", json->jvint(VERSION)) ::
		("resource", resourceobj) ::
		("accepted", acceptedobj) ::
		("payload", payloadobj) ::
		nil
	);

	payloadjson := fullpayload.text();
	return (payloadjson, nil);
}

#
# Parse settlement response.
#
parsesettlement(body: string): (ref SettlementResp, string)
{
	jv := parsestr(body);
	if(jv == nil)
		return (nil, "invalid JSON in settlement response");

	success := 0;
	sv := jv.get("success");
	if(sv != nil && sv.istrue())
		success = 1;

	return (ref SettlementResp(
		success,
		getstr(jv, "errorReason"),
		getstr(jv, "payer"),
		getstr(jv, "transaction"),
		getstr(jv, "network")
	), nil);
}

#
# Chain name ↔ CAIP-2 network mapping
#

chaintonetwork(chain: string): string
{
	if(chain == "base" || chain == "base-mainnet")
		return "eip155:8453";
	if(chain == "base-sepolia")
		return "eip155:84532";
	if(chain == "ethereum" || chain == "mainnet")
		return "eip155:1";
	if(chain == "ethereum-sepolia" || chain == "sepolia")
		return "eip155:11155111";
	if(chain == "polygon")
		return "eip155:137";
	if(chain == "arbitrum")
		return "eip155:42161";
	if(chain == "optimism")
		return "eip155:10";
	return "eip155:1";	# default to mainnet
}

#
# Parse "eip155:NNNN" → NNNN.  Returns 0 for anything that is not a
# well-formed EIP-155 CAIP-2 id.
#
# This MUST NOT default to a real chain: wallet9p pins payments by
# comparing this against the active network's chain id, so returning
# 1 (mainnet) for unparseable input made that check pass — fail-open —
# whenever the wallet happened to be on mainnet.
#
networktochainid(network: string): int
{
	if(!validnetwork(network))
		return 0;
	rest := network[7:];
	if(len rest > 9)
		return 0;	# beyond what an int chain id can hold
	id := 0;
	for(i := 0; i < len rest; i++)
		id = id * 10 + (rest[i] - '0');
	return id;
}

#
# Compute the EIP-712 digest of an EIP-3009 TransferWithAuthorization.
# All inputs are strictly validated; wallet9p calls this so the signer
# itself constructs the message it signs.
#
authdigest(network, asset, payto, from, amount: string,
	validafter, validbefore: big, nonce: array of byte,
	tokenname, tokenversion: string): (array of byte, string)
{
	chainid := networktochainid(network);
	if(chainid <= 0)
		return (nil, "unknown network: " + network);
	if(ethcrypto->strtoaddr(asset) == nil)
		return (nil, "invalid asset address");
	if(ethcrypto->strtoaddr(payto) == nil)
		return (nil, "invalid payto address");
	if(ethcrypto->strtoaddr(from) == nil)
		return (nil, "invalid from address");
	if(ethcrypto->dectobe(amount) == nil)
		return (nil, "invalid amount (must be integer base units)");
	if(nonce == nil || len nonce != 32)
		return (nil, "nonce must be 32 bytes");
	if(validafter < big 0 || validbefore <= validafter)
		return (nil, "invalid validity window");
	if(tokenname == "" || len tokenname > 64 || len tokenversion > 16)
		return (nil, "invalid token name/version");

	domainhash := eip712domainhash(tokenname, tokenversion, chainid, asset);
	structhash := eip712structhash(from, payto, amount,
		sys->sprint("%bd", validafter), sys->sprint("%bd", validbefore),
		ethcrypto->hexencode(nonce));
	if(domainhash == nil || structhash == nil)
		return (nil, "EIP-712 encoding failed");

	digest := ethcrypto->eip712hash(domainhash, structhash);
	if(digest == nil)
		return (nil, "EIP-712 hash failed");
	return (digest, nil);
}

#
# EIP-712 helpers
#

# Hash the EIP-712 domain separator
# keccak256(abi.encode(typeHash, nameHash, versionHash, chainId, verifyingContract))
eip712domainhash(name: string, version: string, chainid: int, contract: string): array of byte
{
	# EIP712Domain type hash:
	# keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
	typehashstr := array of byte "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
	typehash := array[32] of byte;
	kr->keccak256(typehashstr, len typehashstr, typehash);

	# keccak256(name)
	namebytes := array of byte name;
	namehash := array[32] of byte;
	kr->keccak256(namebytes, len namebytes, namehash);

	# keccak256(version)
	versionbytes := array of byte version;
	versionhash := array[32] of byte;
	kr->keccak256(versionbytes, len versionbytes, versionhash);

	# chainId as uint256 (32 bytes, big-endian, zero-padded)
	chainidbytes := pad32(ethcrypto->bigtobytes(big chainid));

	# verifyingContract as address (20 bytes, left-padded to 32)
	contractaddr := ethcrypto->strtoaddr(contract);
	contractpadded := pad32addr(contractaddr);

	# Concatenate: typeHash || nameHash || versionHash || chainId || contract
	encoded := array[5 * 32] of byte;
	encoded[0:] = typehash;
	encoded[32:] = namehash;
	encoded[64:] = versionhash;
	encoded[96:] = chainidbytes;
	encoded[128:] = contractpadded;

	result := array[32] of byte;
	kr->keccak256(encoded, len encoded, result);
	return result;
}

# Hash the TransferWithAuthorization struct
eip712structhash(sender: string, recipient: string, value: string,
	validafter: string, validbefore: string, nonce: string): array of byte
{
	# Struct type hash
	typehashstr := array of byte "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)";
	typehash := array[32] of byte;
	kr->keccak256(typehashstr, len typehashstr, typehash);

	# Encode each field as 32-byte ABI-encoded value
	fromaddr := pad32addr(ethcrypto->strtoaddr(sender));
	toaddr := pad32addr(ethcrypto->strtoaddr(recipient));
	valuebytes := pad32(strtobigbytes(value));
	afterbytes := pad32(strtobigbytes(validafter));
	beforebytes := pad32(strtobigbytes(validbefore));

	# nonce is bytes32 (already 32 bytes as hex)
	noncebytes := ethcrypto->hexdecode(nonce);
	if(noncebytes == nil || len noncebytes != 32)
		noncebytes = array[32] of byte;

	# Concatenate
	encoded := array[7 * 32] of byte;
	encoded[0:] = typehash;
	encoded[32:] = fromaddr;
	encoded[64:] = toaddr;
	encoded[96:] = valuebytes;
	encoded[128:] = afterbytes;
	encoded[160:] = beforebytes;
	encoded[192:] = noncebytes;

	result := array[32] of byte;
	kr->keccak256(encoded, len encoded, result);
	return result;
}

# Pad bytes to 32 bytes (left-padded with zeros for uint256)
pad32(b: array of byte): array of byte
{
	r := array[32] of byte;
	for(i := 0; i < 32; i++)
		r[i] = byte 0;
	if(b != nil) {
		off := 32 - len b;
		if(off < 0) off = 0;
		n := len b;
		if(n > 32) n = 32;
		r[off:] = b[0:n];
	}
	return r;
}

# Pad a 20-byte address to 32 bytes (left-padded)
pad32addr(addr: array of byte): array of byte
{
	r := array[32] of byte;
	for(i := 0; i < 32; i++)
		r[i] = byte 0;
	if(addr != nil && len addr == 20)
		r[12:] = addr;
	return r;
}

# Convert decimal string to big-endian bytes (strict; garbage -> nil,
# which pad32 turns into an all-zero word — callers validate first)
strtobigbytes(s: string): array of byte
{
	return ethcrypto->dectobe(s);
}

#
# JSON helpers
#

parsestr(s: string): ref JValue
{
	iob := bufio->sopen(s);
	if(iob == nil)
		return nil;
	(jv, nil) := json->readjson(iob);
	return jv;
}

getstr(jv: ref JValue, field: string): string
{
	v := jv.get(field);
	if(v == nil)
		return "";
	if(v.isstring()) {
		pick sv := v {
		String =>
			return sv.s;
		}
	}
	return v.text();
}

getint(jv: ref JValue, field: string): int
{
	v := jv.get(field);
	if(v == nil)
		return 0;
	if(v.isint()) {
		pick iv := v {
		Int =>
			return int iv.value;
		}
	}
	return 0;
}

#
# File I/O helpers
#

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

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

#
# Field validators for the wallet authorize protocol.
#
# The protocol is line-oriented "key value", so no field may contain a
# newline, carriage return, or any other control character.  These are
# deliberately conservative: anything unusual is rejected rather than
# escaped, because the consequence of a mistake is a signed transfer.
#

# No control characters (including \n and \r), printable ASCII only
noctl(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] > '~')
			return 0;
	return 1;
}

# "eip155:<digits>", nothing else
validnetwork(s: string): int
{
	if(s == nil || len s < 8 || len s > 32 || s[0:7] != "eip155:")
		return 0;
	rest := s[7:];
	for(i := 0; i < len rest; i++)
		if(!(rest[i] >= '0' && rest[i] <= '9'))
			return 0;
	return 1;
}

# Token name / version: short, printable, no control characters
validtoken(s: string): int
{
	if(s == nil || len s == 0 || len s > 64)
		return 0;
	return noctl(s);
}

# Resource URL echoed back into the request line
validurlfield(s: string): int
{
	if(s == nil || len s == 0 || len s > 1024)
		return 0;
	if(!noctl(s))
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			return 0;
	return 1;
}

# Sanitize an untrusted string for inclusion in an error message
clean(s: string): string
{
	if(s == nil)
		return "";
	if(len s > 64)
		s = s[0:64];
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < ' ' || c > '~')
			c = '?';
		r[len r] = c;
	}
	return r;
}

validacct(s: string): int
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
