implement WmWallet;

#
# wallet - Crypto/fiat wallet manager for Lucifer (Tk version)
#
# A GUI front-end to wallet9p (/n/wallet). Lists accounts, shows address
# and balance, transaction history, and sends payments. Private keys live
# in factotum behind wallet9p; this app only drives the ctl interface.
#
# Two panes: account list (left), details / forms (right). Styled by the
# brutalist Tk defaults.
#
# Mouse:  B1 select / interact   B3 context menu
# Keys:   Tab next field, Enter submit, Escape cancel, Ctrl-Q quit
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "string.m";
	str: String;

include "lucitheme.m";
	lucitheme: Lucitheme;
	Theme: import lucitheme;

WmWallet: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# ── Account ───────────────────────────────────────────────────

AcctInfo: adt {
	name:    string;
	chain:   string;
	address: string;
};

# ── Modes ─────────────────────────────────────────────────────

ModeView, ModeNewETH, ModeImport, ModePay, ModePending: con iota;

Field: adt {
	path:    string;
	label:   string;
	secret:  int;
	prefill: string;
};

# Networks offered by the View-pane dropdown.
networks := array[] of { "Ethereum Sepolia", "Base Sepolia", "Ethereum Mainnet", "Base" };

# ── State ─────────────────────────────────────────────────────

top:    ref Toplevel;
wmctl:  chan of string;
actch:  chan of string;
balancech: chan of int;
pendingch: chan of int;
themech:   chan of int;
stderr: ref Sys->FD;

accts:  array of ref AcctInfo;
selacct: int;		# index into accts, -1 = none
mode:   int;
fields: array of ref Field;	# fields of the current form
focusi: int;
cachedbalance: string;
pendingcount: int;
historyraw: list of string;
accent: string;
dim:    string;
bgc:      string;	# theme background
statusbg: string;	# status-strip background
statusfg: string;	# status-strip foreground

WALLET: con "/n/wallet";
LBLW:   con 96;		# pixel width of the aligned label column

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	str = load String String->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	stderr = sys->fildes(2);
	if(tkclient == nil){
		sys->fprint(stderr, "wallet: cannot load tkclient: %r\n");
		raise "fail:load tkclient";
	}
	lucitheme = load Lucitheme Lucitheme->PATH;

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(stderr, "wallet: no window context\n");
		raise "fail:no context";
	}

	loadtheme();
	ensurewallet9p();

	(top, wmctl) = tkclient->toplevel(ctxt, "-width 520 -height 400",
		"Wallet", Tkclient->Appl);

	actch = chan[8] of string;
	tk->namechan(top, actch, "act");
	balancech = chan[1] of int;
	pendingch = chan[1] of int;
	themech = chan[1] of int;

	selacct = -1;
	mode = ModeView;
	buildbase();
	refreshaccounts();
	setmode(ModeView);

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	spawn themelistener();
	spawn balancetimer();
	spawn pendingwatcher();

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	# top.wreq carries Tk window requests (menu posts create their
	# window through here); a loop that never drains it leaves every
	# posted menu mapped-and-grabbing but windowless — invisible.
	c = <-top.wreq =>
		tkclient->wmctl(top, c);

	k := <-top.ctxt.kbd =>
		handlekey(k);

	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);

	a := <-actch =>
		handleaction(a);

	<-balancech =>
		if(mode == ModeView)
			showbalance();

	n := <-pendingch =>
		pendingcount = n;
		if(n > 0)
			setstatus(sys->sprint("%d pending payment%s — B3 menu to review", n, plural(n)));

	<-themech =>
		loadtheme();
		# Re-theme env-derived widget colours, then reconfigure the widgets
		# carrying explicit theme colours (were hardcoded brimstone and never
		# updated, so the whole pane stayed dark after a switch).
		tkclient->wmctl(top, "retheme");
		tk->cmd(top, ". configure -background " + bgc);
		tk->cmd(top, ".main.div configure -background " + accent);
		tk->cmd(top, ".status configure -background " + statusbg + " -foreground " + statusfg);
		setmode(mode);
	}
}

# ── Base two-pane layout ──────────────────────────────────────

