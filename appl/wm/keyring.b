implement Keyring;

#
# keyring - Factotum key manager for Lucifer (Tk version)
#
# A graphical keychain front-end to factotum's /mnt/factotum/ctl
# interface, styled by the brutalist Tk defaults. The app never stores
# keys itself — factotum is the sole key store.
#
# Quick-add templates (via the B3 context menu):
#   Email Account    — creates service=imap + service=smtp keys
#   API Key          — service=<name> key (anthropic, openai, etc.)
#   Login            — generic service/domain/user/password
#   Wallet Key       — service=wallet-<chain>-<name>
#   Advanced         — raw attribute editor
#
# Mouse:
#   Button 1     select key / interact with fields
#   Button 3     context menu (add / delete / refresh)
# Keyboard:
#   Tab          cycle focus between fields
#   Enter        save key (in form) / Escape cancel / Ctrl-Q quit
#   Delete       delete selected key (in list mode)
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

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

Keyring: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# ── Key representation ────────────────────────────────────────

KeyEntry: adt {
	proto:   string;
	service: string;
	dom:     string;
	user:    string;
	raw:     string;	# full attribute line from ctl
};

# ── Form modes ────────────────────────────────────────────────

ModeList, ModeEmail, ModeAPI, ModeLogin, ModeWallet, ModeAdvanced: con iota;

# A form field: (entry path, label, secret, prefill)
Field: adt {
	path:    string;
	label:   string;
	secret:  int;
	prefill: string;
};

# ── State ─────────────────────────────────────────────────────

top:    ref Toplevel;
wmctl:  chan of string;
actch:  chan of string;
themech: chan of int;
stderr: ref Sys->FD;

keys:    array of ref KeyEntry;
mode:    int;
fields:  array of ref Field;	# fields of the current form
focusi:  int;			# index of the focused field
accent:  string;		# theme accent as #rrggbbff
dim:     string;		# theme dim colour

CTL: con "/mnt/factotum/ctl";

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	str = load String String->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	stderr = sys->fildes(2);
	if(tkclient == nil){
		sys->fprint(stderr, "keyring: cannot load tkclient: %r\n");
		raise "fail:load tkclient";
	}
	lucitheme = load Lucitheme Lucitheme->PATH;

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(stderr, "keyring: no window context\n");
		raise "fail:no context";
	}

	loadtheme();

	(top, wmctl) = tkclient->toplevel(ctxt, "-width 420 -height 500",
		"Keyring", Tkclient->Appl);

	actch = chan[8] of string;
	tk->namechan(top, actch, "act");

	buildbase();
	setmode(ModeList);
	refreshkeys();

	if(secstorelocked())
		flashstatus("Keys are in-memory only (login was skipped)");
	else
		flashstatus("Keys persist to secstore");

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	themech = chan[1] of int;
	spawn themelistener();

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl =>
		tkclient->wmctl(top, c);

	k := <-top.ctxt.kbd =>
		handlekey(k);

	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);

	a := <-actch =>
		handleaction(a);

	<-themech =>
		loadtheme();
		# re-create the menus / accents that carry explicit colours
		setmode(mode);
		flashstatus("theme updated");
	}
}

# ── Base layout: listbox (top), form area, status bar ─────────

buildbase()
{
	cmds := array[] of {
		". configure -background #080808",

		# upper: key list with scrollbar
		"frame .top",
		"scrollbar .top.sb -command {.top.lb yview}",
		"listbox .top.lb -yscrollcommand {.top.sb set} -selectmode single",
		"pack .top.sb -side right -fill y",
		"pack .top.lb -side left -fill both -expand 1",

		# divider
		"frame .div -height 1 -background " + accent,

		# form container (rebuilt per mode)
		"frame .form",

		# status strip
		"label .status -anchor w -background #0a0a0a -foreground #999999",

		"pack .top -side top -fill both -expand 1",
		"pack .div -side top -fill x",
		"pack .form -side top -fill x",
		"pack .status -side bottom -fill x",
		"pack propagate . 0",

		# select a key with B1, raise the menu with B3 (at the pointer)
		"bind .top.lb <Button-1> {%C}",
		"bind .top.lb <Button-3> {send act menu %X %Y}",
		"bind . <Button-3> {send act menu %X %Y}",
	};
	tkcmds(cmds);
	buildmenu();
}

