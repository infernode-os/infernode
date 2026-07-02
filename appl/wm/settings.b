implement Settings;

#
# settings - System preferences for Lucifer
#
# A graphical settings app that provides a non-technical interface
# for configuring: theme, tool budget, active tools, namespace
# paths, agent prompts, and startup profile.
#
# Configuration reads/writes:
#   Theme:        /lib/lucifer/theme/current (persistent, live)
#   Tool budget:  /tool/budget + /tool/ctl budget-add/budget-remove (live, ephemeral)
#   Active tools: /tool/tools + /tool/ctl add/remove (live, ephemeral)
#   Paths:        /tool/paths + /tool/ctl bindpath/unbindpath (live, ephemeral)
#   Prompts:      /lib/veltro/meta.txt, /lib/veltro/agents/task.txt (persistent)
#   Profile:      /lib/sh/profile (persistent, restart required)
#
# Settings marked "restart required" flash a warning in the status bar.
#
# Mouse:
#   Button 1     select / toggle / interact
#   Button 3     context menu (future)
#
# Keyboard:
#   Tab          cycle focus between fields
#   Enter        confirm / apply
#   Escape       cancel edits
#   Ctrl-Q       quit
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect, Pointer: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "keyringinst.m";
	keyringinst: Keyringinst;

include "bioauth.m";
	bioauth: Bioauth;

include "twofaslot.m";
	twofaslot: Twofaslot;

include "twofa.m";
	twofa: Twofa;

include "keyring.m";

include "security.m";
	random: Random;

include "string.m";
	str: String;

include "dialnorm.m";
	dialnorm: Dialnorm;

include "lucitheme.m";

Settings: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# ── Categories ─────────────────────────────────────────────────

CatTheme, CatLLM, CatTools, CatBudget, CatPaths, CatPrompts, CatProfile, CatMessaging, CatSecurity: con iota;
NCATS: con 9;

catnames := array[] of {
	"Theme",
	"LLM Service",
	"Initial Active Tools",
	"Delegatable Tools",
	"Namespace Paths",
	"Agent Prompts",
	"Startup Profile",
	"Messaging",
	"Security",
};

# Short aliases for -c <name>: tab-friendly identifiers a launcher can
# pass to open Settings directly on a given panel. Index parallels
# CatTheme..CatProfile. See INFR-100.
catshortnames := array[] of {
	"theme",
	"llm",
	"tools",
	"delegated",
	"paths",
	"prompts",
	"profile",
	"messaging",
	"security",
};

# ── State ──────────────────────────────────────────────────────

# Tk host
top: ref Toplevel;
wmctl: chan of string;
actch: chan of string;
display_g: ref Display;
category: int;		# current category index
mobile := 0;		# /env/infmobile=1 (kept for parity; Tk sizes itself)
TAPMIN: con 132;

# Theme colours resolved to #rrggbbff strings for Tk
c_bg:	string;
c_fg:	string;
c_dim:	string;
c_accent: string;
c_border: string;

SFONT: con "/fonts/combined/unicode.sans.14.font";

# Panel data (names/labels — the dispatch tables, kept verbatim)
theme_names: array of string;
llm_mode_names := array[] of { "local", "remote" };
llm_mode_labels := array[] of { "Local", "Remote (9P)" };
llm_backend_names := array[] of { "api", "openai" };
llm_backend_labels := array[] of { "Remote API", "Local model" };
llm_stack_names  := array[] of { "ollama", "sglang", "custom" };
llm_stack_labels := array[] of { "Ollama (:11434)", "SGLang (:30000)", "Custom URL" };
llm_is_remote: int;		# reflects the mode radio
llm_have_synthfs: int;		# 1 when /llm/ctl is mountable
llm_models: array of string;	# current model catalogue (for tap-to-fill)

tool_names:   array of string;
budget_names:  array of string;
path_items:   array of string;	# current /tool/paths listing
prompt_files := array[] of {
	("/lib/veltro/meta.txt", "Meta Agent Prompt"),
	("/lib/veltro/agents/task.txt", "Task Agent Prompt"),
};

stderr: ref Sys->FD;
themech: chan of int;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	if(tk == nil || tkclient == nil){
		sys->fprint(sys->fildes(2), "settings: cannot load Tk: %r\n");
		raise "fail:cannot load Tk";
	}
	dialnorm = load Dialnorm Dialnorm->PATH;
	keyringinst = load Keyringinst Keyringinst->PATH;
	if(keyringinst != nil)
		keyringinst->init();

	bioauth = load Bioauth Bioauth->PATH;
	if(bioauth != nil)
		bioauth->init();
	twofaslot = load Twofaslot Twofaslot->PATH;
	if(twofaslot != nil)
		twofaslot->init();
	twofa = load Twofa Twofa->PATH;
	if(twofa != nil) {
		twofa->init();
		twofa->mount();
	}
	random = load Random Random->PATH;
	stderr = sys->fildes(2);

	if(ctxt == nil) {
		sys->fprint(stderr, "settings: no window context\n");
		raise "fail:no context";
	}

	# KLUDGE-MOBILE-ACCORDION-INFR-119 — same env var lucifer.b reads;
	# floors interactive row heights at a 44pt finger tap target.
	(mok, mst) := sys->stat("/env/infmobile");
	if(mok == 0 && mst.length > big 0) {
		mfd := sys->open("/env/infmobile", Sys->OREAD);
		if(mfd != nil) {
			mbuf := array[16] of byte;
			mn := sys->read(mfd, mbuf, len mbuf);
			if(mn > 0 && mbuf[0] == byte '1')
				mobile = 1;
		}
	}

	# Parse -c <name> to choose initial category. Quietly ignore unknown
	# flags / arguments — launchers should not crash settings if a future
	# build of lucibridge passes options this version doesn't understand.
	startcat := CatTheme;
	if(argv != nil)
		argv = tl argv;	# drop progname
	while(argv != nil) {
		a := hd argv;
		argv = tl argv;
		if(a == "-c" && argv != nil) {
			name := hd argv;
			argv = tl argv;
			for(i := 0; i < len catshortnames; i++) {
				if(catshortnames[i] == name) {
					startcat = i;
					break;
				}
			}
		}
	}

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	sys->sleep(100);

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(top, wmctl) = tkclient->toplevel(ctxt, "-width 560 -height 440", "Settings", Tkclient->Appl);
	display_g = top.display;

	loadcolors();

	actch = chan[16] of string;
	tk->namechan(top, actch, "act");

	category = startcat;
	buildui();

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	# Listen for live theme changes from /mnt/ui/event
	themech = chan[1] of int;
	spawn themelistener();

	# Main event loop
	for(;;) {
		alt {
		c := <-wmctl or
		c = <-top.ctxt.ctl =>
			tkclient->wmctl(top, c);
		k := <-top.ctxt.kbd =>
			tk->keyboard(top, k);
		ptr := <-top.ctxt.ptr =>
			tk->pointer(top, *ptr);
		a := <-actch =>
			handleaction(a);
		<-themech =>
			reloadcolors();
		}
	}
}