buildbase()
{
	cmds := array[] of {
		". configure -background " + bgc,
		"frame .main",
		"frame .main.list",
		"scrollbar .main.list.sb -command {.main.list.lb yview}",
		"listbox .main.list.lb -yscrollcommand {.main.list.sb set} -width 160 -selectmode single",
		"pack .main.list.sb -side right -fill y",
		"pack .main.list.lb -side left -fill both -expand 1",
		"frame .main.div -width 1 -background " + accent,
		"frame .main.right",
		"pack .main.list -side left -fill y",
		"pack .main.div -side left -fill y",
		"pack .main.right -side left -fill both -expand 1",
		"label .status -anchor w -background " + statusbg + " -foreground " + statusfg,
		"pack .main -side top -fill both -expand 1",
		"pack .status -side bottom -fill x",
		"pack propagate . 0",
		"bind .main.list.lb <ButtonRelease-1> {send act selectacct}",
		"bind .main.list.lb <Button-3> {send act mainmenu %X %Y}",
	};
	tkcmds(cmds);
	buildmenus();
}

buildmenus()
{
	tk->cmd(top, "menu .mainmenu");
	tk->cmd(top, ".mainmenu add command -label {New Ethereum Account} -command {send act new}");
	tk->cmd(top, ".mainmenu add command -label {Import Private Key} -command {send act import}");
	tk->cmd(top, ".mainmenu add separator");
	tk->cmd(top, ".mainmenu add command -label {Pending Payments} -command {send act pending}");
	tk->cmd(top, ".mainmenu add command -label {Refresh} -command {send act refresh}");
	tk->cmd(top, "menu .detailmenu");
	tk->cmd(top, ".detailmenu add command -label {Send Payment} -command {send act pay}");
	tk->cmd(top, ".detailmenu add command -label {Copy Address} -command {send act copyaddr}");
	tk->cmd(top, ".detailmenu add command -label {Copy Account Name} -command {send act copyname}");
	tk->cmd(top, ".detailmenu add command -label {Copy Tx Hash} -command {send act copytx}");
	tk->cmd(top, ".detailmenu add command -label {Refresh Balance} -command {send act refreshbal}");
}

# ── Right pane per mode ───────────────────────────────────────

setmode(m: int)
{
	mode = m;
	focusi = 0;
	fields = array[0] of ref Field;
	tk->cmd(top, "destroy .main.right");
	tk->cmd(top, "frame .main.right");
	tk->cmd(top, "pack .main.right -side left -fill both -expand 1");
	tk->cmd(top, "bind .main.right <Button-3> {send act detailmenu %X %Y}");

	case m {
	ModeView =>
		buildview();
	ModeNewETH =>
		buildform("New Ethereum Account",
			array[] of {
				ref Field("", "Name:",  0, ""),
				ref Field("", "Chain:", 0, "ethereum"),
			}, "Create", "create");
	ModeImport =>
		buildform("Import Private Key",
			array[] of {
				ref Field("", "Name:",  0, ""),
				ref Field("", "Chain:", 0, "ethereum"),
				ref Field("", "Key:",   1, ""),
			}, "Import", "doimport");
	ModePay =>
		buildpay();
	ModePending =>
		buildpending();
	}
	tk->cmd(top, "update");
}

# ── Pending payment review (approve/deny) ─────────────────────

