implement Wallet9p;

#
# wallet9p - Wallet Filesystem Service
#
# 9P server exposing cryptocurrency and fiat wallet operations.
# Uses factotum for private key storage, budget enforcement for safety.
#
# Filesystem layout:
#   /n/wallet/
#       ctl          rw: global config ("limit <amount>", "default <name>")
#       accounts     r:  newline-separated account names
#       default      r:  default account name
#       new          rw: write "eth base myaccount" → read account name
#       {name}/          per-account directory
#           address  r:  public address
#           balance  r:  balance (queries chain/API)
#           chain    rw: chain name
#           sign     rw: write hex hash → read hex signature
#           pay      rw: write "amount recipient" → read txhash
#           ctl      rw: per-account config
#           history  r:  recent transactions (JSON lines)
#
# Usage:
#   wallet9p [-D] [-m mountpt]
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "string.m";
	str: String;

include "factotum.m";
	factotum: Factotum;

include "keyring.m";
	kr: Keyring;

include "ethcrypto.m";
	ethcrypto: Ethcrypto;

include "wallet.m";
	wallet: Wallet;

include "ethrpc.m";
	ethrpc: Ethrpc;

include "x402.m";
	x402mod: X402;

include "stripe.m";
	stripemod: Stripe;

Wallet9p: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# File types (low byte of qid path)
Qroot:     con 0;
Qctl:      con 1;
Qaccounts: con 2;
Qnew:      con 3;
Qpending:  con 4;
Qdefault:  con 5;
Qnetwork:  con 6;
# Per-account files start at 16
Qacctdir:  con 16;
Qaddress:  con 17;
Qbalance:  con 18;
Qchain:    con 19;
# 20 was Qsign, the raw hash-signing oracle. It is deliberately gone:
# it signed any caller-supplied 32-byte hash with the spend key, with
# no budget, approval, or chain check, so anything that could reach it
# could authorize a transfer of the whole balance. Agents were kept
# away from it by namespace narrowing alone, which is one bug away
# from re-exposing it. Nothing in the tree needs it -- payments go
# through Qpay and Qauthorize, where wallet9p builds and policy-checks
# what it signs -- so the file no longer exists. The number stays
# retired so a stale qid can never be read as a different file.
Qpay:      con 21;
Qacctctl:  con 22;
Qhistory:  con 23;
Qauthorize: con 24;

NACCTFILES: con 7;	# files per account dir

MAXHISTORY: con 200;	# history entries kept per account
PENDTTL:    con 900;	# seconds before an unapproved payment expires
MAXPENDING: con 100;	# total pending-payment records kept

# Account state
AcctState: adt {
	id:         int;		# stable account id (survives list changes)
	acct:       ref Wallet->Account;
	history:    list of string;	# recent transactions
	nhistory:   int;
	requireapproval: int;		# 1 = require trusted approval for payments
};

# Pending payment (awaiting approval)
PendingPay: adt {
	id:        int;
	kind:      string;	# "pay" or "x402"
	acct:      string;
	amount:    string;
	recipient: string;	# recipient (pay) or payto (x402)
	token:     string;	# "eth" or "usdc" (pay); asset address (x402)
	agent:     string;	# agent name (if from tool)
	created:   big;		# epoch seconds when queued
	# x402-only fields
	network:   string;
	tokenname: string;
	tokenver:  string;
	timeout:   int;
	resource:  string;
	result:    string;	# nil = pending; "approved:<data>", "denied",
				# "expired", or "error:<msg>"
};

pendingpays: list of ref PendingPay;
nextpendingid := 1;
nextacctid := 0;

stderr: ref Sys->FD;
user: string;
vers: int;

# Account registry
accounts: list of ref AcctState;

# Global config
defaultacct: string;
globalctl: string;

# Per-fid state for new file
NewState: adt {
	fid:    int;
	result: string;
};
newstates: list of ref NewState;


MKPATH(id, filetype: int): big
{
	return big ((id << 8) | filetype);
}

ACCTID(path: big): int
{
	return (int path >> 8) & 16rFFFFFF;
}

FTYPE(path: big): int
{
	return int path & 16rFF;
}

stderr2(s: string)
{
	sys->fprint(stderr, "wallet9p: %s\n", s);
}

nomod(s: string)
{
	sys->fprint(stderr, "wallet9p: can't load %s: %r\n", s);
	raise "fail:load";
}

# Find account by name
findacct(name: string): ref AcctState
{
	for(l := accounts; l != nil; l = tl l) {
		as := hd l;
		if(as.acct.name == name)
			return as;
	}
	return nil;
}

# Find account by its stable id.  Ids are assigned once at creation
# and never reused, so a 9P fid opened on an account file keeps
# referring to that same account even as accounts are added.
findacctbyid(id: int): ref AcctState
{
	for(l := accounts; l != nil; l = tl l) {
		if((hd l).id == id)
			return hd l;
	}
	return nil;
}

# Get stable account ID from name
acctidbyname(name: string): int
{
	for(l := accounts; l != nil; l = tl l) {
		if((hd l).acct.name == name)
			return (hd l).id;
	}
	return -1;
}

# Number of accounts
naccts(): int
{
	n := 0;
	for(l := accounts; l != nil; l = tl l)
		n++;
	return n;
}

