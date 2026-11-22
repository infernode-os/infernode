implement ToolPayfetch;

#
# payfetch - Fetch a URL, automatically paying via x402 if required
#
# Like webfetch, but handles HTTP 402 Payment Required responses:
#   1. Makes initial request
#   2. If 402, parses x402 payment requirements
#   3. Checks wallet budget
#   4. Signs payment authorization via wallet9p
#   5. Retries request with PAYMENT-SIGNATURE header
#   6. Returns the resource content
#
# The agent explicitly chooses payfetch over webfetch when it is
# willing to spend money to access a resource.
#
# Usage:
#   payfetch <url>                       Use default wallet account
#   payfetch <url> -a <account>          Use specific wallet account
#   payfetch <url> -a <account> -c <chain>  Specify chain preference
#
# The tool reports what it paid before returning the content, so the
# agent (and user via history) can see exactly what was spent.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "publicnet.m";
	publicnet: Publicnet;

include "webclient.m";
	webclient: Webclient;
	Header, Response: import webclient;

include "encoding.m";
	base64: Encoding;

include "x402.m";
	x402: X402;

include "../tool.m";

ToolPayfetch: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

REQUEST_TIMEOUT: con 30000;
MAX_BODY: con 512 * 1024;	# of a response read (as webfetch: it is for a model to read)
inited := 0;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	webclient = load Webclient Webclient->PATH;
	if(webclient == nil)
		return "cannot load Webclient";
	err := webclient->init();
	if(err != nil)
		return "Webclient init: " + err;
	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet == nil)
		return "cannot load Publicnet";
	publicnet->init();
	x402 = load X402 X402->PATH;
	if(x402 == nil)
		return "cannot load X402";
	err = x402->init();
	if(err != nil)
		return "X402 init: " + err;
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		return "cannot load base64 encoding";
	inited = 1;
	return nil;
}

enc64(s: string): string
{
	return base64->enc(array of byte s);
}

name(): string
{
	return "payfetch";
}