# ── Tk UI ──────────────────────────────────────────────────────

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "settings: tk error %s on %s\n", e, cmds[i]);
	}
}

# Read a Tk -variable (radio/check state).
tkv(name: string): string
{
	return tk->cmd(top, "variable " + name);
}

# Read an entry's contents.
eget(path: string): string
{
	return tk->cmd(top, path + " get");
}

buildui()
{
	tkcmds(array[] of {
		". configure -background " + c_bg,
		"frame .cats -background " + c_bg,
		"listbox .cats.lb -font " + SFONT + " -selectmode browse" +
			" -background " + c_bg + " -foreground " + c_fg +
			" -selectbackground " + c_accent + " -selectforeground " + c_bg,
		"pack .cats.lb -side top -fill both -expand 1",
		"pack .cats -side left -fill y",
		"label .status -anchor w -background " + c_bg + " -foreground " + c_dim,
		"pack .status -side bottom -fill x",
		"frame .content -background " + c_bg,
		"pack .content -side left -fill both -expand 1",
		"pack propagate . 0",
		"bind .cats.lb <ButtonRelease-1> {send act cat}",
	});
	for(i := 0; i < len catnames; i++)
		tk->cmd(top, sys->sprint(".cats.lb insert end {%s}", catnames[i]));
	tk->cmd(top, sys->sprint(".cats.lb selection set %d", category));
	buildpanel(category);
	tk->cmd(top, "update");
}

# Rebuild the right-hand content pane for the current category.
buildpanel(cat: int)
{
	category = cat;
	tk->cmd(top, "destroy .content");
	tk->cmd(top, "frame .content -background " + c_bg);
	tk->cmd(top, "pack .content -side left -fill both -expand 1 -padx 8 -pady 6");
	case cat {
	CatTheme =>	paneltheme();
	CatLLM =>	panelllm();
	CatTools =>	panelchecks("tool", readtokensor("/tool/_registry", "/tool/tools"), readlines("/tool/tools"));
	CatBudget =>	panelchecks("budget", readtokensor("/tool/_registry", "/tool/budget"), readlines("/tool/budget"));
	CatPaths =>	panelpaths();
	CatPrompts =>	panelprompts();
	CatProfile =>	panelprofile();
	CatMessaging =>	panelmessaging();
	CatSecurity =>	panelsecurity();
	}
	tk->cmd(top, "update");
}

# header label helper
hdr(name, text: string)
{
	tk->cmd(top, sys->sprint("label .content.%s -anchor w -background %s -foreground %s -text %s",
		name, c_bg, c_fg, tk->quote(text)));
	tk->cmd(top, sys->sprint("pack .content.%s -side top -anchor w -pady 2", name));
}

lbl(name, text: string)
{
	tk->cmd(top, sys->sprint("label .content.%s -anchor w -background %s -foreground %s -text %s",
		name, c_bg, c_dim, tk->quote(text)));
	tk->cmd(top, sys->sprint("pack .content.%s -side top -anchor w", name));
}

btn(name, text, verb: string)
{
	tk->cmd(top, sys->sprint("button .content.%s -text %s -command {send act %s}",
		name, tk->quote(text), verb));
	tk->cmd(top, sys->sprint("pack .content.%s -side top -anchor w -pady 3", name));
}

# ── Panels ─────────────────────────────────────────────────────

paneltheme()
{
	theme_names = readthemes();
	current := readcurrenttheme();
	tk->cmd(top, "variable thm " + tk->quote(current));
	for(i := 0; i < len theme_names; i++)
		tk->cmd(top, sys->sprint(
			"radiobutton .content.t%d -text %s -value %s -variable thm" +
			" -background %s -foreground %s -command {send act theme}; " +
			"pack .content.t%d -side top -anchor w",
			i, tk->quote(theme_names[i]), tk->quote(theme_names[i]),
			c_bg, c_fg, i));
}