# Per-fid new state management
getnewstate(fid: int): ref NewState
{
	for(l := newstates; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

setnewstate(fid: int, result: string)
{
	ns := getnewstate(fid);
	if(ns != nil) {
		ns.result = result;
		return;
	}
	newstates = ref NewState(fid, result) :: newstates;
}

delnewstate(fid: int)
{
	nl: list of ref NewState;
	for(l := newstates; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	newstates = nl;
}

# Per-fid result state for the pay and authorize files.
# Results are bound to the writing fid so concurrent clients never
# read each other's transaction results.
FidResult: adt {
	fid:    int;
	result: string;
};
paystates: list of ref FidResult;
authstates: list of ref FidResult;

getfidresult(states: list of ref FidResult, fid: int): ref FidResult
{
	for(l := states; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

setpaystate(fid: int, result: string)
{
	fr := getfidresult(paystates, fid);
	if(fr != nil) {
		fr.result = result;
		return;
	}
	paystates = ref FidResult(fid, result) :: paystates;
}

setauthstate(fid: int, result: string)
{
	fr := getfidresult(authstates, fid);
	if(fr != nil) {
		fr.result = result;
		return;
	}
	authstates = ref FidResult(fid, result) :: authstates;
}

delfidresult(fid: int)
{
	nl: list of ref FidResult;
	for(l := paystates; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	paystates = nl;
	nl = nil;
	for(l = authstates; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	authstates = nl;
}

#
# Resolve a per-fid result that may reference a pending payment.
# "pending:<id>" strings are resolved against the pending list so the
# reader sees approval/denial/expiry as it happens.
#
resolvefidresult(s: string): string
{
	if(s == nil)
		return "";
	if(!(len s > 8 && s[0:8] == "pending:"))
		return s;
	(id, ok) := strint(s[8:]);
	if(!ok)
		return "error:bad pending id";
	pp := findpending(id);
	if(pp == nil)
		return "expired";
	checkpendingexpiry(pp);
	if(pp.result == nil)
		return s;	# still pending
	if(len pp.result > 9 && pp.result[0:9] == "approved:")
		return pp.result[9:];
	return pp.result;	# "denied", "expired", or "error:..."
}

findpending(id: int): ref PendingPay
{
	for(pl := pendingpays; pl != nil; pl = tl pl)
		if((hd pl).id == id)
			return hd pl;
	return nil;
}

#
# Expiry is fail-closed on the time source: if /dev/time is unreadable
# now() returns 0, and a TTL that silently never fires would leave
# stale authorizations approvable forever. No clock means expired.
#
checkpendingexpiry(pp: ref PendingPay)
{
	if(pp.result != nil)
		return;
	t := now();
	if(t <= big 0 || pp.created <= big 0 || t > pp.created + big PENDTTL)
		pp.result = "expired";
}

# Strict non-negative int parse
strint(s: string): (int, int)
{
	if(s == nil || s == "" || len s > 9)
		return (0, 0);
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= '0' && c <= '9'))
			return (0, 0);
		v = v * 10 + (c - '0');
	}
	return (v, 1);
}

# Epoch seconds from /dev/time (microseconds)
now(): big
{
	fd := sys->open("/dev/time", Sys->OREAD);
	if(fd == nil)
		return big 0;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return big 0;
	s := string buf[0:n];
	usec := big 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= '0' && c <= '9')
			usec = usec * big 10 + big (c - '0');
	}
	return usec / big 1000000;
}

#
# Fill buf completely with cryptographically secure random bytes.
# Returns 0 on success, -1 on failure (callers must fail closed).
#
randfill(buf: array of byte): int
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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil) nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) nomod(Styxservers->PATH);
	styxservers->init(styx);

	str = load String String->PATH;
	if(str == nil) nomod(String->PATH);

	kr = load Keyring Keyring->PATH;
	if(kr == nil) nomod(Keyring->PATH);

	factotum = load Factotum Factotum->PATH;
	if(factotum == nil) nomod(Factotum->PATH);
	factotum->init();

	ethcrypto = load Ethcrypto Ethcrypto->PATH;
	if(ethcrypto == nil) nomod(Ethcrypto->PATH);
	err := ethcrypto->init();
	if(err != nil) {
		sys->fprint(stderr, "wallet9p: ethcrypto init: %s\n", err);
		raise "fail:init";
	}

	wallet = load Wallet Wallet->PATH;
	if(wallet == nil) nomod(Wallet->PATH);
	err = wallet->init();
	if(err != nil) {
		sys->fprint(stderr, "wallet9p: wallet init: %s\n", err);
		raise "fail:init";
	}

	ethrpc = load Ethrpc Ethrpc->PATH;
	if(ethrpc == nil) nomod(Ethrpc->PATH);
	initnetworks();
	# Default to first network (Ethereum Sepolia)
	err = ethrpc->init(networks[0].rpcurl);
	if(err != nil) {
		sys->fprint(stderr, "wallet9p: ethrpc init: %s\n", err);
		raise "fail:init";
	}

	x402mod = load X402 X402->PATH;
	if(x402mod == nil) nomod(X402->PATH);
	err = x402mod->init();
	if(err != nil) {
		sys->fprint(stderr, "wallet9p: x402 init: %s\n", err);
		raise "fail:init";
	}

	mountpt := "/n/wallet";
	debug := 0;

	arg := load Arg Arg->PATH;
	if(arg != nil) {
		arg->init(args);
		while((c := arg->opt()) != 0) {
			case c {
			'D' =>
				debug = 1;
			'm' =>
				mountpt = arg->earg();
			* =>
				sys->fprint(stderr, "Usage: wallet9p [-D] [-m mountpt]\n");
				raise "fail:usage";
			}
		}
	}

	user = readuser();

	# Restore accounts from factotum (persistence across restarts)
	restoreaccounts();

	# Start debounced sync thread
	initsyncthread();

	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	if(debug)
		styxservers->traceset(1);

	spawn serveloop(tchan, srv);

	# Ensure mount point exists
	(ok, nil) := sys->stat(mountpt);
	if(ok < 0) {
		fd := sys->create(mountpt, Sys->OREAD, Sys->DMDIR | 8r755);
		if(fd != nil)
			fd = nil;
	}

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "wallet9p: mount %s: %r\n", mountpt);
		raise "fail:mount";
	}
}

readuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "inferno";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "inferno";
	return string buf[0:n];
}

# --- Serve loop ---

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver)
{
	while((gm := <-tchan) != nil) {
		pick m := gm {
		Readerror =>
			return;

		Open =>
			c := srv.getfid(m.fid);
			if(c != nil) {
				ft := FTYPE(c.path);
				if(ft == Qnew)
					setnewstate(m.fid, "");
			}
			srv.default(gm);

		Read =>
			doread(srv, m);

		Write =>
			dowrite(srv, m);

		Clunk =>
			delnewstate(m.fid);
			delfidresult(m.fid);
			srv.default(gm);

		* =>
			srv.default(gm);
		}
	}
}

doread(srv: ref Styxserver, m: ref Tmsg.Read)
{
	(c, err) := srv.canread(m);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, err));
		return;
	}
	if(c.qtype & Sys->QTDIR) {
		srv.read(m);
		return;
	}

	ft := FTYPE(c.path);
	aid := ACCTID(c.path);

	case ft {
	Qctl =>
		net := getnetwork();
		ctlinfo := "network " + net.name + "\n";
		if(defaultacct != "")
			ctlinfo += "default " + defaultacct + "\n";
		readstr(srv, m, ctlinfo);

	Qaccounts =>
		s := "";
		for(l := accounts; l != nil; l = tl l) {
			s += (hd l).acct.name + "\n";
		}
		readstr(srv, m, s);

	Qdefault =>
		if(defaultacct != "")
			readstr(srv, m, defaultacct + "\n");
		else
			readstr(srv, m, "");

	Qnew =>
		ns := getnewstate(m.fid);
		if(ns != nil && ns.result != "")
			readstr(srv, m, ns.result + "\n");
		else
			readstr(srv, m, "");

	Qpending =>
		s := "";
		for(pl := pendingpays; pl != nil; pl = tl pl) {
			pp := hd pl;
			checkpendingexpiry(pp);
			if(pp.result == nil) {
				net := pp.network;
				if(net == "")
					net = "-";
				s += sys->sprint("%d %s %s %s %s %s %s %s\n",
					pp.id, pp.kind, pp.acct, pp.token, pp.amount,
					pp.recipient, net, pp.agent);
			}
		}
		if(s == "")
			s = "(none)\n";
		readstr(srv, m, s);

	Qnetwork =>
		net := getnetwork();
		s := "name " + net.name + "\n" +
			"chainid " + string net.chainid + "\n" +
			"caip2 eip155:" + string net.chainid + "\n" +
			"usdc " + net.usdc + "\n";
		readstr(srv, m, s);

	Qaddress =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		readstr(srv, m, as.acct.address + "\n");

	Qbalance =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		bal := querybalance(as);
		readstr(srv, m, bal + "\n");

	Qchain =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		readstr(srv, m, as.acct.chain + "\n");

	Qpay =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		# Per-fid ONLY: results are never exposed to a reader that did
		# not write the request.  wallet9p is one backend shared by
		# every agent's bound view, so an account-level fallback would
		# hand another principal's txhash (or pending id) to whoever
		# opened the file next.
		fr := getfidresult(paystates, m.fid);
		if(fr != nil && fr.result != nil)
			readstr(srv, m, resolvefidresult(fr.result) + "\n");
		else
			readstr(srv, m, "");

	Qauthorize =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		# Per-fid ONLY — see Qpay above.  A signed EIP-3009
		# authorization is a replayable bearer credential; handing one
		# to a reader that did not request it is a fund-moving leak.
		fr := getfidresult(authstates, m.fid);
		if(fr != nil && fr.result != nil)
			readstr(srv, m, resolvefidresult(fr.result) + "\n");
		else
			readstr(srv, m, "");

	Qacctctl =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		s := "";
		b := wallet->budgetfor(as.acct);
		if(b == nil)
			s += "no budget\n";
		else
			s += sys->sprint("budget %s %s %s spent %s\n",
				ethcrypto->betodec(b.maxpertx),
				ethcrypto->betodec(b.maxpersess),
				b.currency, ethcrypto->betodec(b.spent));
		if(as.requireapproval)
			s += "requireapproval on\n";
		else
			s += "requireapproval off\n";
		readstr(srv, m, s);

	Qhistory =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		s := "";
		for(h := as.history; h != nil; h = tl h)
			s += hd h + "\n";
		readstr(srv, m, s);

	* =>
		srv.default(m);
	}
}