buildpending()
{
	r := ".main.right";
	tk->cmd(top, "label " + r + ".title -text {Pending Payments}");
	tk->cmd(top, "pack " + r + ".title -side top -anchor w -padx 12 -pady {8 4}");

	raw := readwalletfile("", "pending");
	(nil, lines) := sys->tokenize(raw, "\n");
	nrows := 0;
	for(; lines != nil; lines = tl lines){
		ln := strip(hd lines);
		if(ln == "" || ln == "(none)")
			continue;
		# "<id> <kind> <acct> <token> <amount> <recipient> <network> <agent>"
		(ntoks, toks) := sys->tokenize(ln, " \t");
		if(ntoks < 7)
			continue;
		id := hd toks;
		kind := hd tl toks;
		acct := hd tl tl toks;
		token := hd tl tl tl toks;
		amount := hd tl tl tl tl toks;
		recip := hd tl tl tl tl tl toks;
		net := hd tl tl tl tl tl tl toks;

		# The network is part of what is being approved: the same
		# amount settles very differently on a testnet and on mainnet.
		desc := acct + ": " + amount + " " + token + " -> " + recip + " [" + net + "]";
		if(kind == "x402")
			desc = acct + ": x402 " + amount + " of " + token + " -> " + recip + " [" + net + "]";
		if(len desc > 76)
			desc = desc[0:76] + "...";

		f := r + sys->sprint(".p%d", nrows);
		tk->cmd(top, "frame " + f);
		tk->cmd(top, "label " + f + ".l -text {#" + id + " " + desc + "}");
		tk->cmd(top, "button " + f + ".ok -text {Approve} -command {send act approve " + id + "}");
		tk->cmd(top, "button " + f + ".no -text {Deny} -command {send act deny " + id + "}");
		tk->cmd(top, "pack " + f + ".l -side left -padx {12 8}");
		tk->cmd(top, "pack " + f + ".no -side right -padx {4 12}");
		tk->cmd(top, "pack " + f + ".ok -side right -padx 4");
		tk->cmd(top, "pack " + f + " -side top -fill x -pady 2");
		nrows++;
	}
	if(nrows == 0){
		tk->cmd(top, "label " + r + ".none -text {No pending payments} -foreground " + dim);
		tk->cmd(top, "pack " + r + ".none -side top -anchor w -padx 12 -pady 8");
	}
	tk->cmd(top, "button " + r + ".back -text {Back} -command {send act cancel}");
	tk->cmd(top, "pack " + r + ".back -side top -anchor w -padx 12 -pady {8 4}");
}

doapprove(id: string)
{
	if(writewalletctl("ctl", "approve " + id) <= 0)
		setstatus(errmsg("approve failed"));
	else
		setstatus("Payment " + id + " approved");
	setmode(ModePending);
}

dodeny(id: string)
{
	if(writewalletctl("ctl", "deny " + id) <= 0)
		setstatus(errmsg("deny failed"));
	else
		setstatus("Payment " + id + " denied");
	setmode(ModePending);
}

buildview()
{
	r := ".main.right";
	tk->cmd(top, "frame " + r + ".net");
	tk->cmd(top, sys->sprint("label %s.net.l -text {Network:} -width %d -anchor w", r, LBLW));
	vals := "";
	for(i := 0; i < len networks; i++)
		vals += "{" + networks[i] + "} ";
	tk->cmd(top, "choicebutton " + r + ".net.cb -values {" + vals + "} -command {send act netchange}");
	tk->cmd(top, "pack " + r + ".net.l -side left -padx {12 4} -pady {8 2}");
	tk->cmd(top, "pack " + r + ".net.cb -side left -pady {8 2}");
	tk->cmd(top, "pack " + r + ".net -side top -fill x -anchor w");

	if(selacct < 0 || selacct >= len accts){
		tk->cmd(top, "label " + r + ".sel -text {Select an account} -foreground " + dim);
		tk->cmd(top, "pack " + r + ".sel -side top -anchor w -padx 12 -pady 12");
		return;
	}
	a := accts[selacct];
	addr := a.address;
	if(addr == "")
		addr = "(not available)";
	rows := array[] of {
		("name",   a.name,     accent),
		("chainl", "Chain:",   dim),
		("chain",  a.chain,    ""),
		("addrl",  "Address:", dim),
		("addr",   addr,       ""),
		("ball",   "Balance:", dim),
	};
	for(i = 0; i < len rows; i++){
		(id, txt, fg) := rows[i];
		fgopt := "";
		if(fg != "")
			fgopt = " -foreground " + fg;
		tk->cmd(top, sys->sprint("label %s.%s -text {%s} -anchor w%s", r, id, txt, fgopt));
		tk->cmd(top, sys->sprint("pack %s.%s -side top -anchor w -padx 12", r, id));
	}
	tk->cmd(top, "label " + r + ".bal1 -text {loading...} -anchor w");
	tk->cmd(top, "label " + r + ".bal2 -text {} -anchor w");
	tk->cmd(top, "pack " + r + ".bal1 -side top -anchor w -padx 24");
	tk->cmd(top, "pack " + r + ".bal2 -side top -anchor w -padx 24");

	tk->cmd(top, "button " + r + ".send -text {Send Payment} -command {send act pay}");
	tk->cmd(top, "pack " + r + ".send -side top -anchor w -padx 12 -pady 8");

	tk->cmd(top, "label " + r + ".histl -text {Recent Transactions:} -foreground " + dim + " -anchor w");
	tk->cmd(top, "pack " + r + ".histl -side top -anchor w -padx 12");
	tk->cmd(top, "frame " + r + ".hist");
	tk->cmd(top, "scrollbar " + r + ".hist.sb -command {" + r + ".hist.lb yview}");
	tk->cmd(top, "listbox " + r + ".hist.lb -yscrollcommand {" + r + ".hist.sb set}");
	tk->cmd(top, "pack " + r + ".hist.sb -side right -fill y");
	tk->cmd(top, "pack " + r + ".hist.lb -side left -fill both -expand 1");
	tk->cmd(top, "pack " + r + ".hist -side top -fill both -expand 1 -padx 12 -pady {0 8}");
	loadhistory(a.name);

	cachedbalance = "loading...";
	showbalance();
	spawn fetchbalance(a.name);
}