panelllm()
{
	(curmode, curbackend, cururl, curmodel, curdial, haskey) := readllmconfig();
	if(llm_is_remote)
		curmode = "remote";
	hdr("connh", "Connection");
	tk->cmd(top, "variable llmmode " + curmode);
	for(i := 0; i < len llm_mode_names; i++)
		tk->cmd(top, sys->sprint(
			"radiobutton .content.m%d -text %s -value %s -variable llmmode" +
			" -background %s -foreground %s -command {send act llmmode}; pack .content.m%d -side top -anchor w",
			i, tk->quote(llm_mode_labels[i]), llm_mode_names[i], c_bg, c_fg, i));

	if(llm_is_remote){
		lbl("diall", "Dial address (tcp!host!port):");
		entryrow("dial", curdial);
		hdr("krh", "Keyring authentication");
		lbl("krs", keyring_status_text());
		btn("krinstall", "Install keyfile from clipboard", "keyinstall");
		if(bioauth != nil && bioauth->available() == Bioauth->AVAIL_OK)
			btn("krbio", "Install + protect with biometric", "keybio");
	} else {
		hdr("bh", "Backend");
		bsel := curbackend;
		tk->cmd(top, "variable llmbackend " + tk->quote(bsel));
		for(i := 0; i < len llm_backend_names; i++)
			tk->cmd(top, sys->sprint(
				"radiobutton .content.b%d -text %s -value %s -variable llmbackend" +
				" -background %s -foreground %s -command {send act llmbackend}; pack .content.b%d -side top -anchor w",
				i, tk->quote(llm_backend_labels[i]), llm_backend_names[i], c_bg, c_fg, i));

		llm_have_synthfs = synthfs_present();
		if(curbackend == "openai" && llm_have_synthfs){
			lbl("lstat", readllmstatus_summary());
			hdr("sh", "Local stack");
			ssel := llm_stack_index_from_status();
			tk->cmd(top, "variable llmstack " + llm_stack_names[ssel]);
			for(i := 0; i < len llm_stack_names; i++)
				tk->cmd(top, sys->sprint(
					"radiobutton .content.s%d -text %s -value %s -variable llmstack" +
					" -background %s -foreground %s; pack .content.s%d -side top -anchor w",
					i, tk->quote(llm_stack_labels[i]), llm_stack_names[i], c_bg, c_fg, i));
		}
		lbl("urll", "Endpoint URL:");
		entryrow("url", cururl);
		lbl("modell", "Model:");
		entryrow("model", curmodel);

		llm_models = readllmmodels();
		if(llm_models != nil){
			lbl("modlsl", "Available models (tap to choose):");
			tk->cmd(top, sys->sprint("listbox .content.modls -height 3 -font %s -selectmode browse" +
				" -background %s -foreground %s -selectbackground %s -selectforeground %s",
				SFONT, c_bg, c_fg, c_accent, c_bg));
			for(i := 0; i < len llm_models; i++)
				tk->cmd(top, sys->sprint(".content.modls insert end {%s}", llm_models[i]));
			tk->cmd(top, "pack .content.modls -side top -anchor w -fill x");
			tk->cmd(top, "bind .content.modls <ButtonRelease-1> {send act llmmodel}");
		}
		ks := "API key: not set (add via Keyring app)";
		if(haskey)
			ks = "API key: configured";
		lbl("keyl", ks);
		ps := "Key persistence: inactive (login skipped)";
		if(secstoreunlocked())
			ps = "Key persistence: active";
		lbl("perl", ps);
	}
	btn("llmapply", "Apply", "llmapply");
}

# An entry with the standard styling, packed full-width.
entryrow(name, val: string)
{
	tk->cmd(top, sys->sprint("entry .content.%s -background %s -foreground %s",
		name, c_bg, c_fg));
	tk->cmd(top, sys->sprint(".content.%s insert end %s", name, tk->quote(val)));
	tk->cmd(top, sys->sprint("pack .content.%s -side top -anchor w -fill x -pady 2", name));
}

# Tools / Budget panels: a checkbutton per known item.
panelchecks(kind: string, all, on: array of string)
{
	if(all == nil || len all == 0)
		all = on;
	if(kind == "tool")
		tool_names = all;
	else
		budget_names = all;
	for(i := 0; i < len all; i++){
		v := sys->sprint("%sv%d", kind, i);
		val := "0";
		if(inlist(all[i], on))
			val = "1";
		tk->cmd(top, sys->sprint("variable %s %s", v, val));
		tk->cmd(top, sys->sprint(
			"checkbutton .content.c%d -text %s -variable %s" +
			" -background %s -foreground %s -command {send act %s %d}; pack .content.c%d -side top -anchor w",
			i, tk->quote(all[i]), v, c_bg, c_fg, kind, i, i));
	}
}

panelpaths()
{
	path_items = readlines("/tool/paths");
	tk->cmd(top, sys->sprint("listbox .content.lb -height 8 -font %s -selectmode browse" +
		" -background %s -foreground %s -selectbackground %s -selectforeground %s",
		SFONT, c_bg, c_fg, c_accent, c_bg));
	for(i := 0; i < len path_items; i++)
		tk->cmd(top, sys->sprint(".content.lb insert end {%s}", path_items[i]));
	tk->cmd(top, "pack .content.lb -side top -fill both -expand 1 -pady 2");
	entryrow("padd", "");
	btn("pbind", "Bind", "bind");
	btn("punbind", "Unbind selected", "unbind");
}

panelprompts()
{
	for(i := 0; i < len prompt_files; i++){
		(nil, label) := prompt_files[i];
		lbl(sys->sprint("pl%d", i), label);
		tk->cmd(top, sys->sprint("button .content.pb%d -text {Open in Editor} -command {send act prompt %d};" +
			" pack .content.pb%d -side top -anchor w -pady 3", i, i, i));
	}
}

panelprofile()
{
	lbl("profl", "Startup profile: /lib/sh/profile");
	btn("profb", "Open in Editor", "profile");
}

panelmessaging()
{
	hdr("msgh", "Registered sources:");
	lbl("msgs", readmsgstatus());
	btn("msge", "Edit Email Account", "msgedit");
	btn("msgr", "Register Email Now", "msgregister");
	lbl("msgc", "Credentials: add an Email Account in the Keyring app.");
}

panelsecurity()
{
	hdr("sech", "YubiKey 2FA — secstore key-slots (AAL3)");
	lbl("secstat", securitystatus());
	lbl("sech1", "Fill what an action needs, then click it. The key blinks for a touch.");
	lbl("sech2", "Enroll/backup: insert ONLY the key being enrolled (unplug the others).");
	secentry("secpass", "secstore password");
	secentry("secrec", "recovery passphrase");
	secentry("secpin", "FIDO2 PIN (blank = touch-only)");
	if(twofaslot != nil && twofaslot->is2fa(getuser2fa())){
		btn("secadd", "Add a backup key", "secaddkey");
		btn("secdis", "Disable 2FA (back to password)", "secdisable");
	} else
		btn("secenr", "Enroll this security key", "secenroll");
	lbl("secres", "");
}