dowrite(srv: ref Styxserver, m: ref Tmsg.Write)
{
	(c, werr) := srv.canwrite(m);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, werr));
		return;
	}

	ft := FTYPE(c.path);
	aid := ACCTID(c.path);
	data := string m.data;

	case ft {
	Qctl =>
		# Global control commands
		data = str->take(data, "^\n\r");
		(ntoks, toks) := sys->tokenize(data, " \t");
		if(ntoks < 1) {
			srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
			return;
		}
		cmd := hd toks;
		if(cmd == "default" && ntoks == 2) {
			if(!validacctname(hd tl toks)) {
				srv.reply(ref Rmsg.Error(m.tag, "invalid account name"));
				return;
			}
			defaultacct = hd tl toks;
			globalctl = "default " + defaultacct + "\n";
		} else if(cmd == "rpc" && ntoks == 2) {
			ethrpc->setrpc(hd tl toks);
		} else if(cmd == "network" && ntoks >= 2) {
			# Rejoin remaining tokens as network name (may have spaces)
			nname := "";
			for(nt := tl toks; nt != nil; nt = tl nt) {
				if(nname != "")
					nname += " ";
				nname += hd nt;
			}
			setnetwork(nname);
		} else if(cmd == "approve") {
			(pid, perr) := pendingid(toks, "approve");
			if(perr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, perr));
				return;
			}
			err := approvepending(pid);
			if(err != nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				return;
			}
		} else if(cmd == "deny") {
			(pid, perr) := pendingid(toks, "deny");
			if(perr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, perr));
				return;
			}
			err := denypending(pid);
			if(err != nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				return;
			}
		} else {
			srv.reply(ref Rmsg.Error(m.tag, "unknown ctl command: " + cmd));
			return;
		}
		srv.reply(ref Rmsg.Write(m.tag, len m.data));

	Qnew =>
		# Create new account: "eth base myaccount" or "import eth base myaccount hexkey"
		data = str->take(data, "^\n\r");
		(ntoks, toks) := sys->tokenize(data, " \t");

		if(ntoks >= 1 && hd toks == "import") {
			# import eth base myaccount hexkey — exactly 5 tokens
			if(ntoks != 5) {
				srv.reply(ref Rmsg.Error(m.tag, "usage: import type chain name hexkey"));
				return;
			}
			toks = tl toks;
			accttype := parsetype(hd toks);
			if(accttype < 0) {
				srv.reply(ref Rmsg.Error(m.tag, "unknown account type: " + hd toks));
				return;
			}
			toks = tl toks;
			chain := hd toks; toks = tl toks;
			name := hd toks; toks = tl toks;
			if(!validacctname(name)) {
				srv.reply(ref Rmsg.Error(m.tag, "invalid account name"));
				return;
			}
			if(findacct(name) != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "account exists: " + name));
				return;
			}
			hexkey := hd toks;
			privkey := ethcrypto->hexdecode(hexkey);
			if(privkey == nil) {
				srv.reply(ref Rmsg.Error(m.tag, "invalid hex key"));
				return;
			}
			(acct, err) := wallet->importaccount(name, accttype, chain, privkey);
			zeroarray(privkey);
			if(err != nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				return;
			}
			addaccount(acct);
			setnewstate(m.fid, name);
			syncfactotum();
			vers++;
		} else if(ntoks == 3) {
			# eth base myaccount
			accttype := parsetype(hd toks);
			if(accttype < 0) {
				srv.reply(ref Rmsg.Error(m.tag, "unknown account type: " + hd toks));
				return;
			}
			toks = tl toks;
			chain := hd toks; toks = tl toks;
			name := hd toks;
			if(!validacctname(name)) {
				srv.reply(ref Rmsg.Error(m.tag, "invalid account name"));
				return;
			}
			if(findacct(name) != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "account exists: " + name));
				return;
			}
			(acct, err) := wallet->createaccount(name, accttype, chain);
			if(err != nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				return;
			}
			addaccount(acct);
			setnewstate(m.fid, name);
			syncfactotum();
			vers++;
		} else {
			srv.reply(ref Rmsg.Error(m.tag, "usage: type chain name | import type chain name hexkey"));
			return;
		}
		srv.reply(ref Rmsg.Write(m.tag, len m.data));

	Qchain =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		nc := str->take(data, "^\n\r \t");
		if(!safechain(nc)) {
			srv.reply(ref Rmsg.Error(m.tag, "invalid chain name"));
			return;
		}
		as.acct.chain = nc;
		srv.reply(ref Rmsg.Write(m.tag, len m.data));

	Qpay =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		# Parse: "amount recipient" (ETH) or "usdc amount recipient" (ERC-20)
		paydata := str->take(data, "^\n\r");
		(ntoks, paytoks) := sys->tokenize(paydata, " \t");
		if(ntoks < 2) {
			srv.reply(ref Rmsg.Error(m.tag, "usage: amount recipient OR usdc amount recipient"));
			return;
		}
		payamt: string;
		payrecip: string;
		paytoken := "eth";
		first := hd paytoks;
		if(first == "usdc" || first == "USDC") {
			if(ntoks < 3) {
				srv.reply(ref Rmsg.Error(m.tag, "usage: usdc amount recipient"));
				return;
			}
			payamt = hd tl paytoks;
			payrecip = hd tl tl paytoks;
			paytoken = "usdc";
		} else {
			payamt = first;
			payrecip = hd tl paytoks;
		}
		# Label the pending entry with the real asset so the approval
		# UI never misstates what is being authorized.
		if(as.acct.accttype == Wallet->ACCT_STRIPE) {
			if(paytoken == "usdc") {
				srv.reply(ref Rmsg.Error(m.tag, "pay: Stripe accounts cannot send USDC"));
				return;
			}
			paytoken = "usd-cents";
		}

		payerr := validatepay(as, paytoken, payamt, payrecip);
		if(payerr != nil) {
			srv.reply(ref Rmsg.Error(m.tag, payerr));
			return;
		}

		# Validate before queueing or executing: a payment that can
		# never execute should be rejected at submission time.
		verr := validatepay(as, paytoken, payamt, payrecip);
		if(verr != nil) {
			srv.reply(ref Rmsg.Error(m.tag, "pay: " + verr));
			return;
		}

		# Check if approval is required for this account
		if(as.requireapproval) {
			(pp, qerr) := newpending("pay", as.acct.name, payamt, payrecip, paytoken);
			if(qerr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "pay: " + qerr));
				return;
			}
			# Bind the proposal to the network it was quoted on, so a
			# network switch between proposal and approval cannot
			# silently redirect it to another chain.
			pp.network = "eip155:" + string getnetwork().chainid;
			pres := "pending:" + string pp.id;
			setpaystate(m.fid, pres);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		} else {
			# Execute immediately
			txhash: string;
			if(paytoken == "usdc")
				(txhash, payerr) = executeerc20(as, payamt, payrecip);
			else
				(txhash, payerr) = executepayment(as, payamt, payrecip);
			if(payerr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "pay: " + payerr));
				return;
			}
			setpaystate(m.fid, txhash);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		}

	Qauthorize =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		(areq, aerr) := parseauthreq(data);
		if(aerr != nil) {
			srv.reply(ref Rmsg.Error(m.tag, "authorize: " + aerr));
			return;
		}
		aerr = validateauth(as, areq);
		if(aerr != nil) {
			srv.reply(ref Rmsg.Error(m.tag, "authorize: " + aerr));
			return;
		}
		if(as.requireapproval) {
			(pp, qerr) := newpending("x402", as.acct.name, areq.amount, areq.payto, areq.asset);
			if(qerr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "authorize: " + qerr));
				return;
			}
			pp.network = areq.network;
			pp.tokenname = areq.tokenname;
			pp.tokenver = areq.tokenver;
			pp.timeout = areq.timeout;
			pp.resource = areq.resource;
			pres := "pending:" + string pp.id;
			setauthstate(m.fid, pres);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		} else {
			(res, xerr) := executex402(as, areq);
			if(xerr != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "authorize: " + xerr));
				return;
			}
			setauthstate(m.fid, res);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		}

	Qacctctl =>
		as := findacctbyid(aid);
		if(as == nil) {
			srv.reply(ref Rmsg.Error(m.tag, Enotfound));
			return;
		}
		# Parse budget commands: "budget maxpertx maxpersess currency"
		data = str->take(data, "^\n\r");
		(ntoks, toks) := sys->tokenize(data, " \t");
		if(ntoks >= 1 && hd toks == "budget" && ntoks >= 4) {
			toks = tl toks;
			# uint256 base units: a wei-denominated ETH limit passes
			# 2^63 at 9.3 ETH, so these must not go through an int64
			# parser (which previously rejected any limit >= 1 ETH
			# and left the account with no cap at all).
			maxpertx := ethcrypto->dectobe(hd toks); toks = tl toks;
			maxpersess := ethcrypto->dectobe(hd toks); toks = tl toks;
			currency := hd toks;
			if(maxpertx == nil || maxpersess == nil ||
			   !(currency == "USDC" || currency == "ETH" || currency == "USD")) {
				srv.reply(ref Rmsg.Error(m.tag,
					"usage: budget <maxpertx> <maxpersess> USDC|ETH|USD (integer base units)"));
				return;
			}
			b := ref Wallet->Budget(maxpertx, maxpersess, nil, currency);
			wallet->setbudget(as.acct, b);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		} else if(ntoks >= 1 && hd toks == "requireapproval") {
			val := 1;
			if(ntoks >= 2 && hd tl toks == "off")
				val = 0;
			as.requireapproval = val;
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		} else {
			srv.reply(ref Rmsg.Error(m.tag, "usage: budget maxpertx maxpersess currency | requireapproval [off]"));
		}

	* =>
		srv.default(m);
	}
}