buildform(title: string, flds: array of ref Field, oklabel, oktok: string)
{
	r := ".main.right";
	tk->cmd(top, sys->sprint("label %s.title -text {%s} -foreground %s -anchor w", r, title, accent));
	tk->cmd(top, "pack " + r + ".title -side top -anchor w -padx 12 -pady {12 6}");
	fields = flds;
	for(i := 0; i < len flds; i++){
		f := flds[i];
		row := sys->sprint("%s.r%d", r, i);
		tk->cmd(top, "frame " + row);
		tk->cmd(top, sys->sprint("label %s.l -text {%s} -width %d -anchor w", row, f.label, LBLW));
		show := "";
		if(f.secret)
			show = " -show *";
		tk->cmd(top, sys->sprint("entry %s.e -width 220%s", row, show));
		if(f.prefill != "")
			tk->cmd(top, sys->sprint("%s.e insert 0 {%s}", row, f.prefill));
		tk->cmd(top, sys->sprint("pack %s.l -side left -padx {12 4}", row));
		tk->cmd(top, sys->sprint("pack %s.e -side left -fill x -expand 1 -padx {0 12}", row));
		tk->cmd(top, "pack " + row + " -side top -fill x -pady 2");
		f.path = row + ".e";
	}
	tk->cmd(top, "frame " + r + ".btns");
	tk->cmd(top, sys->sprint("button %s.btns.ok -text {%s} -command {send act %s}", r, oklabel, oktok));
	tk->cmd(top, "button " + r + ".btns.cancel -text {Cancel} -command {send act cancel}");
	tk->cmd(top, "pack " + r + ".btns.ok -side left -padx {12 4} -pady 8");
	tk->cmd(top, "pack " + r + ".btns.cancel -side left -pady 8");
	tk->cmd(top, "pack " + r + ".btns -side top -fill x");
	setfocus(0);
}

buildpay()
{
	r := ".main.right";
	from := "";
	if(selacct >= 0 && selacct < len accts)
		from = accts[selacct].name;
	tk->cmd(top, sys->sprint("label %s.title -text {Send from: %s} -foreground %s -anchor w", r, from, accent));
	tk->cmd(top, "pack " + r + ".title -side top -anchor w -padx 12 -pady {12 6}");
	fields = array[] of {
		ref Field("", "Recipient:", 0, ""),
		ref Field("", "Amount:",    0, ""),
	};
	for(i := 0; i < len fields; i++){
		f := fields[i];
		row := sys->sprint("%s.r%d", r, i);
		tk->cmd(top, "frame " + row);
		tk->cmd(top, sys->sprint("label %s.l -text {%s} -width %d -anchor w", row, f.label, LBLW));
		tk->cmd(top, sys->sprint("entry %s.e -width 220", row));
		tk->cmd(top, sys->sprint("pack %s.l -side left -padx {12 4}", row));
		tk->cmd(top, sys->sprint("pack %s.e -side left -fill x -expand 1 -padx {0 12}", row));
		tk->cmd(top, "pack " + row + " -side top -fill x -pady 2");
		f.path = row + ".e";
	}
	tk->cmd(top, "frame " + r + ".tok");
	tk->cmd(top, sys->sprint("label %s.tok.l -text {Token:} -width %d -anchor w", r, LBLW));
	tk->cmd(top, "choicebutton " + r + ".tok.cb -values {{ETH (wei)} {USDC (base units)}}");
	tk->cmd(top, "pack " + r + ".tok.l -side left -padx {12 4}");
	tk->cmd(top, "pack " + r + ".tok.cb -side left");
	tk->cmd(top, "pack " + r + ".tok -side top -fill x -pady 2");

	tk->cmd(top, "frame " + r + ".btns");
	tk->cmd(top, "button " + r + ".btns.ok -text {Send} -command {send act send}");
	tk->cmd(top, "button " + r + ".btns.cancel -text {Cancel} -command {send act cancel}");
	tk->cmd(top, "pack " + r + ".btns.ok -side left -padx {12 4} -pady 8");
	tk->cmd(top, "pack " + r + ".btns.cancel -side left -pady 8");
	tk->cmd(top, "pack " + r + ".btns -side top -fill x");
	setfocus(0);
}