# A masked secret entry with a dim label prefix.
secentry(name, prompt: string)
{
	lbl(name + "l", prompt + ":");
	tk->cmd(top, sys->sprint("entry .content.%s -show * -background %s -foreground %s",
		name, c_bg, c_fg));
	tk->cmd(top, sys->sprint("pack .content.%s -side top -anchor w -fill x -pady 2", name));
}

# ── Action dispatch ────────────────────────────────────────────

handleaction(a: string)
{
	(nil, toks) := sys->tokenize(a, " ");
	if(toks == nil)
		return;
	tok := hd toks;
	arg := -1;
	if(tl toks != nil)
		arg = int hd tl toks;
	case tok {
	"cat" =>
		s := tk->cmd(top, ".cats.lb curselection");
		if(s != nil && len s > 0 && s[0] >= '0' && s[0] <= '9')
			buildpanel(int s);
	"theme" =>	applytheme(tkv("thm"));
	"llmmode" =>
		llm_is_remote = tkv("llmmode") == "remote";
		buildpanel(CatLLM);
	"llmbackend" =>	buildpanel(CatLLM);
	"llmmodel" =>
		s := tk->cmd(top, ".content.modls curselection");
		if(s != nil && len s > 0 && s[0] >= '0' && s[0] <= '9' && llm_models != nil){
			i := int s;
			if(i >= 0 && i < len llm_models){
				tk->cmd(top, ".content.model delete 0 end");
				tk->cmd(top, ".content.model insert end " + tk->quote(llm_models[i]));
			}
		}
	"llmapply" =>	applyllm();
	"keyinstall" =>	install_keyring_from_snarf();
	"keybio" =>	install_keyring_to_biometric();
	"tool" =>
		if(arg >= 0 && arg < len tool_names)
			applytool(tool_names[arg], int tkv(sys->sprint("toolv%d", arg)));
	"budget" =>
		if(arg >= 0 && arg < len budget_names)
			applybudget(budget_names[arg], int tkv(sys->sprint("budgetv%d", arg)));
	"bind" =>	dobindpath();
	"unbind" =>	dounbindpath();
	"prompt" =>
		if(arg >= 0 && arg < len prompt_files){
			(path, nil) := prompt_files[arg];
			openineditor(path);
		}
	"profile" =>
		openineditor("/lib/sh/profile");
		flashstatus("restart required for profile changes");
	"msgedit" =>	openineditor("/lib/veltro/sources/email.conf");
	"msgregister" =>	doregisteremail();
	"secenroll" =>	doenroll2fa();
	"secaddkey" =>	doaddkey2fa();
	"secdisable" =>	dodisable2fa();
	}
}

# read tokens from `prim`, falling back to the lines of `fallback`.
readtokensor(prim, fallback: string): array of string
{
	a := readtokens(prim);
	if(a == nil || len a == 0)
		a = readlines(fallback);
	return a;
}

# ── Security (YubiKey 2FA) ────────────────────────────────────

getuser2fa(): string
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

securitystatus(): string
{
	if(twofaslot == nil)
		return "2FA module unavailable";
	user := getuser2fa();
	enrolled := "NOT enrolled (password-only)";
	if(twofaslot->is2fa(user))
		enrolled = "ENROLLED (key-slot protected)";
	return sys->sprint("Account \"%s\": %s", user, enrolled);
}

setsecresult(s: string)
{
	tk->cmd(top, ".content.secres configure -text " + tk->quote(s));
	tk->cmd(top, "update");
}

tohex2fa(a: array of byte): string
{
	h := "0123456789abcdef";
	s := "";
	for(i := 0; i < len a; i++) {
		s[len s] = h[(int a[i] >> 4) & 16rf];
		s[len s] = h[int a[i] & 16rf];
	}
	return s;
}

doenroll2fa()
{
	if(twofa == nil || twofaslot == nil || random == nil) {
		setsecresult("2FA modules unavailable."); return;
	}
	pass := eget(".content.secpass");
	rec := eget(".content.secrec");
	pin := eget(".content.secpin");
	if(pass == "" || rec == "") {
		setsecresult("Need the secstore password AND a recovery passphrase."); return;
	}
	if(!twofa->available()) {
		setsecresult("Insert your security key first."); return;
	}
	setsecresult("Creating credential — TOUCH your security key now…");
	(cred, ce) := twofa->enroll(pin);
	if(ce != nil) { setsecresult("Enroll failed: " + ce); return; }
	salt := random->randombuf(Random->ReallyRandom, 32);
	if(salt == nil || len salt != 32) { setsecresult("Could not generate a salt."); return; }
	setsecresult("Binding key — TOUCH again…");
	keys := ("key", cred, tohex2fa(salt)) :: nil;
	err := twofaslot->enroll(getuser2fa(), pass, rec, keys, pin);
	if(err != nil) { setsecresult("Enroll failed: " + err); return; }
	buildpanel(CatSecurity);
	setsecresult("Enrolled. Login now needs this key (or the recovery passphrase).");
}

doaddkey2fa()
{
	if(twofa == nil || twofaslot == nil || random == nil) {
		setsecresult("2FA modules unavailable."); return;
	}
	if(!twofaslot->is2fa(getuser2fa())) {
		setsecresult("Not 2FA yet — use Enroll first."); return;
	}
	pass := eget(".content.secpass");
	rec := eget(".content.secrec");
	pin := eget(".content.secpin");
	if(pass == "" || rec == "") {
		setsecresult("A backup needs the password AND the recovery passphrase."); return;
	}
	if(!twofa->available()) {
		setsecresult("Insert the BACKUP key first."); return;
	}
	setsecresult("Creating backup credential — TOUCH the backup key…");
	(cred, ce) := twofa->enroll(pin);
	if(ce != nil) { setsecresult("Backup failed: " + ce); return; }
	salt := random->randombuf(Random->ReallyRandom, 32);
	if(salt == nil || len salt != 32) { setsecresult("Could not generate a salt."); return; }
	setsecresult("Binding backup key — TOUCH again…");
	err := twofaslot->addkey(getuser2fa(), pass, rec, cred, tohex2fa(salt), pin);
	if(err != nil) { setsecresult("Backup failed: " + err); return; }
	buildpanel(CatSecurity);
	setsecresult("Backup key added. Either key (+ password) now unlocks login.");
}