doc(): string
{
	return "Payfetch - Fetch a URL, paying via x402 if required\n\n" +
		"Usage:\n" +
		"  payfetch <url>\n" +
		"  payfetch <url> -a <account>\n" +
		"  payfetch <url> -a <account> -c <chain>\n\n" +
		"Arguments:\n" +
		"  url      - Full URL (https://...; a payment is made over https only)\n" +
		"  -a acct  - Wallet account name (default: reads /mnt/wallet/ctl)\n" +
		"  -c chain - Preferred chain (default: base)\n\n" +
		"Behavior:\n" +
		"  1. Fetches the URL normally\n" +
		"  2. If the server returns 402 Payment Required with x402 headers,\n" +
		"     requests a payment authorization from the wallet and retries\n" +
		"  3. Reports what was paid before returning content\n\n" +
		"The agent must have /mnt/wallet access (caps.paths must include /mnt/wallet).\n" +
		"Budget and approval policy are enforced inside wallet9p: if the\n" +
		"account requires approval, the fetch waits up to 90s for a trusted\n" +
		"controller to approve, then reports pending if it hasn't been.\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"payfetch\"," +
		"\"description\":\"Fetch a URL, automatically paying via x402 if the server returns 402 Payment Required. Reports what was paid before returning content. Requires /mnt/wallet access.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"url\":{\"type\":\"string\",\"description\":\"Full URL beginning with https://.\"}," +
				"\"flags\":{\"type\":\"string\",\"description\":\"Optional flags: -a <account> to choose a wallet account, -c <chain> to override the chain (default base). Pass both space-separated, e.g. '-a myacct -c base'.\"}" +
			"}," +
			"\"required\":[\"url\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(!inited && (ierr := init()) != nil)
		return "error: payfetch: " + ierr;

	# Parse arguments
	(nil, toks) := sys->tokenize(strip(args), " \t\n");
	if(toks == nil)
		return "error: usage: payfetch <url> [-a account] [-c chain]";

	url := hd toks;
	toks = tl toks;
	acctname := "";
	chain := "base";
	chainoverride := 0;

	# A flag that is not one, or has no value, is an error.  (They were
	# passed over: "-a" with nothing after it paid from the default
	# account, not the one that was meant.)
	while(toks != nil) {
		flag := hd toks;
		toks = tl toks;
		if(flag != "-a" && flag != "-c")
			return "error: unknown argument '" + flag + "'; usage: payfetch <url> [-a account] [-c chain]";
		if(toks == nil)
			return "error: " + flag + " needs a value; usage: payfetch <url> [-a account] [-c chain]";
		if(flag == "-a")
			acctname = hd toks;
		else {
			chain = hd toks;
			chainoverride = 1;
		}
		toks = tl toks;
	}

	# If no account specified, try to read default from wallet ctl
	if(acctname == "")
		acctname = getdefaultaccount();
	if(acctname == "")
		return "error: no wallet account specified and no default set.\n" +
			"Use: payfetch <url> -a <account>\n" +
			"Or set default from a trusted wallet controller.";
	if(!validaccount(acctname))
		return "error: unsafe wallet account name";

	# Validate URL
	lurl := str->tolower(url);
	if(!hasprefix(lurl, "http://") && !hasprefix(lurl, "https://"))
		return "error: URL must start with http:// or https://";

	# SSRF protection (same policy as webfetch; publicnet enforces the
	# same ranges again at dial time on every hop)
	host := extracthost(url);
	if(isblocked(host))
		return "error: requests to internal/private network addresses are not allowed";

	# First request
	hdrs := Header("User-Agent", "Veltro/1.0 (x402-enabled)") ::
		Header("Accept", "text/html, application/json, text/plain, */*") :: nil;

	(resp, err) := dofetch("GET", url, hdrs, nil);
	if(err != nil)
		return "error: fetch failed: " + err;

	# Not a 402 — return content directly
	if(resp.statuscode != 402) {
		if(resp.statuscode >= 400)
			return sys->sprint("error: HTTP %d", resp.statuscode);
		return formatresponse(resp);
	}

	# ── x402 payment flow ────────────────────────────────

	# A payment is asked for and made over https only.  Over plain
	# http anyone on the path writes the 402 (the recipient, the
	# amount) and reads the signed authorization that answers it.
	if(!hasprefix(str->tolower(resp.url), "https://"))
		return "error: " + resp.url + " asks for payment (HTTP 402) over plain http; " +
			"payfetch pays over https only";

	# Parse 402 response body
	body := string resp.body;
	(pr, perr) := x402->parse402(body);
	if(perr != nil) {
		# (the start of what came, on one line: it was echoed whole)
		if(len body > 300)
			body = body[0:300] + "...";
		return "error: cannot parse 402 response: " + perr +
			"\nResponse body: " + oneline(body);
	}

	# Note: pr.errmsg is informational (e.g. "Payment required"), not fatal
	# Only treat it as fatal if there are no payment options
	if(pr.accepts == nil && pr.errmsg != nil && pr.errmsg != "")
		return "error: server payment error: " + pr.errmsg;

	# Select payment option: prefer the wallet's ACTIVE network (read
	# from /mnt/wallet/network) so we never request an authorization the
	# wallet will refuse; an explicit -c overrides.
	opt: ref X402->PaymentReq;
	walletnet := walletcaip2();
	if(chainoverride)
		opt = x402->selectoption(pr, chain);
	else if(walletnet != "")
		opt = selectbynetwork(pr, walletnet);
	if(opt == nil)
		opt = x402->selectoption(pr, chain);
	if(opt == nil)
		return "error: no compatible payment option for chain '" + chain + "'" +
			"\nServer accepts: " + listnetworks(pr);

	# Client-side sanity check on the quoted amount.  This is advisory
	# only — the enforcing budget/approval checks run inside wallet9p,
	# where the agent cannot bypass them.
	if(!validamount(opt.amount))
		return "error: server quoted a malformed payment amount: " + opt.amount;

	# Request a signed authorization from wallet9p (budget + approval
	# enforced there), waiting up to 90s for the approval.  One not
	# approved in that time is withdrawn, and the error says so: there
	# is nothing left pending to approve later, and a fetch again is a
	# new request.
	(payload, aerr) := x402->authorize(opt, pr.resource, acctname, 90);
	if(aerr != nil)
		return "error: payment authorization failed: " + aerr;

	# Retry with the payment header.  X-PAYMENT carries the payload
	# base64-encoded per the x402 spec; the legacy PAYMENT-SIGNATURE
	# header (raw JSON) is kept for older servers.
	payhdrs := Header("User-Agent", "Veltro/1.0 (x402-enabled)") ::
		Header("Accept", "text/html, application/json, text/plain, */*") ::
		Header("X-PAYMENT", enc64(payload)) ::
		Header("PAYMENT-SIGNATURE", payload) :: nil;

	# (to the address that asked for payment, which a redirect may
	# have made another than the one first asked for; webclient drops
	# these headers if a redirect changes origin again)
	# From here the authorization has left: whatever comes back, the
	# result says so.  (A timeout, an error status or a settlement
	# header that did not parse said nothing of it.)
	sent := "The payment authorization (" + opt.amount + " to " + opt.payto + " on " + opt.network +
		") was signed and sent before this; whether it was taken is not known." +
		" Check the wallet before fetching this again.";
	(resp2, err2) := dofetch("GET", resp.url, payhdrs, nil);
	if(err2 != nil)
		return "error: paid request failed: " + err2 + "\n" + sent;

	if(resp2.statuscode >= 400)
		return sys->sprint("error: paid request returned HTTP %d\n%s", resp2.statuscode, sent);

	# Check settlement response if present
	settlement := getheader(resp2.headers, "X-PAYMENT-RESPONSE");
	if(settlement == "")
		settlement = getheader(resp2.headers, "PAYMENT-RESPONSE");
	paidmsg := "";
	if(settlement != "") {
		(sr, nil) := x402->parsesettlement(settlement);
		if(sr != nil && sr.success)
			paidmsg = sys->sprint("[Paid %s to %s on %s, tx: %s]\n",
				opt.amount, opt.payto, opt.network, sr.transaction);
		else if(sr != nil)
			paidmsg = "[Payment reported but settlement pending]\n";
		else
			paidmsg = sys->sprint("[Payment authorization for %s to %s on %s sent; the server's settlement report could not be read]\n",
				opt.amount, opt.payto, opt.network);
	} else {
		paidmsg = sys->sprint("[Paid %s on %s]\n", opt.amount, opt.network);
	}

	return paidmsg + formatresponse(resp2);
}