# The B3 context menu (mirrors the old mainmenu).
buildmenu()
{
	tk->cmd(top, "menu .ctx");
	items := array[] of {
		("Add Email Account", "email"),
		("Add API Key",       "api"),
		("Add Login",         "login"),
		("Add Wallet Key",    "wallet"),
		("Add Advanced",      "advanced"),
		("",                  ""),
		("Delete Selected",   "delete"),
		("",                  ""),
		("Refresh",           "refresh"),
	};
	for(i := 0; i < len items; i++){
		(label, tok) := items[i];
		if(label == "")
			tk->cmd(top, ".ctx add separator");
		else
			tk->cmd(top, sys->sprint(".ctx add command -label {%s} -command {send act %s}", label, tok));
	}
}

# Rebuild the form area for a mode.
setmode(m: int)
{
	mode = m;
	focusi = 0;
	# clear the form frame
	tk->cmd(top, "destroy .form");
	tk->cmd(top, "frame .form");
	tk->cmd(top, "pack .form -side top -fill x -after .div");

	fields = modefields(m);

	if(len fields == 0){
		# list mode: offer Delete when a key is selected
		tk->cmd(top, "button .form.del -text {Delete} -command {send act delete}");
		tk->cmd(top, "pack .form.del -side left -padx 12 -pady 8");
		updatehint();
		return;
	}

	# one labelled row per field
	for(i := 0; i < len fields; i++){
		f := fields[i];
		row := sys->sprint(".form.r%d", i);
		tk->cmd(top, "frame " + row);
		# Inferno Tk widget -width is in PIXELS, not characters: reserve
		# a fixed label column wide enough for the longest label so the
		# rows line up.
		tk->cmd(top, sys->sprint("label %s.l -text {%s} -width 84 -anchor w", row, f.label));
		show := "";
		if(f.secret)
			show = " -show *";
		tk->cmd(top, sys->sprint("entry %s.e -width 28%s", row, show));
		if(f.prefill != "")
			tk->cmd(top, sys->sprint("%s.e insert 0 {%s}", row, f.prefill));
		tk->cmd(top, sys->sprint("pack %s.l -side left -padx {12 4}", row));
		tk->cmd(top, sys->sprint("pack %s.e -side left -fill x -expand 1 -padx {0 12}", row));
		tk->cmd(top, "pack " + row + " -side top -fill x -pady 2");
		f.path = row + ".e";
	}
	# Save / Cancel buttons
	tk->cmd(top, "frame .form.btns");
	tk->cmd(top, "button .form.btns.save -text {Save} -command {send act save}");
	tk->cmd(top, "button .form.btns.cancel -text {Cancel} -command {send act cancel}");
	tk->cmd(top, "pack .form.btns.save -side left -padx {12 4} -pady 8");
	tk->cmd(top, "pack .form.btns.cancel -side left -pady 8");
	tk->cmd(top, "pack .form.btns -side top -fill x");

	setfocus(0);
	updatehint();
	tk->cmd(top, "update");
}

modefields(m: int): array of ref Field
{
	case m {
	ModeEmail =>
		return array[] of {
			ref Field("", "Server:",   0, ""),
			ref Field("", "User:",     0, ""),
			ref Field("", "Password:", 1, ""),
		};
	ModeAPI =>
		return array[] of {
			ref Field("", "Service:", 0, "anthropic"),
			ref Field("", "API Key:", 1, ""),
		};
	ModeLogin =>
		return array[] of {
			ref Field("", "Service:",  0, ""),
			ref Field("", "Domain:",   0, ""),
			ref Field("", "User:",     0, ""),
			ref Field("", "Password:", 1, ""),
		};
	ModeWallet =>
		return array[] of {
			ref Field("", "Name:",  0, ""),
			ref Field("", "Chain:", 0, "eth"),
			ref Field("", "Key:",   1, ""),
		};
	ModeAdvanced =>
		return array[] of {
			ref Field("", "Attrs:",  0, ""),
			ref Field("", "Secret:", 1, ""),
		};
	}
	return array[0] of ref Field;
}

setfocus(i: int)
{
	if(i < 0 || i >= len fields)
		return;
	focusi = i;
	tk->cmd(top, "focus " + fields[i].path);
	tk->cmd(top, "update");
}

fieldval(i: int): string
{
	if(i < 0 || i >= len fields)
		return "";
	return tk->cmd(top, fields[i].path + " get");
}

updatehint()
{
	if(mode == ModeList)
		setstatusright("B3: menu");
	else
		setstatusright("Tab: next field   Enter: save");
}

# ── Actions (button / menu commands) ──────────────────────────