dodisable2fa()
{
	if(twofaslot == nil) {
		setsecresult("2FA module unavailable."); return;
	}
	if(!twofaslot->is2fa(getuser2fa())) {
		setsecresult("Account is already password-only."); return;
	}
	pass := eget(".content.secpass");
	rec := eget(".content.secrec");
	pin := eget(".content.secpin");
	if(pass == "") { setsecresult("Need the secstore password."); return; }
	setsecresult("Disabling 2FA — TOUCH your key if it's present…");
	err := twofaslot->disable(getuser2fa(), pass, rec, pin);
	if(err != nil) { setsecresult("Disable failed: " + err); return; }
	buildpanel(CatSecurity);
	setsecresult("2FA disabled. Login is now password-only.");
}

readthemes(): array of string
{
	fd := sys->open("/lib/lucifer/theme", Sys->OREAD);
	if(fd == nil)
		return array[] of { "brimstone", "halo" };

	names: list of string;
	n := 0;
	for(;;) {
		(count, dirs) := sys->dirread(fd);
		if(count <= 0)
			break;
		for(i := 0; i < count; i++) {
			nm := dirs[i].name;
			if(nm == "current")
				continue;
			names = nm :: names;
			n++;
		}
	}
	if(n == 0)
		return array[] of { "brimstone", "halo" };

	result := array[n] of string;
	for(j := n - 1; j >= 0; j--) {
		result[j] = hd names;
		names = tl names;
	}
	return result;
}

readcurrenttheme(): string
{
	s := readfile("/lib/lucifer/theme/current");
	if(s == nil)
		return "brimstone";
	return strip(s);
}

readlines(path: string): array of string
{
	s := readfile(path);
	if(s == nil)
		return nil;
	# Tokenize on newlines
	lines: list of string;
	n := 0;
	while(len s > 0) {
		eol := len s;
		for(i := 0; i < len s; i++) {
			if(s[i] == '\n') {
				eol = i;
				break;
			}
		}
		line := s[0:eol];
		if(eol < len s)
			s = s[eol + 1:];
		else
			s = "";
		line = strip(line);
		if(len line > 0) {
			lines = line :: lines;
			n++;
		}
	}
	if(n == 0)
		return nil;
	result := array[n] of string;
	for(j := n - 1; j >= 0; j--) {
		result[j] = hd lines;
		lines = tl lines;
	}
	return result;
}

# Read space-or-newline separated tokens from a file.
# /tool/_registry returns space-separated on one line.
readtokens(path: string): array of string
{
	s := readfile(path);
	if(s == nil)
		return nil;
	(nil, toks) := sys->tokenize(s, " \t\n");
	if(toks == nil)
		return nil;
	# Count
	n := 0;
	for(t := toks; t != nil; t = tl t)
		n++;
	result := array[n] of string;
	i := 0;
	for(t = toks; t != nil; t = tl t)
		result[i++] = hd t;
	return result;
}

inlist(s: string, arr: array of string): int
{
	if(arr == nil)
		return 0;
	for(i := 0; i < len arr; i++)
		if(arr[i] == s)
			return 1;
	return 0;
}

# ── Actions ───────────────────────────────────────────────────

applytheme(name: string)
{
	# Write to /mnt/ui/ctl for live theme switching across all zones.
	# luciuisrv persists the choice to /lib/lucifer/theme/current and
	# broadcasts a "theme <name>" global event so every zone reloads.
	fd := sys->open("/mnt/ui/ctl", Sys->OWRITE);
	if(fd != nil) {
		cmd := "theme " + name;
		b := array of byte cmd;
		sys->write(fd, b, len b);
		flashstatus("theme set to " + name);
		return;
	}
	# Fallback: write directly (pre-luciuisrv or standalone mode)
	fd = sys->open("/lib/lucifer/theme/current", Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil) {
		flashstatus(sys->sprint("error: %r"));
		return;
	}
	b := array of byte name;
	sys->write(fd, b, len b);
	flashstatus("theme set to " + name + " — restart for full effect");
}

applytool(name: string, active: int)
{
	cmd: string;
	if(active)
		cmd = "add " + name;
	else
		cmd = "remove " + name;
	writectl("/tool/ctl", cmd);
}

applybudget(name: string, enabled: int)
{
	cmd: string;
	if(enabled)
		cmd = "budget-add " + name;
	else
		cmd = "budget-remove " + name;
	writectl("/tool/ctl", cmd);
}

dobindpath()
{
	path := strip(eget(".content.padd"));
	if(len path == 0)
		return;
	writectl("/tool/ctl", "bindpath " + path);
	tk->cmd(top, ".content.padd delete 0 end");
	refreshpaths();
}

dounbindpath()
{
	s := tk->cmd(top, ".content.lb curselection");
	if(s == nil || len s == 0 || s[0] < '0' || s[0] > '9')
		return;
	idx := int s;
	if(path_items == nil || idx < 0 || idx >= len path_items)
		return;
	# Path entries may have " ro"/" rw" suffix — extract just the path
	(path, nil) := str->splitl(path_items[idx], " \t");
	if(path == nil || len path == 0)
		path = path_items[idx];
	writectl("/tool/ctl", "unbindpath " + path);
	refreshpaths();
}

# Reload the /tool/paths listing into the paths listbox.
refreshpaths()
{
	path_items = readlines("/tool/paths");
	tk->cmd(top, ".content.lb delete 0 end");
	for(i := 0; i < len path_items; i++)
		tk->cmd(top, sys->sprint(".content.lb insert end {%s}", path_items[i]));
	tk->cmd(top, "update");
}