setfocus(i: int)
{
	if(i < 0 || i >= len fields)
		return;
	focusi = i;
	tk->cmd(top, "focus " + fields[i].path);
}

fieldval(i: int): string
{
	if(i < 0 || i >= len fields)
		return "";
	return tk->cmd(top, fields[i].path + " get");
}

# ── Actions ───────────────────────────────────────────────────

handleaction(a: string)
{
	(n, toks) := sys->tokenize(a, " ");
	if(n == 0)
		return;
	cmd := hd toks;
	case cmd {
	"mainmenu" =>
		tk->cmd(top, ".mainmenu post " + menuxy(toks, n));
	"detailmenu" =>
		if(mode == ModeView && selacct >= 0)
			tk->cmd(top, ".detailmenu post " + menuxy(toks, n));
		else
			tk->cmd(top, ".mainmenu post " + menuxy(toks, n));
	"selectacct" =>
		sel := tk->cmd(top, ".main.list.lb curselection");
		if(sel != nil && sel != ""){
			selacct = int sel;
			setmode(ModeView);
		}
	"new" =>     setmode(ModeNewETH);
	"import" =>  setmode(ModeImport);
	"pay" =>     if(selacct >= 0) setmode(ModePay);
	"pending" => setmode(ModePending);
	"approve" =>
		if(tl toks != nil)
			doapprove(hd tl toks);
	"deny" =>
		if(tl toks != nil)
			dodeny(hd tl toks);
	"refresh" =>
		refreshaccounts();
		setmode(ModeView);
	"cancel" =>  setmode(ModeView);
	"create" =>  donew();
	"doimport" => doimport();
	"send" =>    dosend();
	"netchange" => netchange();
	"refreshbal" =>
		cachedbalance = "loading...";
		if(selacct >= 0){
			showbalance();
			spawn fetchbalance(accts[selacct].name);
		}
		setstatus("Balance refreshed");
	"copyaddr" =>
		if(selacct >= 0){ copytoclip(accts[selacct].address); setstatus("Address copied"); }
	"copyname" =>
		if(selacct >= 0){ copytoclip(accts[selacct].name); setstatus("Account name copied"); }
	"copytx" =>
		txh := selectedtxhash();
		if(txh != ""){ copytoclip(txh); setstatus("Tx hash copied"); }
		else setstatus("No transaction selected");
	}
}

# Enter in a form submits the current mode.
submit()
{
	case mode {
	ModeNewETH => donew();
	ModeImport => doimport();
	ModePay =>    dosend();
	}
}

# ── Account create / import / pay ─────────────────────────────

donew()
{
	name := fieldval(0);
	if(name == ""){ setstatus("Name is required"); return; }
	chain := fieldval(1);
	if(chain == "")
		chain = "ethereum";
	if(writewalletctl("new", "eth " + chain + " " + name) <= 0){
		setstatus(errmsg("create failed"));
		return;
	}
	finishaccount(name, "Account created: " + name);
}

doimport()
{
	name := fieldval(0);
	if(name == ""){ setstatus("Name is required"); return; }
	chain := fieldval(1);
	if(chain == "")
		chain = "ethereum";
	hexkey := fieldval(2);
	if(hexkey == ""){ setstatus("Private key is required"); return; }
	if(writewalletctl("new", "import eth " + chain + " " + name + " " + hexkey) <= 0){
		setstatus(errmsg("import failed"));
		return;
	}
	finishaccount(name, "Account imported: " + name);
}