# ── Wallet helpers ───────────────────────────────────────────

getdefaultaccount(): string
{
	d := readfile("/mnt/wallet/default");
	if(d != nil) {
		(nil, dtoks) := sys->tokenize(d, " \t\n");
		if(dtoks != nil)
			return hd dtoks;
	}

	s := readfile("/mnt/wallet/ctl");
	if(s == nil)
		return "";
	# Parse "default <name>\n"
	(nil, toks) := sys->tokenize(s, " \t\n");
	if(toks != nil && hd toks == "default" && tl toks != nil)
		return hd tl toks;
	return "";
}

# Read the wallet's active network as a CAIP-2 id ("eip155:NNNN")
walletcaip2(): string
{
	s := readfile("/mnt/wallet/network");
	if(s == nil)
		return "";
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines) {
		(nil, toks) := sys->tokenize(hd lines, " \t");
		if(toks != nil && hd toks == "caip2" && tl toks != nil)
			return hd tl toks;
	}
	return "";
}

selectbynetwork(pr: ref X402->PaymentRequired, network: string): ref X402->PaymentReq
{
	for(l := pr.accepts; l != nil; l = tl l) {
		if((hd l).network == network)
			return hd l;
	}
	return nil;
}

validamount(s: string): int
{
	if(s == nil || s == "" || len s > 78)
		return 0;
	for(i := 0; i < len s; i++)
		if(!(s[i] >= '0' && s[i] <= '9'))
			return 0;
	return 1;
}

# ── HTTP helpers ─────────────────────────────────────────────

# The request keeps its own time and limit: at the deadline its
# connection is hung up and nothing of it is left running, and no more
# than MAX_BODY of a response is read.
dofetch(method, url: string, hdrs: list of Header, body: array of byte): (ref Response, string)
{
	(r, e) := webclient->requestbounded(method, url, hdrs, body, 1, REQUEST_TIMEOUT, MAX_BODY);
	if(e == "request timed out")
		e = "request timed out (30s)";
	return (r, e);
}

formatresponse(resp: ref Response): string
{
	if(resp.body == nil || len resp.body == 0)
		return "(empty response)";

	text := string resp.body;
	if(resp.truncated)
		text += "\n[the response is longer: only its first 512KB were read]";
	# what came is the server's words: one that begins as a failed call
	# does ("error:") is said to be the response
	if(len text >= 6 && str->tolower(text[0:6]) == "error:")
		return "the response:\n" + text;
	return text;
}

# s on one line: control characters and line ends as blanks
oneline(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < ' ' || c == 16r7F)
			c = ' ';
		r[len r] = c;
	}
	return r;
}

getheader(hdrs: list of Header, name: string): string
{
	lname := str->tolower(name);
	for(; hdrs != nil; hdrs = tl hdrs) {
		h := hd hdrs;
		if(str->tolower(h.name) == lname)
			return h.value;
	}
	return "";
}

listnetworks(pr: ref X402->PaymentRequired): string
{
	s := "";
	for(l := pr.accepts; l != nil; l = tl l) {
		if(s != "")
			s += ", ";
		s += (hd l).network;
	}
	return s;
}

# ── Utility ──────────────────────────────────────────────────

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
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

# The URL host extractor and the SSRF blocklist live in publicnet,
# the same module that re-checks the address at dial time. Local
# copies of these two functions drifted apart across the fetch
# tools; there is now one definition.
extracthost(url: string): string
{
	return publicnet->urlhost(url);
}

isblocked(host: string): int
{
	return publicnet->hostblocked(host);
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}