pendingid(toks: list of string, verb: string): (int, string)
{
	if(toks == nil || tl toks == nil || tl tl toks != nil)
		return (-1, "usage: " + verb + " <id>");
	(id, rest) := str->toint(hd tl toks, 10);
	if(id <= 0 || rest != "")
		return (-1, verb + ": invalid id");
	return (id, nil);
}

validacctname(s: string): int
{
	if(s == nil || s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')
			continue;
		return 0;
	}
	return 1;
}

parsetype(s: string): int
{
	if(s == "eth" || s == "ethereum")
		return Wallet->ACCT_ETH;
	if(s == "sol" || s == "solana")
		return Wallet->ACCT_SOL;
	if(s == "stripe" || s == "fiat")
		return Wallet->ACCT_STRIPE;
	return -1;
}

# Register a new account with a stable id
addaccount(acct: ref Wallet->Account)
{
	as := ref AcctState(nextacctid++, acct, nil, 0, 1);
	accounts = as :: accounts;
}

#
# Queue a pending payment.
#
# The queue is a hard-bounded resource in a process shared by every
# agent: an unresolved proposal is never silently dropped to make room
# (that would lose a payment a human may be about to review), so once
# MAXPENDING live proposals exist, new ones are REFUSED. Resolved
# records are recycled first, and expiry is applied on the way in so a
# stale queue drains itself instead of wedging the account.
#
newpending(kind, acct, amount, recipient, token: string): (ref PendingPay, string)
{
	t := now();
	if(t <= big 0)
		return (nil, "no time source: cannot queue a payment for approval");

	# expire stale records, then drop resolved ones beyond the cap
	live := 0;
	keep: list of ref PendingPay;
	for(pl := pendingpays; pl != nil; pl = tl pl) {
		pp := hd pl;
		checkpendingexpiry(pp);
		if(pp.result == nil)
			live++;
	}
	if(live >= MAXPENDING)
		return (nil, sys->sprint("pending queue full (%d awaiting approval): approve or deny before submitting more", live));

	kept := 0;
	for(pl = pendingpays; pl != nil; pl = tl pl) {
		pp := hd pl;
		if(pp.result == nil || kept < MAXPENDING) {
			keep = pp :: keep;
			kept++;
		}
	}
	pendingpays = nil;
	for(; keep != nil; keep = tl keep)
		pendingpays = hd keep :: pendingpays;

	np := ref PendingPay(nextpendingid++, kind, acct, amount, recipient,
		token, "agent", t, "", "", "", 0, "", nil);
	pendingpays = np :: pendingpays;
	return (np, nil);
}

inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# Chain names must satisfy the SAME rule the wallet library applies on
# persistence (Wallet->validname): a name accepted here but rejected
# there would silently revert to a default on the next restart.
safechain(s: string): int
{
	return wallet->validname(s);
}

# Strict non-negative big parse
strbig(s: string): (big, int)
{
	if(s == nil || s == "" || len s > 18)
		return (big 0, 0);
	v := big 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= '0' && c <= '9'))
			return (big 0, 0);
		v = v * big 10 + big (c - '0');
	}
	return (v, 1);
}

validamount(s: string): int
{
	if(s == nil || s == "")
		return 0;
	nonzero := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return 0;
		if(c != '0')
			nonzero = 1;
	}
	return nonzero;
}

hascontrol(s: string): int
{
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < ' ' || c == 16r7f)
			return 1;
	}
	return 0;
}

# --- Pending payment approval/denial ---