applyllm()
{
	if(llm_is_remote) {
		# Remote mode: dial + mount at /mnt/llm.
		# Always writes auth=keyring + keyfile=/lib/keyring/serve-llm
		# so the boot's mount path takes mount -k (not anonymous
		# mount -A, which hephaestus's default keyring listener hangs
		# up on — INFR-169). If the keyfile isn't on disk yet, the
		# config still saves; the user has to install one via the
		# "Install keyfile from clipboard" button (or push it through
		# devicectl on a phone) before the next launch can authenticate.
		addr := strip(eget(".content.dial"));
		if(len addr == 0) {
			flashstatus("enter a dial address (e.g. tcp!host!5640)");
			return;
		}
		addr = dialnorm->normalize(addr);
		tk->cmd(top, ".content.dial delete 0 end");
		tk->cmd(top, ".content.dial insert end " + tk->quote(addr));
		# Persist only — the actual mount lives in the root
		# namespace established by /lib/sh/profile at boot time, so
		# mounting from this user-space process would not be visible
		# to wm's children (Veltro etc). Tell the user to restart.
		writellmconfig_full("remote", "", "", "", addr,
			"keyring", Keyringinst->DEFAULT_PATH);
		if(keyring_present())
			flashstatus("LLM dial + keyring saved — close InferNode and relaunch");
		else
			flashstatus("LLM dial saved — install keyfile, then relaunch");
		return;
	}

	# Local mode: determine selected backend
	backend := tkv("llmbackend");
	if(backend != "api" && backend != "openai")
		backend = "api";

	url := strip(eget(".content.url"));
	model := strip(eget(".content.model"));

	# If the user picked Ollama or SGLang via the stack radio (only
	# offered when backend=openai and /llm/ctl is mounted), hand off
	# to llmctl via the synthetic FS — it stops the other backend,
	# starts the chosen one, waits for health, and updates ndb. We
	# still call writellmconfig afterwards to capture the user's
	# `model=` choice (llmctl only touches `url=`).
	if(backend == "openai" && llm_have_synthfs) {
		stack := tkv("llmstack");
		if(stack != "" && stack != "custom") {
			flashstatus(sys->sprint(
				"switching to %s (may take up to 60s for cold sglang start)…",
				stack));
			err := writellmctl("set " + stack);
			if(err != "") {
				flashstatus("llmctl error: " + err);
				return;
			}
			# llmctl wrote `url=` for us; preserve model and reload.
			writellmconfig("local", backend, url, model, "");
			flashstatus(sys->sprint(
				"switched to %s — restart llmsrv for the new URL to be dialed",
				stack));
			return;
		}
	}

	writellmconfig("local", backend, url, model, "");
	flashstatus("LLM config saved — restart llmsrv for backend/URL changes");
}

readllmconfig(): (string, string, string, string, string, int)
{
	# Returns (mode, backend, url, model, dial, haskey).
	# Fallbacks are intentionally blank: a fresh install ships
	# /lib/ndb/llm with no backend or model set, and the Settings UI
	# is the user's first opportunity to pick. Pre-populating a model
	# string (especially one from a different backend than the user
	# is about to choose) is the wrong default.
	mode := "local";
	backend := "";
	url := "";
	model := "";
	dial := "";
	haskey := 0;

	lines := readlines("/lib/ndb/llm");
	if(lines != nil) {
		for(i := 0; i < len lines; i++) {
			line := lines[i];
			if(len line > 5 && line[0:5] == "mode=")
				mode = line[5:];
			else if(len line > 8 && line[0:8] == "backend=")
				backend = line[8:];
			else if(len line > 4 && line[0:4] == "url=")
				url = line[4:];
			else if(len line > 6 && line[0:6] == "model=")
				model = line[6:];
			else if(len line > 5 && line[0:5] == "dial=")
				dial = line[5:];
		}
	}

	# Set a default URL ONLY when the user has already chosen a backend
	# but the URL field is empty. If backend is also blank (fresh install),
	# leave URL blank too - the user picks both.
	if(url == "" && backend != "") {
		if(backend == "openai")
			url = "http://localhost:11434/v1";
		else if(backend == "api")
			url = "https://api.anthropic.com";
	}

	# Check for API key in factotum
	fd := sys->open("/mnt/factotum/ctl", Sys->OREAD);
	if(fd != nil) {
		buf := array[4096] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0) {
			content := string buf[0:n];
			if(hassubstr(content, "anthropic") || hassubstr(content, "llm"))
				haskey = 1;
		}
	}

	return (mode, backend, url, model, dial, haskey);
}

# The connected backend's model catalogue, read from /mnt/llm/models
# (served by llmsrv). nil when the file is absent/empty — no llmsrv
# mounted, the backend is unreachable, or it lists nothing. The read is
# fast in the common cases (a local GET, or an immediate dial-refused),
# so calling it from layout is fine.
readllmmodels(): array of string
{
	return readlines("/mnt/llm/models");
}

writellmconfig(mode, backend, url, model, dial: string)
{
	writellmconfig_full(mode, backend, url, model, dial, "", "");
}

# Extended form that also writes auth=/keyfile= when those are set.
# Pass auth="" + keyfile="" to leave any existing entries untouched
# (matches the old single-arg writellmconfig behaviour). Pass
# non-empty values to overwrite them — Remote 9P (INFR-169) takes
# auth="keyring" + keyfile=Keyringinst->DEFAULT_PATH so the boot path uses
# mount -k instead of falling through to anonymous mount -A.
writellmconfig_full(mode, backend, url, model, dial, auth, keyfile: string)
{
	# Preserve unknown keys we don't manage; auth=/keyfile= are
	# rewritten only when the caller passes a value.
	extra := "";
	existing := readlines("/lib/ndb/llm");
	for(i := 0; i < len existing; i++) {
		line := existing[i];
		if(islinekey(line, "mode") || islinekey(line, "backend") ||
		   islinekey(line, "url") || islinekey(line, "model") ||
		   islinekey(line, "dial"))
			continue;
		if(auth != "" && islinekey(line, "auth"))
			continue;
		if(keyfile != "" && islinekey(line, "keyfile"))
			continue;
		extra += line + "\n";
	}

	fd := sys->create("/lib/ndb/llm", Sys->OWRITE, 8r666);
	if(fd == nil) {
		flashstatus(sys->sprint("cannot write config: %r"));
		return;
	}
	config := sys->sprint("mode=%s\nbackend=%s\nurl=%s\nmodel=%s\ndial=%s\n",
		mode, backend, url, model, dial);
	if(auth != "")
		config += "auth=" + auth + "\n";
	if(keyfile != "")
		config += "keyfile=" + keyfile + "\n";
	config += extra;
	b := array of byte config;
	sys->write(fd, b, len b);
}