handleaction(a: string)
{
	# the B3 bind sends "menu <X> <Y>" (screen coords)
	(n, toks) := sys->tokenize(a, " ");
	if(n >= 1 && hd toks == "menu"){
		xy := "20 40";
		if(n >= 3 && (hd tl toks)[0] >= '0' && (hd tl toks)[0] <= '9')
			xy = hd tl toks + " " + hd tl tl toks;
		tk->cmd(top, ".ctx post " + xy);
		return;
	}
	case a {
	"email" =>    setmode(ModeEmail);
	"api" =>      setmode(ModeAPI);
	"login" =>    setmode(ModeLogin);
	"wallet" =>   setmode(ModeWallet);
	"advanced" => setmode(ModeAdvanced);
	"refresh" =>
		refreshkeys();
		flashstatus("refreshed");
	"delete" =>   deleteselected();
	"save" =>     savekey();
	"cancel" =>   setmode(ModeList);
	}
}

# ── Save: build the factotum command(s) per mode ──────────────

savekey()
{
	cmds: list of string;
	case mode {
	ModeEmail =>
		dom := fieldval(0); user := fieldval(1); pass := fieldval(2);
		if(dom == "" || user == "" || pass == ""){ flashstatus("error: fill all fields"); return; }
		cmds =
			sys->sprint("key proto=pass service=imap dom=%s user=%s !password=%s", dom, user, pass) ::
			sys->sprint("key proto=pass service=smtp dom=%s user=%s !password=%s", dom, user, pass) :: nil;
	ModeAPI =>
		svc := fieldval(0); pass := fieldval(1);
		if(svc == "" || pass == ""){ flashstatus("error: fill all fields"); return; }
		cmds = sys->sprint("key proto=pass service=%s user=apikey !password=%s", svc, pass) :: nil;
	ModeLogin =>
		svc := fieldval(0); dom := fieldval(1); user := fieldval(2); pass := fieldval(3);
		if(svc == "" || user == "" || pass == ""){ flashstatus("error: fill service, user, and password"); return; }
		a := "key proto=pass service=" + svc;
		if(dom != "")
			a += " dom=" + dom;
		a += " user=" + user + " !password=" + pass;
		cmds = a :: nil;
	ModeWallet =>
		wname := fieldval(0); chain := fieldval(1); wkey := fieldval(2);
		if(wname == "" || chain == "" || wkey == ""){ flashstatus("error: fill all fields"); return; }
		svc := "wallet-" + chain + "-" + wname;
		cmds = sys->sprint("key proto=pass service=%s user=key !password=%s", svc, wkey) :: nil;
	ModeAdvanced =>
		raw := fieldval(0); pass := fieldval(1);
		if(raw == ""){ flashstatus("error: enter attributes"); return; }
		if(!strcontains(raw, "proto="))
			raw = "proto=pass " + raw;
		a := "key " + raw;
		if(pass != "")
			a += " !password=" + pass;
		cmds = a :: nil;
	* =>
		return;
	}

	for(l := cmds; l != nil; l = tl l)
		if(writectl(hd l) < 0)
			return;
	writectl("sync");
	if(mode == ModeEmail)
		flashstatus("added email keys");
	else
		flashstatus("key added");
	setmode(ModeList);
	refreshkeys();
}

deleteselected()
{
	sel := tk->cmd(top, ".top.lb curselection");
	if(sel == nil || sel == ""){ flashstatus("no key selected"); return; }
	i := int sel;
	if(i < 0 || i >= len keys){ flashstatus("no key selected"); return; }
	ke := keys[i];
	cmd := "delkey";
	if(ke.proto != "")   cmd += " proto=" + ke.proto;
	if(ke.service != "") cmd += " service=" + ke.service;
	if(ke.dom != "")     cmd += " dom=" + ke.dom;
	if(ke.user != "")    cmd += " user=" + ke.user;
	if(writectl(cmd) < 0)
		return;
	writectl("sync");
	flashstatus("key deleted");
	refreshkeys();
}

# ── factotum I/O ──────────────────────────────────────────────

writectl(cmd: string): int
{
	fd := sys->open(CTL, Sys->OWRITE);
	if(fd == nil){
		m := sys->sprint("error: %r");
		flashstatus(m);
		sys->fprint(stderr, "keyring: %s\n", m);
		return -1;
	}
	b := array of byte cmd;
	if(sys->write(fd, b, len b) < 0){
		m := sys->sprint("error: %r");
		flashstatus(m);
		sys->fprint(stderr, "keyring: %s\n", m);
		return -1;
	}
	return 0;
}