finishaccount(name, msg: string)
{
	refreshaccounts();
	for(i := 0; i < len accts; i++)
		if(accts[i].name == name)
			selacct = i;
	setmode(ModeView);
	setstatus(msg);
}

dosend()
{
	if(selacct < 0){ setstatus("No account selected"); return; }
	acct := accts[selacct];
	recipient := fieldval(0);
	if(recipient == ""){ setstatus("Recipient address is required"); return; }
	amount := fieldval(1);
	if(amount == ""){ setstatus("Amount is required"); return; }
	tokv := tk->cmd(top, ".main.right.tok.cb getvalue");
	cmd := amount + " " + recipient;
	if(len tokv >= 4 && tokv[0:4] == "USDC")
		cmd = "usdc " + amount + " " + recipient;
	# Single ORDWR fd for write and read: wallet9p binds the result to
	# the writing fid, so this read can only ever observe OUR proposal
	# — never a concurrent agent proposal's pending id.  (A fresh fd
	# would fall back to the account-level result, which an agent
	# could have overwritten between our write and read.)
	fd := sys->open(WALLET + "/" + acct.name + "/pay", Sys->ORDWR);
	if(fd == nil){
		setstatus(errmsg("payment failed"));
		return;
	}
	b := array of byte cmd;
	if(sys->write(fd, b, len b) <= 0){
		setstatus(errmsg("payment failed"));
		return;
	}
	txhash := payresult(fd);
	if(len txhash > 8 && txhash[0:8] == "pending:"){
		# This payment was initiated by the user right here, so the
		# trusted GUI approves its own proposal — but only after
		# confirming the pending record is exactly what was just
		# submitted.  Agent proposals still wait in the queue.
		id := txhash[8:];
		if(!pendingmatches(id, acct.name, amount, recipient)){
			setstatus("Queued payment doesn't match this form — review Pending Payments");
			setmode(ModePending);
			return;
		}
		if(writewalletctl("ctl", "approve " + id) <= 0){
			setstatus(errmsg("payment queued but approval failed"));
			setmode(ModePending);
			return;
		}
		txhash = payresult(fd);
	}
	if(len txhash > 6 && txhash[0:6] == "error:"){
		setstatus("Payment failed: " + txhash[6:]);
		return;
	}
	if(txhash != ""){
		shown := txhash;
		if(len shown > 20)
			shown = shown[0:20];
		setstatus("Sent! tx:" + shown + "...");
	} else
		setstatus("Payment submitted");
	cachedbalance = "";
	setmode(ModeView);
}

# Read the pay result on the given (writing) fid
payresult(fd: ref Sys->FD): string
{
	rbuf := array[1024] of byte;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	n := sys->read(fd, rbuf, len rbuf);
	if(n <= 0)
		return "";
	return strip(string rbuf[0:n]);
}

# Confirm a pending record is a pay proposal with exactly the account,
# amount, and recipient the user just entered — the guard that keeps
# auto-approve from ever blessing someone else's queued payment.
pendingmatches(id, acct, amount, recipient: string): int
{
	raw := readwalletfile("", "pending");
	(nil, lines) := sys->tokenize(raw, "\n");
	for(; lines != nil; lines = tl lines){
		# "<id> <kind> <acct> <token> <amount> <recipient> <network> <agent>"
		(ntoks, toks) := sys->tokenize(strip(hd lines), " \t");
		if(ntoks < 7 || hd toks != id)
			continue;
		kind := hd tl toks;
		pacct := hd tl tl toks;
		pamount := hd tl tl tl tl toks;
		precip := hd tl tl tl tl tl toks;
		return kind == "pay" && pacct == acct &&
			pamount == amount && precip == recipient;
	}
	return 0;
}

netchange()
{
	v := tk->cmd(top, ".main.right.net.cb getvalue");
	if(v == "")
		return;
	writewalletctl("ctl", "network " + v);
	cachedbalance = "loading...";
	if(selacct >= 0){
		showbalance();
		spawn fetchbalance(accts[selacct].name);
	}
	setstatus("Network: " + v);
}

# ── wallet9p I/O ──────────────────────────────────────────────

readwalletfile(acct, file: string): string
{
	path := WALLET + "/";
	if(acct != "")
		path += acct + "/";
	path += file;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	all := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}
	return all;
}