# Keyring helpers (INFR-169) — thin shims around keyringinst so the
# install path can be unit-tested without dragging in wmclient or
# the Settings UI. See appl/lib/keyringinst.b and
# tests/keyringinst_test.b.
keyring_present(): int
{
	return keyringinst->present();
}

keyring_status_text(): string
{
	return keyringinst->status_text();
}

# Snarf → prepare_payload → install_payload. Settings owns the UI
# (snarf read + flashstatus); keyringinst owns the file write so we
# can exercise it from a test that targets /tmp.
install_keyring_from_snarf()
{
	buf := snarfget();
	if(buf == nil || len buf == 0) {
		flashstatus("clipboard is empty — copy the serve-llm keyfile first");
		return;
	}
	payload := keyringinst->prepare_payload(buf);
	err := keyringinst->install_payload(payload, Keyringinst->DEFAULT_PATH);
	if(err != nil) {
		flashstatus(err);
		return;
	}
	flashstatus(sys->sprint("keyfile installed (%d bytes) at %s",
		len payload, Keyringinst->DEFAULT_PATH));
}

# Snarf → prepare_payload → bioauth->store. The slot name "serve-llm"
# is what boot.sh asks for via /phone/bio_retrieve before falling back
# to the plaintext file. Triggers the OS biometric prompt on the
# device — caller blocks here until the user authenticates.
install_keyring_to_biometric()
{
	if(bioauth == nil) {
		flashstatus("biometric: module not loaded");
		return;
	}
	buf := snarfget();
	if(buf == nil || len buf == 0) {
		flashstatus("clipboard is empty — copy the serve-llm keyfile first");
		return;
	}
	payload := keyringinst->prepare_payload(buf);
	err := bioauth->store("serve-llm", payload);
	if(err != nil) {
		flashstatus(err);
		return;
	}
	flashstatus(sys->sprint("keyfile sealed in biometric store (%d bytes, slot serve-llm)",
		len payload));
}

islinekey(line, key: string): int
{
	klen := len key + 1;
	return len line >= klen && line[0:klen] == key + "=";
}

# ── /llm synthetic FS (served by llmctl9p) ────────────────────
# Settings reads /llm/status for live state and writes verbs to
# /llm/ctl. The daemon owns the actual systemctl + ndb work; this
# file does uniform file I/O only — no shell exec, no special-case
# logic for "which backend is up". When the daemon isn't mounted we
# fall back to the legacy URL-only path.

synthfs_present(): int
{
	(ok, nil) := sys->stat("/llm/ctl");
	return ok >= 0;
}