refreshkeys()
{
	fd := sys->open(CTL, Sys->OREAD);
	if(fd == nil){
		flashstatus("factotum not available");
		keys = array[0] of ref KeyEntry;
		repopulate();
		return;
	}
	all := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		all += string buf[0:n];
	}
	kl: list of ref KeyEntry;
	(nil, lines) := sys->tokenize(all, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(len line > 4 && line[0:4] == "key ")
			line = line[4:];
		if(line == "")
			continue;
		kl = parsekey(line) :: kl;
	}
	# preserve file order
	n := len kl;
	keys = array[n] of ref KeyEntry;
	for(i := n - 1; i >= 0; i--){
		keys[i] = hd kl;
		kl = tl kl;
	}
	repopulate();
	setstatusleft(sys->sprint("%d key%s", n, plural(n)));
}

parsekey(line: string): ref KeyEntry
{
	ke := ref KeyEntry("", "", "", "", line);
	(nil, toks) := sys->tokenize(line, " \t");
	for(; toks != nil; toks = tl toks){
		t := hd toks;
		(name, val) := splitkv(t);
		case name {
		"proto" =>   ke.proto = val;
		"service" => ke.service = val;
		"dom" =>     ke.dom = val;
		"user" =>    ke.user = val;
		}
	}
	return ke;
}

splitkv(t: string): (string, string)
{
	for(i := 0; i < len t; i++)
		if(t[i] == '=')
			return (t[0:i], t[i+1:]);
	return (t, "");
}

repopulate()
{
	tk->cmd(top, ".top.lb delete 0 end");
	if(len keys == 0){
		tk->cmd(top, ".top.lb insert end {(no keys — right-click to add)}");
		return;
	}
	for(i := 0; i < len keys; i++)
		tk->cmd(top, sys->sprint(".top.lb insert end {%s}", keylabel(keys[i])));
}

keylabel(ke: ref KeyEntry): string
{
	s := "?";
	if(ke.proto != "")
		s = ke.proto;
	if(ke.service != "")
		s += "  " + ke.service;
	if(ke.dom != "")
		s += "  " + ke.dom;
	if(ke.user != "")
		s += "  user=" + ke.user;
	return s;
}

secstorelocked(): int
{
	(ok, nil) := sys->stat("/tmp/.secstore-unlocked");
	return ok < 0;
}

# ── Keyboard ──────────────────────────────────────────────────

handlekey(k: int)
{
	Kdel: con 16rFF9F;
	# Ctrl-Q quits
	if(k == 'q' - 16r60){
		exit;
	}
	# Escape cancels the form / clears selection
	if(k == 27){
		if(mode != ModeList)
			setmode(ModeList);
		else
			tk->cmd(top, ".top.lb selection clear 0 end");
		return;
	}
	# Tab cycles focus through the form fields
	if(k == '\t'){
		if(len fields > 0)
			setfocus((focusi + 1) % len fields);
		return;
	}
	# Enter saves when editing a form
	if((k == '\n' || k == '\r') && mode != ModeList){
		savekey();
		return;
	}
	# Delete removes the selected key in list mode
	if(k == Kdel && mode == ModeList){
		deleteselected();
		return;
	}
	# everything else goes to the focused Tk widget
	tk->keyboard(top, k);
}

# ── Status bar ────────────────────────────────────────────────

statusleft  := "";
statusright := "";

setstatusleft(s: string)  { statusleft = s; drawstatus(); }
setstatusright(s: string) { statusright = s; drawstatus(); }
flashstatus(s: string)    { statusleft = s; drawstatus(); }

drawstatus()
{
	t := statusleft;
	if(statusright != "")
		t += "    —    " + statusright;
	tk->cmd(top, sys->sprint(".status configure -text {%s}", t));
}

# ── Theme ─────────────────────────────────────────────────────

loadtheme()
{
	th: ref Theme;
	if(lucitheme != nil)
		th = lucitheme->gettheme();
	if(th == nil)
		th = ref Theme;
	accent = col(th.accent);
	dim = col(th.dim);
}

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
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

# ── Helpers ───────────────────────────────────────────────────

plural(n: int): string
{
	if(n == 1)
		return "";
	return "s";
}

strcontains(s, sub: string): int
{
	ls := len s; lsub := len sub;
	if(lsub > ls)
		return 0;
	for(i := 0; i <= ls - lsub; i++)
		if(s[i:i+lsub] == sub)
			return 1;
	return 0;
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "keyring: tk error %s on %s\n", e, cmds[i]);
	}
}