writewalletctl(file, cmd: string): int
{
	fd := sys->open(WALLET + "/" + file, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte cmd;
	return sys->write(fd, b, len b);
}

refreshaccounts()
{
	raw := readwalletfile("", "accounts");
	(nil, lines) := sys->tokenize(raw, "\n");
	al: list of ref AcctInfo;
	for(; lines != nil; lines = tl lines){
		name := strip(hd lines);
		if(name == "")
			continue;
		chain := strip(readwalletfile(name, "chain"));
		addr := strip(readwalletfile(name, "address"));
		al = ref AcctInfo(name, chain, addr) :: al;
	}
	n := len al;
	accts = array[n] of ref AcctInfo;
	for(i := n - 1; i >= 0; i--){
		accts[i] = hd al;
		al = tl al;
	}
	tk->cmd(top, ".main.list.lb delete 0 end");
	for(j := 0; j < len accts; j++){
		s := accts[j].name;
		if(accts[j].chain != "")
			s += "  " + accts[j].chain;
		tk->cmd(top, sys->sprint(".main.list.lb insert end {%s}", s));
	}
	if(selacct >= len accts)
		selacct = -1;
	setstatus(sys->sprint("%d account%s", len accts, plural(len accts)));
}

fetchbalance(acctname: string)
{
	bal := strip(readwalletfile(acctname, "balance"));
	if(bal != "")
		cachedbalance = bal;
	alt { balancech <-= 1 => ; * => ; }
}

showbalance()
{
	if(tk->cmd(top, ".main.right.bal1 cget -text")[0] == '!')
		return;
	(usdc, eth) := splitbalance(cachedbalance);
	tk->cmd(top, sys->sprint(".main.right.bal1 configure -text {%s}", usdc));
	tk->cmd(top, sys->sprint(".main.right.bal2 configure -text {%s}", eth));
}

splitbalance(bal: string): (string, string)
{
	for(i := 0; i < len bal; i++)
		if(bal[i] == ',')
			return (strip(bal[0:i]), strip(bal[i+1:]));
	return (bal, "");
}

loadhistory(acctname: string)
{
	raw := readwalletfile(acctname, "history");
	(nil, lines) := sys->tokenize(raw, "\n");
	hl: list of string;
	for(; lines != nil; lines = tl lines){
		ln := strip(hd lines);
		if(ln != "")
			hl = ln :: hl;	# reversed → newest first
	}
	historyraw = hl;
	r := ".main.right.hist.lb";
	tk->cmd(top, r + " delete 0 end");
	if(hl == nil){
		tk->cmd(top, r + " insert end {(no transactions)}");
		return;
	}
	for(; hl != nil; hl = tl hl)
		tk->cmd(top, sys->sprint("%s insert end {%s}", r, fmthistory(hd hl)));
}

fmthistory(line: string): string
{
	(kind, token, amount, recip, txhash) := parsehistory(line);
	if(kind == "")
		return line;
	if(len recip > 12)
		recip = recip[0:6] + ".." + recip[len recip - 4:];
	out := amount;
	if(token != "")
		out += " " + token;
	out += " -> " + recip;
	if(len txhash > 10)
		out += "  tx:" + txhash[0:10] + "..";
	return out;
}

#
# wallet9p history lines are "<epoch> <kind> ..." :
#   <ts> pay  <token> <amount> <recipient> <txhash>
#   <ts> x402 <amount> <asset> <payto>
# The leading timestamp and the token field were added when history
# became an audit trail; parse defensively so a line written by an
# older server (no timestamp, no token) still renders.
#
parsehistory(line: string): (string, string, string, string, string)
{
	(nil, toks) := sys->tokenize(line, " \t");
	if(toks == nil)
		return ("", "", "", "", "");

	# skip a leading epoch timestamp if present
	if(alldigits(hd toks)){
		toks = tl toks;
		if(toks == nil)
			return ("", "", "", "", "");
	}

	kind := hd toks;
	toks = tl toks;

	if(kind == "x402"){
		amount := next(toks); toks = rest(toks);
		asset := next(toks); toks = rest(toks);
		payto := next(toks);
		return ("x402", shortasset(asset), amount, payto, "");
	}
	if(kind != "pay")
		return ("", "", "", "", "");

	# "pay <token> <amount> <recipient> <txhash>"; a line from an older
	# server omits the token, in which case the next field is numeric.
	token := next(toks);
	if(alldigits(token)){
		amount := token; toks = rest(toks);
		recip := next(toks); toks = rest(toks);
		return ("pay", "", amount, recip, next(toks));
	}
	toks = rest(toks);
	amount := next(toks); toks = rest(toks);
	recip := next(toks); toks = rest(toks);
	return ("pay", token, amount, recip, next(toks));
}

next(l: list of string): string
{
	if(l == nil)
		return "";
	return hd l;
}

rest(l: list of string): list of string
{
	if(l == nil)
		return nil;
	return tl l;
}

alldigits(s: string): int
{
	if(s == nil || s == "")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

shortasset(a: string): string
{
	if(len a > 12)
		return a[0:6] + ".." + a[len a - 4:];
	return a;
}

selectedtxhash(): string
{
	sel := tk->cmd(top, ".main.right.hist.lb curselection");
	if(sel == nil || sel == "")
		return "";
	idx := int sel;
	i := 0;
	for(l := historyraw; l != nil; l = tl l){
		if(i == idx){
			(nil, nil, nil, nil, txhash) := parsehistory(hd l);
			return txhash;
		}
		i++;
	}
	return "";
}

copytoclip(s: string)
{
	fd := sys->open("/dev/snarf", Sys->OWRITE);
	if(fd != nil){
		b := array of byte s;
		sys->write(fd, b, len b);
	}
}

ensurewallet9p()
{
	(ok, nil) := sys->stat(WALLET + "/accounts");
	if(ok >= 0)
		return;
	mod := load Command "/dis/veltro/wallet9p.dis";
	if(mod == nil)
		return;
	spawn mod->init(nil, "wallet9p" :: nil);
	for(i := 0; i < 50; i++){
		(ok2, nil) := sys->stat(WALLET + "/accounts");
		if(ok2 >= 0)
			break;
		sys->sleep(100);
	}
	sys->sleep(200);
}

# ── Keyboard ──────────────────────────────────────────────────

handlekey(k: int)
{
	if(k == 'q' - 16r60)
		exit;
	if(k == 27){
		if(mode != ModeView)
			setmode(ModeView);
		return;
	}
	if(k == '\t'){
		if(len fields > 0)
			setfocus((focusi + 1) % len fields);
		return;
	}
	if((k == '\n' || k == '\r') && mode != ModeView){
		submit();
		return;
	}
	tk->keyboard(top, k);
}

# ── Status / theme / helpers ──────────────────────────────────

setstatus(s: string)
{
	tk->cmd(top, sys->sprint(".status configure -text {%s}", s));
}

errmsg(deflt: string): string
{
	m := sys->sprint("%r");
	if(m == "" || m == "unknown")
		return deflt;
	return m;
}

loadtheme()
{
	th: ref Theme;
	if(lucitheme != nil)
		th = lucitheme->gettheme();
	if(th == nil)
		th = ref Theme;
	accent = col(th.accent >> 8);
	dim = col(th.dim >> 8);
	bgc = col(th.bg >> 8);
	statusbg = col(th.editstatus >> 8);
	statusfg = col(th.editstattext >> 8);
}

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

menuxy(toks: list of string, n: int): string
{
	if(n >= 3){
		x := hd tl toks;
		y := hd tl tl toks;
		if(x != "" && x[0] >= '0' && x[0] <= '9')
			return x + " " + y;
	}
	return "40 40";
}

themelistener()
{
	fd := sys->open("/mnt/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		sys->seek(fd, big 0, Sys->SEEKSTART);
		if(len ev >= 6 && ev[0:6] == "theme ")
			themech <-= 1;
	}
}

balancetimer()
{
	for(;;){
		sys->sleep(30000);
		alt { balancech <-= 1 => ; * => ; }
	}
}

pendingwatcher()
{
	for(;;){
		sys->sleep(2000);
		raw := readwalletfile("", "pending");
		(nil, lines) := sys->tokenize(raw, "\n");
		n := 0;
		for(; lines != nil; lines = tl lines){
			ln := strip(hd lines);
			if(ln != "" && ln != "(none)")
				n++;
		}
		if(n != pendingcount)
			alt { pendingch <-= n => ; * => ; }
	}
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

plural(n: int): string
{
	if(n == 1)
		return "";
	return "s";
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "wallet: tk error %s on %s\n", e, cmds[i]);
	}
}