approvepending(id: int): string
{
	pp := findpending(id);
	if(pp == nil || pp.result != nil)
		return "pending payment not found: " + string id;
	checkpendingexpiry(pp);
	if(pp.result != nil)
		return "pending payment expired: " + string id;

	as := findacct(pp.acct);
	if(as == nil)
		return "account not found: " + pp.acct;

	# The proposal was quoted, budget-checked, and shown to the
	# approver against one specific chain. If the active network has
	# changed since, approving it would settle somewhere the approver
	# never saw -- refuse rather than silently switch chains.
	active := "eip155:" + string getnetwork().chainid;
	if(pp.network != "" && pp.network != active) {
		pp.result = "error:network changed since proposal";
		return sys->sprint("payment %d was proposed on %s but the active network is now %s; it was not executed",
			id, pp.network, active);
	}

	if(pp.kind == "x402") {
		areq := ref AuthReq(pp.network, pp.token, pp.recipient,
			pp.amount, pp.timeout, pp.tokenname, pp.tokenver, pp.resource);
		(res, xerr) := executex402(as, areq);
		if(xerr != nil) {
			pp.result = "error:" + xerr;
			return "authorize: " + xerr;
		}
		pp.result = "approved:" + res;
		return nil;
	}

	txhash: string;
	payerr: string;
	if(pp.token == "usdc")
		(txhash, payerr) = executeerc20(as, pp.amount, pp.recipient);
	else
		(txhash, payerr) = executepayment(as, pp.amount, pp.recipient);
	if(payerr != nil) {
		pp.result = "error:" + payerr;
		return "pay: " + payerr;
	}
	pp.result = "approved:" + txhash;
	return nil;
}

denypending(id: int): string
{
	pp := findpending(id);
	if(pp == nil || pp.result != nil)
		return "pending payment not found: " + string id;
	pp.result = "denied";
	return nil;
}

readstr(srv: ref Styxserver, m: ref Tmsg.Read, s: string)
{
	data := array of byte s;
	if(m.offset >= big len data) {
		srv.reply(ref Rmsg.Read(m.tag, nil));
		return;
	}
	off := int m.offset;
	end := off + m.count;
	if(end > len data)
		end = len data;
	srv.reply(ref Rmsg.Read(m.tag, data[off:end]));
}

min(a, b: int): int
{
	if(a < b) return a;
	return b;
}

