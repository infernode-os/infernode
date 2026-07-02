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

ModeView, ModeNewETH, ModeImport, ModePay: con iota;

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
		setmode(mode);
	}
}

# ── Base two-pane layout ──────────────────────────────────────

buildbase()
{
	cmds := array[] of {
		". configure -background #080808",
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
		"label .status -anchor w -background #0a0a0a -foreground #999999",
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
	}
	tk->cmd(top, "update");
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
		tk->cmd(top, sys->sprint("label %s.%s -text '%s -anchor w%s", r, id, txt, fgopt));
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
	tk->cmd(top, sys->sprint("label %s.title -text '%s -foreground %s -anchor w", r, title, accent));
	tk->cmd(top, "pack " + r + ".title -side top -anchor w -padx 12 -pady {12 6}");
	fields = flds;
	for(i := 0; i < len flds; i++){
		f := flds[i];
		row := sys->sprint("%s.r%d", r, i);
		tk->cmd(top, "frame " + row);
		tk->cmd(top, sys->sprint("label %s.l -text '%s -width %d -anchor w", row, f.label, LBLW));
		show := "";
		if(f.secret)
			show = " -show *";
		tk->cmd(top, sys->sprint("entry %s.e -width 220%s", row, show));
		if(f.prefill != "")
			tk->cmd(top, sys->sprint("%s.e insert 0 '%s", row, f.prefill));
		tk->cmd(top, sys->sprint("pack %s.l -side left -padx {12 4}", row));
		tk->cmd(top, sys->sprint("pack %s.e -side left -fill x -expand 1 -padx {0 12}", row));
		tk->cmd(top, "pack " + row + " -side top -fill x -pady 2");
		f.path = row + ".e";
	}
	tk->cmd(top, "frame " + r + ".btns");
	tk->cmd(top, sys->sprint("button %s.btns.ok -text '%s -command {send act %s}", r, oklabel, oktok));
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
	tk->cmd(top, sys->sprint("label %s.title -text 'Send from: %s -foreground %s -anchor w", r, from, accent));
	tk->cmd(top, "pack " + r + ".title -side top -anchor w -padx 12 -pady {12 6}");
	fields = array[] of {
		ref Field("", "Recipient:", 0, ""),
		ref Field("", "Amount:",    0, ""),
	};
	for(i := 0; i < len fields; i++){
		f := fields[i];
		row := sys->sprint("%s.r%d", r, i);
		tk->cmd(top, "frame " + row);
		tk->cmd(top, sys->sprint("label %s.l -text '%s -width %d -anchor w", row, f.label, LBLW));
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
	if(writewalletctl(acct.name + "/pay", cmd) <= 0){
		setstatus(errmsg("payment failed"));
		return;
	}
	txhash := strip(readwalletfile(acct.name, "pay"));
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
		tk->cmd(top, sys->sprint(".main.list.lb insert end '%s", s));
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
	tk->cmd(top, sys->sprint(".main.right.bal1 configure -text '%s", usdc));
	tk->cmd(top, sys->sprint(".main.right.bal2 configure -text '%s", eth));
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
		tk->cmd(top, sys->sprint("%s insert end '%s", r, fmthistory(hd hl)));
}

fmthistory(line: string): string
{
	(nil, toks) := sys->tokenize(line, " \t");
	if(toks != nil && hd toks == "pay")
		toks = tl toks;
	amount := ""; recip := ""; txhash := "";
	if(toks != nil){ amount = hd toks; toks = tl toks; }
	if(toks != nil){ recip = hd toks; toks = tl toks; }
	if(toks != nil){ txhash = hd toks; }
	if(len recip > 12)
		recip = recip[0:6] + ".." + recip[len recip - 4:];
	out := amount + " -> " + recip;
	if(len txhash > 10)
		out += "  tx:" + txhash[0:10] + "..";
	return out;
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
			(nil, toks) := sys->tokenize(hd l, " \t");
			if(toks != nil && hd toks == "pay")
				toks = tl toks;
			if(toks != nil) toks = tl toks;	# amount
			if(toks != nil) toks = tl toks;	# recipient
			if(toks != nil)
				return hd toks;
			return "";
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
	tk->cmd(top, sys->sprint(".status configure -text '%s", s));
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