readllmstatus_raw(): string
{
	fd := sys->open("/llm/status", Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# Single-line status summary for the panel label. Reduces the daemon's
# verbose multi-line output to "backend / healthy / url".
readllmstatus_summary(): string
{
	raw := readllmstatus_raw();
	if(raw == "")
		return "Stack status: (llmctl9p daemon not responding)";
	backend := pickfield(raw, "backend");
	healthy := pickfield(raw, "healthy");
	return sys->sprint("Stack status: active=%s healthy=%s", backend, healthy);
}

# `key  value` (two-space delimited per the daemon's format). Returns
# the value or "" if the field is absent.
pickfield(raw, key: string): string
{
	(lines, nil) := splitlines(raw);
	for(i := 0; i < len lines; i++) {
		line := lines[i];
		if(len line > len key && line[0:len key] == key) {
			rest := line[len key:];
			while(len rest > 0 && (rest[0] == ' ' || rest[0] == '\t'))
				rest = rest[1:];
			return rest;
		}
	}
	return "";
}

splitlines(s: string): (array of string, string)
{
	# Walk once to count, again to fill. Trailing newline is dropped.
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	if(len s > 0 && s[len s - 1] != '\n')
		n++;
	out := array[n] of string;
	last := 0; k := 0;
	for(i = 0; i < len s; i++) {
		if(s[i] == '\n') {
			out[k++] = s[last:i];
			last = i + 1;
		}
	}
	if(last < len s)
		out[k++] = s[last:];
	return (out, nil);
}

# Map current /llm/status "backend" value to a llm_stack_names index.
# Anything that isn't ollama/sglang collapses to "custom" so an
# externally-managed setup doesn't surprise the radio.
llm_stack_index_from_status(): int
{
	b := pickfield(readllmstatus_raw(), "backend");
	for(i := 0; i < len llm_stack_names; i++)
		if(llm_stack_names[i] == b)
			return i;
	return len llm_stack_names - 1;	# "custom"
}

# Write a verb to /llm/ctl. Returns "" on success, a human-readable
# error string on failure. The daemon validates the verb and shells
# out to host llmctl; that synchronous host call may take ~60s on a
# cold sglang start (flashinfer JIT compile).
writellmctl(verb: string): string
{
	fd := sys->open("/llm/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open /llm/ctl: %r");
	b := array of byte verb;
	n := sys->write(fd, b, len b);
	if(n != len b)
		return sys->sprint("write /llm/ctl: %r");
	return "";
}

secstoreunlocked(): int
{
	(ok, nil) := sys->stat("/tmp/.secstore-unlocked");
	return ok >= 0;
}

hassubstr(s, sub: string): int
{
	slen := len s;
	sublen := len sub;
	if(sublen > slen)
		return 0;
	for(i := 0; i <= slen - sublen; i++) {
		if(s[i:i+sublen] == sub)
			return 1;
	}
	return 0;
}

# Read the live source registry from /mnt/msg/status (best-effort display).
readmsgstatus(): string
{
	fd := sys->open("/mnt/msg/status", Sys->OREAD);
	if(fd == nil)
		return "(msg9p not mounted at /mnt/msg)";
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "(no sources registered)";
	return string buf[:n];
}

# Register the email source live from /lib/veltro/sources/email.conf — the same
# line boot replays at startup. Credentials come from the keyring Email Account;
# a missing-creds register fails softly and is reported in the status bar.
doregisteremail()
{
	cfd := sys->open("/lib/veltro/sources/email.conf", Sys->OREAD);
	if(cfd == nil) {
		flashstatus("no email.conf — use Edit Email Account first");
		return;
	}
	cbuf := array[1024] of byte;
	cn := sys->read(cfd, cbuf, len cbuf);
	if(cn <= 0) {
		flashstatus("email.conf is empty");
		return;
	}
	conf := string cbuf[:cn];
	while(len conf > 0 && (conf[len conf-1]=='\n' || conf[len conf-1]==' ' || conf[len conf-1]=='\t' || conf[len conf-1]=='\r'))
		conf = conf[:len conf-1];

	cmd := "register email /dis/veltro/sources/email.dis " + conf;
	wfd := sys->open("/mnt/msg/ctl", Sys->OWRITE);
	if(wfd == nil) {
		flashstatus("cannot open /mnt/msg/ctl");
		return;
	}
	b := array of byte cmd;
	if(sys->write(wfd, b, len b) != len b)
		flashstatus(sys->sprint("register failed: %r"));
	else
		flashstatus("email source registered");

	# Refresh the live registry display.
	if(category == CatMessaging)
		buildpanel(CatMessaging);
}

openineditor(path: string)
{
	# Check if the file is accessible first
	(ok, nil) := sys->stat(path);
	if(ok < 0) {
		flashstatus(path + " not accessible — check namespace paths");
		sys->fprint(stderr, "settings: stat %s failed: %r\n", path);
		return;
	}

	# Write to presentation ctl to launch editor with the file.
	# /tool/activity exists only in agent namespaces; from a GUI app
	# launched by lucifer we read /mnt/ui/activity/current instead.
	actid := readfile("/mnt/ui/activity/current");
	if(actid == nil) {
		flashstatus("cannot reach presentation zone — is luciuisrv running?");
		sys->fprint(stderr, "settings: cannot read /mnt/ui/activity/current\n");
		return;
	}
	aid := strip(actid);
	pctl := sys->sprint("/mnt/ui/activity/%s/presentation/ctl", aid);
	sys->fprint(stderr, "settings: openineditor %s → pctl=%s\n", path, pctl);

	# Kill existing editor first (ignore error — may not exist)
	fd := sys->open(pctl, Sys->OWRITE);
	if(fd == nil) {
		flashstatus("cannot open presentation ctl — launch from Lucifer");
		sys->fprint(stderr, "settings: cannot open %s: %r\n", pctl);
		return;
	}
	kb := array of byte "kill id=editor";
	kn := sys->write(fd, kb, len kb);
	sys->fprint(stderr, "settings: kill id=editor → %d\n", kn);
	fd = nil;

	# Small delay for kill to propagate
	sys->sleep(100);

	# Create editor artifact with file path as data
	fd = sys->open(pctl, Sys->OWRITE);
	if(fd == nil) {
		flashstatus("cannot open presentation ctl");
		sys->fprint(stderr, "settings: cannot reopen %s: %r\n", pctl);
		return;
	}
	cmd := sys->sprint("create id=editor type=app dis=/dis/wm/editor.dis label=editor data=%s", path);
	b := array of byte cmd;
	n := sys->write(fd, b, len b);
	sys->fprint(stderr, "settings: create → %d (%s)\n", n, cmd);
	fd = nil;
	if(n < 0) {
		flashstatus(sys->sprint("editor launch failed: %r"));
		return;
	}

	# Center the editor tab
	fd = sys->open(pctl, Sys->OWRITE);
	if(fd != nil) {
		b = array of byte "center id=editor";
		cn := sys->write(fd, b, len b);
		sys->fprint(stderr, "settings: center id=editor → %d\n", cn);
		fd = nil;
	}

	flashstatus("opened " + path + " in editor");
}

# ── Theme listener ─────────────────────────────────────────────

themelistener()
{
	fd := sys->open("/mnt/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		# INFR-28: reset client-side fid offset so the next read on
		# this streaming queue starts at 0 (otherwise the kernel
		# applies the accumulated offset to the server reply and
		# truncates / EOFs on the third read onward).
		sys->seek(fd, big 0, Sys->SEEKSTART);
		if(len ev >= 6 && ev[0:6] == "theme ")
			themech <-= 1;
	}
}

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		c_bg = col(th.editbg >> 8);
		c_fg = col(th.edittext >> 8);
		c_dim = col(th.dim >> 8);
		c_accent = col(th.accent >> 8);
		c_border = col(th.editlineno >> 8);
	} else {
		c_bg = col(16r080808);
		c_fg = col(16rcccccc);
		c_dim = col(16r999999);
		c_accent = col(16re8553a);
		c_border = col(16r131313);
	}
}

reloadcolors()
{
	loadcolors();
	if(top == nil)
		return;
	tkclient->wmctl(top, "retheme");
	cat := category;
	tk->cmd(top, "destroy .cats");
	tk->cmd(top, "destroy .content");
	tk->cmd(top, "destroy .status");
	buildui();
	buildpanel(cat);
}

# ── Helpers ───────────────────────────────────────────────────

writectl(path, cmd: string)
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil) {
		flashstatus(sys->sprint("error: %r"));
		return;
	}
	b := array of byte cmd;
	n := sys->write(fd, b, len b);
	if(n < 0)
		flashstatus(sys->sprint("error: %r"));
}

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

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

snarfget(): string
{
	fd := sys->open("/chan/snarf", Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[4096] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[:n];
	}
	return s;
}
flashstatus(msg: string)
{
	if(top != nil){
		tk->cmd(top, ".status configure -text " + tk->quote(msg));
		tk->cmd(top, "update");
	}
}