zeroarray(a: array of byte)
{
	if(a == nil)
		return;
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

# --- Debounced factotum sync ---
# Coalesces rapid sync requests (e.g. batch account imports)
# to avoid triggering expensive PAK handshake for each operation.

syncdebouncech: chan of int;

initsyncthread()
{
	syncdebouncech = chan of int;
	spawn syncdebouncethread();
}

syncfactotum()
{
	# Signal the debounce thread (non-blocking)
	if(syncdebouncech != nil)
		alt {
		syncdebouncech <-= 1 => ;
		* => ;
		}
}

syncdebouncethread()
{
	DEBOUNCE_MS: con 2000;	# wait 2 seconds for more syncs before committing
	for(;;) {
		<-syncdebouncech;
		# Got a sync request — wait for quiet period
		for(;;) {
			expired := 0;
			timer := chan of int;
			spawn synctimeout(timer, DEBOUNCE_MS);
			alt {
			<-syncdebouncech =>
				;	# another sync arrived, reset timer
			<-timer =>
				expired = 1;
			}
			if(expired)
				break;
		}
		# Quiet period expired — do the actual sync
		dosyncfactotum();
	}
}

synctimeout(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { ch <-= 1 => ; * => ; }
}

dosyncfactotum()
{
	fd := sys->open("/mnt/factotum/ctl", Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(stderr, "wallet9p: sync: cannot open factotum ctl: %r\n");
		return;
	}
	b := array of byte "sync";
	n := sys->write(fd, b, len b);
	if(n < 0)
		sys->fprint(stderr, "wallet9p: sync failed: %r\n");
	else
		sys->fprint(stderr, "wallet9p: sync OK\n");
}

# --- Account restoration from factotum ---

restoreaccounts()
{
	saved := wallet->listaccounts();
	for(; saved != nil; saved = tl saved) {
		acct := hd saved;
		# Skip if already loaded
		if(findacct(acct.name) != nil)
			continue;
		# Load full account info (derives address from factotum key)
		(fullacct, err) := wallet->loadaccount(acct.name);
		if(err != nil || fullacct == nil) {
			if(err != nil)
				sys->fprint(stderr, "wallet9p: skipping account %s: %s\n",
					acct.name, err);
			continue;
		}
		addaccount(fullacct);
		sys->fprint(stderr, "wallet9p: restored account: %s (%s)\n",
			fullacct.name, fullacct.address);
	}
}

# --- Network configuration ---

NetworkConfig: adt {
	name:	string;	# display name
	rpcurl:	string;	# JSON-RPC endpoint
	usdc:	string;	# USDC contract address
	chainid: int;	# EIP-155 chain ID
};

networks: array of ref NetworkConfig;
activenetwork := 0;

initnetworks()
{
	networks = array[4] of ref NetworkConfig;
	networks[0] = ref NetworkConfig("Ethereum Sepolia",
		"https://ethereum-sepolia-rpc.publicnode.com",
		"0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
		11155111);
	networks[1] = ref NetworkConfig("Base Sepolia",
		"https://sepolia.base.org",
		"0x036CbD53842c5426634e7929541eC2318f3dCF7e",
		84532);
	networks[2] = ref NetworkConfig("Ethereum Mainnet",
		"https://eth.llamarpc.com",
		"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
		1);
	networks[3] = ref NetworkConfig("Base",
		"https://mainnet.base.org",
		"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
		8453);
}

getnetwork(): ref NetworkConfig
{
	if(activenetwork >= 0 && activenetwork < len networks)
		return networks[activenetwork];
	return networks[0];
}

setnetwork(name: string)
{
	for(i := 0; i < len networks; i++) {
		if(networks[i].name == name) {
			activenetwork = i;
			ethrpc->setrpc(networks[i].rpcurl);
			sys->fprint(stderr, "wallet9p: network: %s (%s)\n",
				networks[i].name, networks[i].rpcurl);
			return;
		}
	}
	sys->fprint(stderr, "wallet9p: unknown network: %s\n", name);
}

# --- Balance query ---

querybalance(as: ref AcctState): string
{
	if(as.acct.accttype == Wallet->ACCT_STRIPE)
		return querystripebalance(as);
	if(as.acct.accttype != Wallet->ACCT_ETH)
		return "0";

	addr := as.acct.address;
	if(addr == "" || addr == nil)
		return "0";

	net := getnetwork();

	# Try USDC token balance
	(tokbal, tokerr) := ethrpc->tokenbalance(net.usdc, addr);
	usdcstr := "0";
	if(tokerr != nil) {
		sys->fprint(stderr, "wallet9p: %s USDC balance: %s\n", net.name, tokerr);
		usdcstr = "?";
	} else if(tokbal != nil && tokbal != "0")
		usdcstr = ethrpc->weitotoken(tokbal, 6);	# USDC has 6 decimals

	# Also get native ETH balance
	(ethbal, etherr) := ethrpc->getbalance(addr);
	ethstr := "0";
	if(etherr != nil) {
		sys->fprint(stderr, "wallet9p: %s ETH balance: %s\n", net.name, etherr);
		ethstr = "?";
	} else if(ethbal != nil && ethbal != "0")
		ethstr = ethrpc->weitoeth(ethbal);

	# If both queries failed, report the network error
	if(tokerr != nil && etherr != nil)
		return net.name + ": RPC error";

	result := "";
	if(usdcstr != "0")
		result += usdcstr + " USDC";
	if(ethstr != "0") {
		if(result != "")
			result += ", ";
		result += ethstr + " ETH";
	}
	if(result == "")
		result = "0 USDC, 0 ETH";
	return result;
}

# --- Payment execution ---

# x402 authorization request (parsed from the authorize file)
AuthReq: adt {
	network:   string;
	asset:     string;
	payto:     string;
	amount:    string;
	timeout:   int;
	tokenname: string;
	tokenver:  string;
	resource:  string;
};

#
# Budget enforcement.  If a budget is configured for the account it is
# a hard cap: the payment's currency must match the budget currency
# and the amount must pass per-tx and per-session limits.  A budget in
# a different currency fails closed — it cannot be evaluated.
# With no budget configured, the approval gate is the control.
#
budgeterr(as: ref AcctState, currency: string, amt: array of byte): string
{
	b := wallet->budgetfor(as.acct);
	if(b == nil)
		return nil;
	if(b.currency != currency)
		return "budget is in " + b.currency + "; cannot evaluate a " +
			currency + " payment against it";
	return wallet->checkbudget(as.acct, amt);
}

recordspendamt(as: ref AcctState, amt: array of byte)
{
	wallet->recordspend(as.acct, amt);
}

# Append a timestamped history entry, capped at MAXHISTORY
addhistory(as: ref AcctState, entry: string)
{
	as.history = (sys->sprint("%bd ", now()) + entry) :: as.history;
	as.nhistory++;
	if(as.nhistory > MAXHISTORY) {
		# drop the oldest entry (last in the list)
		nl: list of string;
		n := 0;
		for(l := as.history; l != nil && n < MAXHISTORY; l = tl l) {
			nl = hd l :: nl;
			n++;
		}
		as.history = nil;
		for(; nl != nil; nl = tl nl)
			as.history = hd nl :: as.history;
		as.nhistory = n;
	}
}

#
# The chain ID used for signing comes from the local network
# configuration, never from the RPC endpoint.  The endpoint is
# cross-checked and a mismatch refuses to sign: a malicious or
# misconfigured RPC must not be able to move a payment to a
# different chain.
#
confirmchainid(net: ref NetworkConfig): string
{
	(rpcid, err) := ethrpc->chainid();
	if(err != nil)
		return "cannot confirm chain id: " + err;
	if(rpcid != net.chainid)
		return sys->sprint("RPC chain id %d does not match configured network %s (%d); refusing to sign",
			rpcid, net.name, net.chainid);
	return nil;
}

# Validate a pay request without executing it.  Must be at least as
# strict as the execution path: anything that would fail after human
# approval has to be rejected at submission time instead.
#
# validamount() rejects anything that is not a positive integer — notably
# ZERO, which is never a legitimate payment proposal and which a plain
# base-unit parse would happily accept.
validatepay(as: ref AcctState, token, amount, recipient: string): string
{
	if(!validamount(amount))
		return "invalid payment amount";

	if(as.acct.accttype == Wallet->ACCT_STRIPE) {
		# For Stripe the "recipient" is a human-readable description
		# that reaches an external API: bound it and reject control
		# characters.
		if(recipient == nil || recipient == "" || len recipient > 256 ||
		   hascontrol(recipient))
			return "invalid payment description";
		# mirror executestripepayment exactly (strint, positive)
		(cents, ok) := strint(amount);
		if(!ok || cents <= 0)
			return "invalid amount (cents, up to 9 digits): " + amount;
		return budgeterr(as, "USD", ethcrypto->dectobe(amount));
	}

	if(as.acct.accttype != Wallet->ACCT_ETH)
		return "only ETH and Stripe accounts can send payments";
	amt := ethcrypto->dectobe(amount);
	if(amt == nil)
		return "invalid amount (must be integer base units): " + amount;
	if(ethcrypto->strtoaddr(recipient) == nil)
		return "invalid recipient address: " + recipient;
	cur := "ETH";
	if(token == "usdc")
		cur = "USDC";
	return budgeterr(as, cur, amt);
}

executepayment(as: ref AcctState, amount: string, recipient: string): (string, string)
{
	if(as.acct.accttype == Wallet->ACCT_STRIPE)
		return executestripepayment(as, amount, recipient);
	if(as.acct.accttype != Wallet->ACCT_ETH)
		return (nil, "only ETH and Stripe accounts can send payments");

	addr := as.acct.address;
	if(addr == "" || addr == nil)
		return (nil, "account has no address");

	# Amount is wei as a strict decimal string (uint256)
	amt := ethcrypto->dectobe(amount);
	if(amt == nil)
		return (nil, "invalid amount (must be integer wei): " + amount);

	dstaddr := ethcrypto->strtoaddr(recipient);
	if(dstaddr == nil)
		return (nil, "invalid recipient address: " + recipient);

	# Budget is enforced on every execution path, including approvals
	berr := budgeterr(as, "ETH", amt);
	if(berr != nil)
		return (nil, "budget: " + berr);

	net := getnetwork();
	cerr := confirmchainid(net);
	if(cerr != nil)
		return (nil, cerr);

	# Get nonce
	(nonce, nonceerr) := ethrpc->getnonce(addr);
	if(nonceerr != nil)
		return (nil, "nonce: " + nonceerr);

	# Query network gas price, fall back to 1 gwei
	gasprice := big 1000000000;	# fallback: 1 gwei
	{
		(gpstr, gperr) := ethrpc->gasprice();
		if(gperr == nil && gpstr != nil && gpstr != "0") {
			(gp, gok) := strbig(gpstr);
			if(gok)
				gasprice = gp;
		}
	}
	# Cap at 100 gwei to prevent fee spikes
	if(gasprice > big 100000000000)
		gasprice = big 100000000000;
	gaslimit := big 21000;	# standard ETH transfer

	tx := ref Ethcrypto->EthTx(
		big nonce,
		gasprice,
		gaslimit,
		dstaddr,
		amt,
		nil,		# no data (simple transfer)
		net.chainid
	);

	# Retrieve private key from factotum, sign the full tx, zero key
	svc := "wallet-eth-" + as.acct.name;
	(nil, password) := factotum->getuserpasswd("proto=pass service=" + svc);
	if(password == nil || password == "")
		return (nil, "no key in factotum for " + as.acct.name);

	privkey := ethcrypto->hexdecode(password);
	if(privkey == nil || len privkey != 32)
		return (nil, "invalid key in factotum");

	rawtx := ethcrypto->signtx(tx, privkey);
	# Zero key immediately
	for(i := 0; i < len privkey; i++)
		privkey[i] = byte 0;

	if(rawtx == nil)
		return (nil, "transaction signing failed");

	# Submit to network
	hextx := ethcrypto->hexencode(rawtx);
	(txhash, senderr) := ethrpc->sendrawtx(hextx);
	if(senderr != nil)
		return (nil, "send: " + senderr);

	recordspendamt(as, amt);
	addhistory(as, "pay eth " + amount + " " + recipient + " " + txhash);
	return (txhash, nil);
}

#
# ERC-20 transfer: sends tokens by calling transfer(address,uint256) on the token contract
#
executeerc20(as: ref AcctState, amount: string, recipient: string): (string, string)
{
	if(as.acct.accttype != Wallet->ACCT_ETH)
		return (nil, "only ETH accounts can send ERC-20");

	addr := as.acct.address;
	if(addr == "" || addr == nil)
		return (nil, "account has no address");

	net := getnetwork();

	recipaddr := ethcrypto->strtoaddr(recipient);
	if(recipaddr == nil)
		return (nil, "invalid recipient: " + recipient);

	# Amount is in token base units (USDC = 6 decimals, so 1 USDC = 1000000)
	amtbytes := ethcrypto->dectobe(amount);
	if(amtbytes == nil)
		return (nil, "invalid amount (must be integer base units): " + amount);

	berr := budgeterr(as, "USDC", amtbytes);
	if(berr != nil)
		return (nil, "budget: " + berr);

	cerr := confirmchainid(net);
	if(cerr != nil)
		return (nil, cerr);

	# Get nonce
	(nonce, nonceerr) := ethrpc->getnonce(addr);
	if(nonceerr != nil)
		return (nil, "nonce: " + nonceerr);

	# Build transfer(address,uint256) calldata:
	# selector(4) + address(32) + amount(32) = 68 bytes
	calldata := array[68] of byte;
	for(i := 0; i < 68; i++)
		calldata[i] = byte 0;
	# Function selector a9059cbb
	calldata[0] = byte 16ra9;
	calldata[1] = byte 16r05;
	calldata[2] = byte 16r9c;
	calldata[3] = byte 16rbb;
	# Recipient address, left-padded to 32 bytes
	calldata[16:] = recipaddr;
	# Amount, left-padded to 32 bytes (dectobe guarantees <= 32 bytes)
	calldata[68 - len amtbytes:] = amtbytes;

	# Gas for ERC-20 transfer is higher than simple ETH
	# Query network gas price, fall back to 1 gwei
	gasprice := big 1000000000;	# fallback: 1 gwei
	{
		(gpstr, gperr) := ethrpc->gasprice();
		if(gperr == nil && gpstr != nil && gpstr != "0") {
			(gp, gok) := strbig(gpstr);
			if(gok)
				gasprice = gp;
		}
	}
	# Cap at 100 gwei to prevent fee spikes
	if(gasprice > big 100000000000)
		gasprice = big 100000000000;
	gaslimit := big 100000;	# ERC-20 transfers need ~65000 gas

	# Transaction goes TO the token contract, with 0 ETH value
	tokenaddr := ethcrypto->strtoaddr(net.usdc);
	if(tokenaddr == nil)
		return (nil, "invalid token contract address");

	tx := ref Ethcrypto->EthTx(
		big nonce,
		gasprice,
		gaslimit,
		tokenaddr,	# send to token contract
		nil,		# 0 ETH value
		calldata,	# transfer(recipient, amount)
		net.chainid
	);

	# Sign
	svc := "wallet-eth-" + as.acct.name;
	(nil, password) := factotum->getuserpasswd("proto=pass service=" + svc);
	if(password == nil || password == "")
		return (nil, "no key in factotum for " + as.acct.name);

	privkey := ethcrypto->hexdecode(password);
	if(privkey == nil || len privkey != 32)
		return (nil, "invalid key in factotum");

	rawtx := ethcrypto->signtx(tx, privkey);
	for(i = 0; i < len privkey; i++)
		privkey[i] = byte 0;

	if(rawtx == nil)
		return (nil, "transaction signing failed");

	# Submit
	hextx := ethcrypto->hexencode(rawtx);
	(txhash, senderr) := ethrpc->sendrawtx(hextx);
	if(senderr != nil)
		return (nil, "send: " + senderr);

	recordspendamt(as, amtbytes);
	addhistory(as, "pay usdc " + amount + " " + recipient + " " + txhash);
	return (txhash, nil);
}

# --- x402 authorization (EIP-3009 TransferWithAuthorization) ---

#
# Parse an authorize request: newline-separated "key value" lines.
# name/version take the rest of the line (token names contain spaces).
#
parseauthreq(data: string): (ref AuthReq, string)
{
	req := ref AuthReq("", "", "", "", 0, "", "", "");
	# A repeated key must be an error, never last-wins: the request is
	# built from a remote server's 402 response, and a newline smuggled
	# into any field would otherwise let a later "payto"/"amount" line
	# silently override the one the client validated and displayed.
	seen: list of string;
	(nil, lines) := sys->tokenize(data, "\n\r");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		(key, val) := str->splitstrl(line, " ");
		if(val == nil)
			continue;
		val = val[1:];	# skip the separator
		if(inlist(key, seen))
			return (nil, "duplicate field: " + key);
		seen = key :: seen;
		case key {
		"scheme" =>
			if(val != "exact")
				return (nil, "unsupported scheme");
		"network" =>	req.network = val;
		"asset" =>	req.asset = val;
		"payto" =>	req.payto = val;
		"amount" =>	req.amount = val;
		"timeout" =>
			(t, ok) := strint(val);
			if(!ok)
				return (nil, "bad timeout");
			req.timeout = t;
		"name" =>	req.tokenname = val;
		"version" =>	req.tokenver = val;
		"resource" =>
			if(len val <= 1024)
				req.resource = val;
		* =>
			return (nil, "unknown field");
		}
	}
	if(req.network == "" || req.asset == "" || req.payto == "" || req.amount == "")
		return (nil, "missing required field (network/asset/payto/amount)");
	# clamp validity window
	if(req.timeout < 30)
		req.timeout = 30;
	if(req.timeout > 3600)
		req.timeout = 3600;
	return (req, nil);
}

#
# Validate an authorization request against the active network and
# the account's budget, without signing anything.
#
validateauth(as: ref AcctState, req: ref AuthReq): string
{
	if(as.acct.accttype != Wallet->ACCT_ETH)
		return "only ETH accounts can authorize x402 payments";
	if(as.acct.address == nil || as.acct.address == "")
		return "account has no address";

	net := getnetwork();
	netid := x402mod->networktochainid(req.network);
	if(netid != net.chainid)
		return sys->sprint("request network %s does not match active network %s (eip155:%d)",
			req.network, net.name, net.chainid);

	if(ethcrypto->strtoaddr(req.asset) == nil)
		return "invalid asset address";
	if(ethcrypto->strtoaddr(req.payto) == nil)
		return "invalid payto address";
	amt := ethcrypto->dectobe(req.amount);
	if(amt == nil)
		return "invalid amount (must be integer base units)";
	if(req.tokenname == "" || len req.tokenname > 64 || len req.tokenver > 16)
		return "invalid token name/version";

	return budgeterr(as, assetcurrency(req.asset), amt);
}

# Map an asset contract address to a budget currency name.
# Only the active network's USDC contract is recognized; anything else
# fails closed against a configured budget.
assetcurrency(asset: string): string
{
	net := getnetwork();
	if(hexeq(asset, net.usdc))
		return "USDC";
	return "token:" + asset;
}

hexeq(a, b: string): int
{
	return str->tolower(a) == str->tolower(b);
}

#
# Sign an EIP-3009 authorization.  wallet9p generates the nonce and
# validity window and computes the EIP-712 digest itself, so the key
# only ever signs messages this server constructed.
#
executex402(as: ref AcctState, req: ref AuthReq): (string, string)
{
	verr := validateauth(as, req);
	if(verr != nil)
		return (nil, verr);

	amt := ethcrypto->dectobe(req.amount);

	nonce := array[32] of byte;
	if(randfill(nonce) < 0)
		return (nil, "no entropy source for nonce generation");

	nowt := now();
	if(nowt <= big 0)
		return (nil, "no time source for validity window");
	validafter := nowt - big 600;	# tolerate clock skew
	if(validafter < big 0)
		validafter = big 0;
	validbefore := nowt + big req.timeout;

	(digest, derr) := x402mod->authdigest(req.network, req.asset, req.payto,
		as.acct.address, req.amount, validafter, validbefore, nonce,
		req.tokenname, req.tokenver);
	if(derr != nil)
		return (nil, "digest: " + derr);

	(sig, serr) := wallet->signhash(as.acct, digest);
	if(serr != nil)
		return (nil, "sign: " + serr);
	if(sig == nil || len sig != 65)
		return (nil, "sign: malformed signature");

	recordspendamt(as, amt);
	addhistory(as, "x402 " + req.amount + " " + req.asset + " " + req.payto);

	res := "sig " + ethcrypto->hexencode(sig) +
		" from " + as.acct.address +
		" nonce " + ethcrypto->hexencode(nonce) +
		sys->sprint(" validafter %bd validbefore %bd", validafter, validbefore);
	return (res, nil);
}

# --- Stripe fiat backend ---

initstripe(acctname: string): string
{
	if(stripemod != nil)
		return nil;	# already initialized

	svc := "wallet-stripe-" + acctname;
	(nil, apikey) := factotum->getuserpasswd("proto=pass service=" + svc);
	if(apikey == nil || apikey == "")
		return "no Stripe API key in factotum for " + acctname;

	stripemod = load Stripe Stripe->PATH;
	if(stripemod == nil)
		return sys->sprint("cannot load Stripe: %r");

	return stripemod->init(apikey);
}

querystripebalance(as: ref AcctState): string
{
	err := initstripe(as.acct.name);
	if(err != nil)
		return "Stripe: " + err;

	(bal, berr) := stripemod->balance();
	if(berr != nil)
		return "Stripe: " + berr;
	return bal;
}

executestripepayment(as: ref AcctState, amount: string, description: string): (string, string)
{
	err := initstripe(as.acct.name);
	if(err != nil)
		return (nil, "Stripe: " + err);

	(cents, ok) := strint(amount);
	if(!ok || cents <= 0)
		return (nil, "invalid amount: " + amount);

	berr := budgeterr(as, "USD", ethcrypto->dectobe(amount));
	if(berr != nil)
		return (nil, "budget: " + berr);

	(id, perr) := stripemod->createpayment(cents, "usd", description);
	if(perr != nil)
		return (nil, "Stripe: " + perr);

	recordspendamt(as, ethcrypto->dectobe(amount));
	addhistory(as, "pay usd-cents " + amount + " " + description);
	return (id, nil);
}

# --- Navigator ---

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			ft := FTYPE(n.path);
			name := n.name;

			if(ft == Qroot) {
				# Root directory entries
				if(name == "ctl")
					n.path = MKPATH(0, Qctl);
				else if(name == "accounts")
					n.path = MKPATH(0, Qaccounts);
				else if(name == "default")
					n.path = MKPATH(0, Qdefault);
				else if(name == "new")
					n.path = MKPATH(0, Qnew);
				else if(name == "pending")
					n.path = MKPATH(0, Qpending);
				else if(name == "network")
					n.path = MKPATH(0, Qnetwork);
				else {
					# Look for account name
					id := acctidbyname(name);
					if(id >= 0)
						n.path = MKPATH(id, Qacctdir);
					else {
						n.reply <-= (nil, Enotfound);
						continue;
					}
				}
			} else if(ft == Qacctdir) {
				aid := ACCTID(n.path);
				if(name == "address")
					n.path = MKPATH(aid, Qaddress);
				else if(name == "balance")
					n.path = MKPATH(aid, Qbalance);
				else if(name == "chain")
					n.path = MKPATH(aid, Qchain);
				else if(name == "pay")
					n.path = MKPATH(aid, Qpay);
				else if(name == "authorize")
					n.path = MKPATH(aid, Qauthorize);
				else if(name == "ctl")
					n.path = MKPATH(aid, Qacctctl);
				else if(name == "history")
					n.path = MKPATH(aid, Qhistory);
				else {
					n.reply <-= (nil, Enotfound);
					continue;
				}
			} else if(name == "..") {
				if(ft >= Qacctdir && ft <= Qauthorize)
					n.path = MKPATH(ACCTID(n.path), Qacctdir);
				else
					n.path = MKPATH(0, Qroot);
			} else {
				n.reply <-= (nil, Enotfound);
				continue;
			}
			n.reply <-= dirgen(n.path);

		Readdir =>
			ft := FTYPE(n.path);
			entries: list of big;

			if(ft == Qroot) {
				# Root: ctl, accounts, new, pending, network, then account dirs
				entries = MKPATH(0, Qnetwork) :: entries;
				entries = MKPATH(0, Qpending) :: entries;
				entries = MKPATH(0, Qnew) :: entries;
				entries = MKPATH(0, Qdefault) :: entries;
				entries = MKPATH(0, Qaccounts) :: entries;
				entries = MKPATH(0, Qctl) :: entries;
				for(l := accounts; l != nil; l = tl l)
					entries = MKPATH((hd l).id, Qacctdir) :: entries;
			} else if(ft == Qacctdir) {
				aid := ACCTID(n.path);
				entries =
					MKPATH(aid, Qaddress) ::
					MKPATH(aid, Qbalance) ::
					MKPATH(aid, Qchain) ::
					MKPATH(aid, Qpay) ::
					MKPATH(aid, Qauthorize) ::
					MKPATH(aid, Qacctctl) ::
					MKPATH(aid, Qhistory) ::
					nil;
			}

			# Reverse to correct order
			ordered: list of big;
			for(el := entries; el != nil; el = tl el)
				ordered = hd el :: ordered;

			# Emit entries
			k := 0;
			for(ol := ordered; ol != nil; ol = tl ol) {
				if(k >= n.offset + n.count)
					break;
				if(k >= n.offset) {
					(d, e) := dirgen(hd ol);
					n.reply <-= (d, e);
				}
				k++;
			}
			n.reply <-= (nil, nil);
		}
	}
}

dirgen(p: big): (ref Sys->Dir, string)
{
	ft := FTYPE(p);
	aid := ACCTID(p);

	name := "";
	perm := 8r444;
	qtype := Sys->QTFILE;

	case ft {
	Qroot =>
		name = "/";
		perm = Sys->DMDIR | 8r555;
		qtype = Sys->QTDIR;
	Qctl =>
		name = "ctl";
		perm = 8r666;
	Qaccounts =>
		name = "accounts";
	Qdefault =>
		name = "default";
	Qnew =>
		name = "new";
		perm = 8r666;
	Qpending =>
		name = "pending";
		perm = 8r444;
	Qnetwork =>
		name = "network";
		perm = 8r444;
	Qacctdir =>
		as := findacctbyid(aid);
		if(as != nil)
			name = as.acct.name;
		else
			name = string aid;
		perm = Sys->DMDIR | 8r555;
		qtype = Sys->QTDIR;
	Qaddress =>
		name = "address";
	Qbalance =>
		name = "balance";
	Qchain =>
		name = "chain";
		perm = 8r666;
	Qpay =>
		name = "pay";
		perm = 8r666;
	Qauthorize =>
		name = "authorize";
		perm = 8r666;
	Qacctctl =>
		name = "ctl";
		perm = 8r666;
	Qhistory =>
		name = "history";
	* =>
		return (nil, Enotfound);
	}

	d := ref sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid = Qid(p, vers, qtype);
	d.mode = perm;
	d.length = big 0;

	return (d, nil);
}
