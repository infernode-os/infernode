implement WmLogon;

#
# InferNode Login Screen / Secstore Unlock
#
# Fullscreen login displayed at boot before the window manager starts.
#
# The form is Tk. There is no window manager yet, but Tk has never
# needed one: it needs a window to draw in, and this allocates a
# screen over the display and gives Tk a backed window covering it.
# That buys everything a text field is expected to do -- click to
# place the caret, arrow keys, Home/End, drag to select, masking --
# and a backing store, so the panel never shows a half-painted frame.
# The first version of this screen drew with the raw draw library and
# hand-rolled a field that could append and backspace and nothing
# else; on bare metal every one of its shortcuts showed.
#
# Shows brand image, password field, version info.
# On Enter: unlocks secstore and loads keys into factotum.
# On Escape (double-press): skip with warning (keys won't persist).
# Exits after unlock, allowing boot to continue.
#
# First boot: prompts for new password + confirmation, creates secstore account.
# Subsequent boots: prompts for password, unlocks secstore, loads keys.
#
# For headless: profile detects no display and falls back to console prompt.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Screen, Image, Point, Rect, Pointer: import draw;

include "tk.m";
	tk: Tk;

include "lucitheme.m";
	lucitheme: Lucitheme;

include "bufio.m";
	bufio: Bufio;

include "imagefile.m";

include "dial.m";

include "secstore.m";
	secstore: Secstore;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "factotum.m";
	factotum: Factotum;

include "twofaslot.m";

include "sh.m";

WmLogon: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

IMGPATH:  con "/lib/lucifer/login-screen.png";
BODYFONT: con "/fonts/combined/unicode.sans.14.font";
SMALLFONT: con "/fonts/combined/unicode.sans.12.font";
FIELDW:   con 300;
PADDING:  con 16;

# Login states
STATE_LOGIN:		con 0;
STATE_SETUP_PASS:	con 1;
STATE_SETUP_CONFIRM:	con 2;
STATE_LOGIN_FAILED:	con 3;
STATE_RECOVERY:		con 4;
STATE_FIDOPIN:		con 5;

display_g: ref Display;
top: ref Tk->Toplevel;
logo_g: ref Image;	# cached brand image

# Password state
passbuf: string;
confirmbuf: string;
savedpass: string;
savedloginpass: string;	# secstore password held while prompting for the recovery passphrase
current2fadkhex: string;	# 2FA data key (hex) for this session — for DK-encrypted secstore save-back
statusmsg: string;
state: int;
escpending: int;

stderr: ref Sys->FD;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	bufio = load Bufio Bufio->PATH;
	kr = load Keyring Keyring->PATH;
	secstore = load Secstore Secstore->PATH;
	factotum = load Factotum Factotum->PATH;
	lucitheme = load Lucitheme Lucitheme->PATH;

	# Open display directly (no wmclient)
	if(ctxt != nil && ctxt.display != nil)
		display_g = ctxt.display;
	if(display_g == nil) {
		display_g = Display.allocate(nil);
		if(display_g == nil) {
			# No display — headless fallback
			headlessprompt();
			return;
		}
	}

	# If factotum was already started with secstore backing (e.g. headless
	# mode with $SECSTORE_PASSWORD), skip the login screen entirely.
	if(factotumhaskeys()) {
		createsecstoresentinel();
		return;
	}

	passbuf = "";
	confirmbuf = "";
	savedpass = "";
	escpending = 0;

	# Load brand image once (reloading per-redraw can fail under resource pressure)
	logo_g = loadpng(IMGPATH);

	# Brief delay for display to settle (prevents blank-screen glitch
	# when the display is still initializing on fast startup)
	sys->sleep(200);

	if(!secstoreacctexists()) {
		state = STATE_SETUP_PASS;
		statusmsg = "First boot — choose a secstore password";
	} else {
		state = STATE_LOGIN;
		statusmsg = "Enter password to unlock";
	}

	if(tk == nil || !buildform()) {
		sys->fprint(stderr, "logon: cannot build the login form: %r\n");
		headlessprompt();
		return;
	}
	redraw();

	# Input straight from the devices: there is no window manager to
	# route it yet. Enter and Escape drive the state machine here;
	# everything else is the field's business and goes to Tk.
	kbdfd := sys->open("/dev/keyboard", Sys->OREAD);
	if(kbdfd == nil) {
		sys->fprint(stderr, "logon: cannot open /dev/keyboard: %r\n");
		headlessprompt();
		return;
	}
	ptrfd := sys->open("/dev/pointer", Sys->OREAD);

	kbdch := chan of int;
	ptrch := chan of ref Pointer;
	pids := chan of int;
	spawn kbdreader(kbdfd, kbdch, pids);
	kbdpid := <-pids;
	ptrpid := -1;
	if(ptrfd != nil){
		spawn ptrreader(ptrfd, ptrch, pids);
		ptrpid = <-pids;
	}

	#
	# A break inside an alt arm leaves the alt, not the loop (the
	# first version of this loop did exactly that and the desktop
	# never started), so the loop's exit is a flag.
	#
	done := 0;
	while(!done) alt {
	k := <-kbdch =>
		if(k < 0)
			done = 1;
		else case k {
		'\n' or '\r' =>
			escpending = 0;
			passbuf = fieldtext();
			done = handleenter();
		27 =>	# Escape
			passbuf = fieldtext();
			done = handleescape();
		* =>
			escpending = 0;
			tk->keyboard(top, k);
			tk->cmd(top, "update");
		}
	p := <-ptrch =>
		tk->pointer(top, *p);
		tk->cmd(top, "update");
	}

	# The readers are blocked in read; left alone they would go on
	# eating the desktop's keystrokes after this screen is gone.
	kill(kbdpid);
	if(ptrpid >= 0)
		kill(ptrpid);
}

kbdreader(fd: ref Sys->FD, out: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s := string buf[0:n];
		for(i := 0; i < len s; i++)
			out <-= s[i];
	}
	out <-= -1;
}

ptrreader(fd: ref Sys->FD, out: chan of ref Pointer, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	buf := array[64] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s := string buf[0:n];
		if(len s < 2 || s[0] != 'm')
			continue;
		(nf, f) := sys->tokenize(s[1:], " ");
		if(nf < 3)
			continue;
		x := int hd f; f = tl f;
		y := int hd f; f = tl f;
		b := int hd f;
		out <-= ref Pointer(b, Point(x, y), 0);
	}
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

fieldtext(): string
{
	return tk->cmd(top, ".f.pw get");
}

# Returns 1 if login screen should exit
handleenter(): int
{
	case state {
	STATE_SETUP_PASS =>
		if(passbuf == nil || passbuf == "") {
			statusmsg = "Password required";
			redraw();
			return 0;
		}
		savedpass = passbuf;
		passbuf = "";
		state = STATE_SETUP_CONFIRM;
		statusmsg = "Confirm your password";
		redraw();
		return 0;

	STATE_SETUP_CONFIRM =>
		if(passbuf != savedpass) {
			statusmsg = "Passwords don't match — try again";
			passbuf = "";
			savedpass = "";
			state = STATE_SETUP_PASS;
			redraw();
			return 0;
		}
		# Passwords match — create account and unlock
		dosetupandunlock(passbuf);
		passbuf = "";
		savedpass = "";
		return 1;

	STATE_LOGIN =>
		r := dounlock();
		if(r == 1)
			return 1;
		if(r == 2){	# moved to the recovery-passphrase prompt
			redraw();
			return 0;
		}
		# Unlock failed — let user retry or skip
		state = STATE_LOGIN_FAILED;
		statusmsg += "\nEnter: try again  |  Escape: continue without secstore";
		redraw();
		return 0;

	STATE_LOGIN_FAILED =>
		# Enter from failed state — go back to password entry
		passbuf = "";
		state = STATE_LOGIN;
		statusmsg = "Enter password to unlock";
		redraw();
		return 0;

	STATE_RECOVERY =>
		if(passbuf == nil || passbuf == "") {
			statusmsg = "Recovery passphrase required";
			redraw();
			return 0;
		}
		statusmsg = "Unlocking with recovery passphrase...";
		redraw();
		rerr := connectfactotum(savedloginpass, passbuf, "");
		passbuf = "";
		if(rerr == nil) {
			enablesecstoresave(savedloginpass);
			createsecstoresentinel();
			savedloginpass = "";
			finishunlock();
			return 1;
		}
		savedloginpass = "";
		state = STATE_LOGIN_FAILED;
		statusmsg = "Recovery failed\nEnter: try again  |  Escape: continue without secstore";
		redraw();
		return 0;

	STATE_FIDOPIN =>
		fidopin := passbuf;		# blank allowed (touch-only keys)
		passbuf = "";
		statusmsg = "Unlocking with your security key (touch it)...";
		redraw();
		ferr := connectfactotum(savedloginpass, "", fidopin);
		if(ferr == nil) {
			enablesecstoresave(savedloginpass);
			createsecstoresentinel();
			savedloginpass = "";
			finishunlock();
			return 1;
		}
		if(ferr == "NEEDRECOVERY" || (len ferr >= 13 && ferr[:13] == "NEEDRECOVERY:")) {
			state = STATE_RECOVERY;
			statusmsg = "Security key didn't unlock — enter recovery passphrase";
			if(len ferr > 13)
				statusmsg = "Security key failed (" + ferr[13:] + ") — enter recovery passphrase";
			redraw();
			return 0;
		}
		savedloginpass = "";
		state = STATE_LOGIN_FAILED;
		statusmsg = "Unlock failed: " + ferr + "\nEnter: try again  |  Escape: continue without secstore";
		redraw();
		return 0;
	}
	return 0;
}

# Returns 1 if login screen should exit
handleescape(): int
{
	case state {
	STATE_SETUP_CONFIRM =>
		# Go back to password entry
		passbuf = "";
		savedpass = "";
		state = STATE_SETUP_PASS;
		statusmsg = "Choose a secstore password";
		redraw();
		return 0;

	STATE_LOGIN_FAILED =>
		# User chose to continue without secstore after failed unlock
		statusmsg = "Continuing without secstore";
		redraw();
		sys->sleep(500);
		return 1;

	* =>
		# Double-press escape to skip
		if(escpending) {
			statusmsg = "Skipped";
			redraw();
			sys->sleep(300);
			return 1;
		}
		escpending = 1;
		statusmsg = "Keys won't persist. Press Escape again to skip.";
		redraw();
		return 0;
	}
}

# A Tk colour from a packed lucitheme colour (0xRRGGBBAA).
tkcol(c: int): string
{
	return sys->sprint("#%06x", (c >> 8) & 16rffffff);
}

#
# The form. A screen over the display, a backed window covering it,
# and the widgets; redraw() decides which of them show.
#
buildform(): int
{
	di := display_g.image;

	bg := int 16r1a1a1aff;
	input := int 16r2a2a2aff;
	accent := int 16rff5500ff;
	text := int 16rffffffff;
	dim := int 16r666666ff;
	red := int 16rff4444ff;
	if(lucitheme != nil){
		th := lucitheme->gettheme();
		if(th != nil){
			bg = th.bg;
			input = th.input;
			accent = th.accent;
			text = th.text;
			dim = th.dim;
			red = th.red;
		}
	}

	scr := Screen.allocate(di, display_g.color(bg), 0);
	if(scr == nil)
		return 0;
	di.draw(di.r, scr.fill, nil, scr.fill.r.min);
	win := scr.newwindow(di.r, Draw->Refbackup, bg);
	if(win == nil)
		return 0;

	top = tk->toplevel(display_g, "-bd 0 -bg " + tkcol(bg));
	if(top == nil)
		return 0;
	top.screenr = di.r;
	e := tk->putimage(top, ".", win, nil);
	if(e != nil){
		sys->fprint(stderr, "logon: tk window: %s\n", e);
		return 0;
	}

	cmds := array[] of {
		". configure -width " + string di.r.dx() + " -height " + string di.r.dy(),
		"pack propagate . 0",
		"frame .f -bd 0 -bg " + tkcol(bg),
		"label .f.prompt -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + BODYFONT,
		"entry .f.pw -show • -width " + string FIELDW + " -bd 0 -relief flat"
			+ " -bg " + tkcol(input) + " -fg " + tkcol(text)
			+ " -highlightthickness 1 -highlightcolor " + tkcol(accent)
			+ " -selectbackground " + tkcol(accent)
			+ " -font " + BODYFONT,
		"label .f.status -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + BODYFONT,
		"label .f.err -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(red) + " -font " + BODYFONT,
		"label .f.choice -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(text) + " -font " + BODYFONT,
		"label .f.warn1 -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + SMALLFONT
			+ " -text {Keys and secrets will not be available.}",
		"label .f.warn2 -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + SMALLFONT
			+ " -text {AI integration may not work.}",
		"frame .b -bd 0 -bg " + tkcol(bg),
		"label .b.version -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + SMALLFONT,
		"label .b.copy -bd 0 -bg " + tkcol(bg) + " -fg " + tkcol(dim) + " -font " + SMALLFONT,
		"pack .b.version .b.copy -side top",
		"pack .b -side bottom -pady " + string PADDING,
		"pack .f -expand 1",
	};
	for(i := 0; i < len cmds; i++){
		e = tk->cmd(top, cmds[i]);
		if(e != nil && e[0] == '!')
			sys->fprint(stderr, "logon: tk: %s: %s\n", cmds[i], e);
	}

	if(logo_g != nil){
		# The brand image is RGBA. Composite it over the background
		# here, once, and hand Tk an opaque image of known geometry.
		flat := display_g.newimage(Rect((0, 0), (logo_g.r.dx(), logo_g.r.dy())), di.chans, 0, bg);
		if(flat != nil){
			flat.draw(flat.r, logo_g, nil, logo_g.r.min);
			logo_g = flat;
		}
		tk->cmd(top, "image create bitmap logo");
		tk->putimage(top, "logo", logo_g, nil);
		tk->cmd(top, "label .f.logo -bd 0 -image logo -bg " + tkcol(bg));
	}
	# There is no window manager to say so: this window has the keyboard.
	tk->cmd(top, "focus -global 1");

	version := rf("/dev/sysctl");
	if(version == nil)
		version = brandname();
	tk->cmd(top, ".b.version configure -text " + tk->quote(version));
	tk->cmd(top, ".b.copy configure -text " + tk->quote(brandcopyright()));
	return 1;
}

#
# Show the state: which widgets are packed and what they say. Every
# state change in the handlers ends by calling this.
#
redraw()
{
	if(top == nil)
		return;

	for(w := list of {".f.logo", ".f.prompt", ".f.pw", ".f.status", ".f.err", ".f.choice", ".f.warn1", ".f.warn2"}; w != nil; w = tl w)
		tk->cmd(top, "pack forget " + hd w);

	if(logo_g != nil)
		tk->cmd(top, "pack .f.logo -side top -pady " + string PADDING);

	if(state == STATE_LOGIN_FAILED) {
		# Failed state: show error and choices, no password field
		errline := statusmsg;
		choiceline := "";
		for(si := 0; si < len errline; si++)
			if(errline[si] == '\n') {
				choiceline = errline[si+1:];
				errline = errline[0:si];
				break;
			}
		tk->cmd(top, ".f.err configure -text " + tk->quote(errline));
		tk->cmd(top, "pack .f.err -side top -pady 8");
		if(choiceline != "") {
			tk->cmd(top, ".f.choice configure -text " + tk->quote(choiceline));
			tk->cmd(top, "pack .f.choice -side top -pady 8");
		}
		tk->cmd(top, "pack .f.warn1 .f.warn2 -side top");
	} else {
		prompt := "Password:";
		case state {
		STATE_SETUP_PASS =>
			prompt = "New password:";
		STATE_SETUP_CONFIRM =>
			prompt = "Confirm password:";
		STATE_RECOVERY =>
			prompt = "Recovery passphrase:";
		STATE_FIDOPIN =>
			prompt = "Security key PIN:";
		}
		tk->cmd(top, ".f.prompt configure -text " + tk->quote(prompt));
		tk->cmd(top, "pack .f.prompt -side top -pady 2");
		if(passbuf == "")
			tk->cmd(top, ".f.pw delete 0 end");
		tk->cmd(top, "pack .f.pw -side top");
		tk->cmd(top, ".f.status configure -text " + tk->quote(statusmsg));
		if(statusmsg != nil && statusmsg != "")
			tk->cmd(top, "pack .f.status -side top -pady " + string PADDING);
		tk->cmd(top, "focus .f.pw");
	}
	tk->cmd(top, "update");
}

# First boot: create secstore account, then unlock
dosetupandunlock(pass: string)
{
	statusmsg = "Creating secstore account...";
	redraw();
	err := createsecstoreacct(pass);
	if(err != nil) {
		statusmsg = "Setup failed: " + err;
		redraw();
		sys->sleep(2000);
		return;
	}

	statusmsg = "Unlocking (this may take a moment)...";
	redraw();

	err = connectfactotum(pass, "", "");
	if(err == nil) {
		enablesecstoresave(pass);
		createsecstoresentinel();
	}

	pass = "";

	if(err != nil) {
		statusmsg = err;
		redraw();
		sys->sleep(2000);
		return;
	}

	finishunlock();
}

# Normal boot: unlock secstore and load keys.
# Returns 1 on success, 0 on failure.
# 1 if this account has 2FA key-slots (checked locally, before secstore).
accountis2fa(): int
{
	ts := load Twofaslot Twofaslot->PATH;
	if(ts == nil)
		return 0;
	ts->init();
	u := rf("/dev/user");
	if(u == nil)
		u = "inferno";
	return ts->is2fa(u);
}

dounlock(): int
{
	if(passbuf == nil || passbuf == "") {
		statusmsg = "Password required";
		redraw();
		return 0;
	}

	# 2FA accounts: collect the security-key PIN (UV / AAL3) before unlocking.
	# Blank PIN is fine for touch-only keys; legacy accounts unlock directly.
	if(accountis2fa()){
		savedloginpass = passbuf;
		passbuf = "";
		state = STATE_FIDOPIN;
		statusmsg = "Enter your security key PIN (blank if none)";
		return 2;
	}

	statusmsg = "Unlocking (this may take a moment)...";
	redraw();

	err := connectfactotum(passbuf, "", "");

	# Establish secstore save-back path so future keys persist
	if(err == nil) {
		enablesecstoresave(passbuf);
		createsecstoresentinel();
	}

	passbuf = "";	# zero password

	if(err != nil) {
		statusmsg = err;
		redraw();
		return 0;
	}

	finishunlock();
	return 1;
}

# Create sentinel so other apps can detect secstore is active
createsecstoresentinel()
{
	fd := sys->create("/tmp/.secstore-unlocked", Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "1");
}

# Post-unlock status. logon exits right after this and its last drawn frame
# lingers on screen while lucifer + the veltro tools boot (a few seconds), so
# leave the user on "Starting desktop..." rather than a frozen "Unlocked".
finishunlock()
{
	statusmsg = "Unlocked";
	redraw();
	ensurellmsrv();
	statusmsg = "Starting desktop...";
	redraw();
}

# Start llmsrv if not already running.
# llmsrv may have failed during profile because the API key
# was only in secstore (not yet loaded at profile time).
ensurellmsrv()
{
	(ok, nil) := sys->stat("/mnt/llm");
	if(ok >= 0)
		return;	# already running

	sys->fprint(stderr, "logon: /mnt/llm not mounted, starting llmsrv\n");
	spawn startllmsrv();
	sys->sleep(1000);	# give it time to mount
}

startllmsrv()
{
	mod := load Command "/dis/llmsrv.dis";
	if(mod == nil) {
		sys->fprint(stderr, "logon: cannot load llmsrv: %r\n");
		return;
	}
	mod->init(nil, "llmsrv" :: nil);
}

connectfactotum(pass, recoverypass, fidopin: string): string
{
	current2fadkhex = "";	# set below only if a 2FA slot unlock yields the DK
	if(secstore == nil)
		return "secstore module not loaded";
	secstore->init();
	if(factotum == nil)
		return "factotum module not loaded";
	factotum->init();

	user := rf("/dev/user");
	if(user == nil)
		user = "inferno";

	pwhash := secstore->mkseckey(pass);
	pwhash2 := secstore->mkseckey2(pass);
	rootkey := secstore->mkfilekey3(user, pass);
	filekey := secstore->mkfilekey2(pass);
	legacykey := secstore->mkfilekey(pass);

	(conn, nil, diag) := secstore->connect2("tcp!127.0.0.1!5356", user, pwhash, pwhash2);
	if(conn == nil) {
		if(diag != nil)
			return "secstore: " + diag;
		return sys->sprint("secstore: %r");
	}

	file := secstore->getfile(conn, "factotum", 0);
	secstore->bye(conn);

	if(file == nil) {
		sys->fprint(stderr, "logon: secstore has no factotum file for %s (new account or read failure)\n", user);
		return nil;
	}

	# 2FA accounts encrypt the factotum blob under a data key wrapped in
	# YubiKey/recovery key-slots; legacy password-only accounts have no slots
	# and take the unchanged path below. Strictly additive — no slots, no change.
	plaintext: array of byte;
	twofaslot := load Twofaslot Twofaslot->PATH;
	is2fa := 0;
	if(twofaslot != nil){
		twofaslot->init();
		is2fa = twofaslot->is2fa(user);
	}
	if(is2fa){
		# Try the present YubiKey (touch); if recoverypass is given, unlock()
		# also tries the recovery slot.
		(dk, unlockerr) := twofaslot->unlock(user, rootkey, recoverypass, fidopin);	# touch + (FIDO PIN if UV)
		if(dk != nil){
			plaintext = secstore->decrypt3(file, dk, nil, nil);
			current2fadkhex = tohex(dk);	# retain DK so save-back stays DK-encrypted (no downgrade)
		}
		# Fall back to the password path if the blob is still password-encrypted
		# — a legacy/un-migrated blob during an incomplete enroll/disable. A
		# fully migrated 2FA blob will NOT decrypt under the password, so strong
		# mode is preserved when the key is simply absent.
		if(plaintext == nil)
			plaintext = secstore->decrypt3(file, rootkey, filekey, legacykey);
		if(plaintext == nil){
			if(recoverypass == ""){
				# NEEDRECOVERY tells logon to prompt for the recovery passphrase.
				# Suffix the actual derive error so the screen can show "PIN
				# invalid" / "PIN blocked" instead of leaving the user guessing.
				if(unlockerr != nil && unlockerr != "")
					return "NEEDRECOVERY:" + unlockerr;
				return "NEEDRECOVERY";
			}
			return "recovery passphrase did not unlock";
		}
	}else{
		plaintext = secstore->decrypt3(file, rootkey, filekey, legacykey);
		if(plaintext == nil)
			return "wrong password";
	}

	# Parse key lines and add to running factotum
	lines := string plaintext;
	secstore->erasekey(plaintext);

	fd := sys->open("/mnt/factotum/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open factotum: %r");

	nloaded := 0;
	line := "";
	for(i := 0; i < len lines; i++) {
		if(lines[i] == '\n') {
			if(len line > 4 && line[0:4] == "key ") {
				b := array of byte line;
				sys->write(fd, b, len b);
				nloaded++;
			}
			line = "";
		} else
			line[len line] = lines[i];
	}
	if(len line > 4 && line[0:4] == "key ") {
		b := array of byte line;
		sys->write(fd, b, len b);
		nloaded++;
	}

	sys->fprint(stderr, "logon: loaded %d keys from secstore\n", nloaded);

	# The password just authenticated against the stored PAK verifier, so it is
	# safe to (re)derive and upgrade a legacy verifier to secstore3. Best-effort.
	migratepak(user, pass);
	return nil;
}

#
# Opportunistically upgrade the local secstore PAK verifier to secstore3 after a
# verified login. The verifier is a one-way function of (user, password), so a
# successful login is proof we can recompute it under the stronger suite; the
# factotum blob and 2fa key-slots are keyed independently and are untouched.
#
# Best-effort: this must NEVER disturb the login that already succeeded, so any
# error just logs and returns. Idempotent (skips if already secstore3), and it
# stages to a temp file it reads back and validates before swapping, so a bad or
# short write can never destroy the working verifier.
#
migratepak(user, pass: string)
{
	if(secstore == nil || user == nil || user == "")
		return;
	pakpath := "/usr/inferno/secstore/" + user + "/PAK";

	rfd := sys->open(pakpath, Sys->OREAD);
	if(rfd == nil)
		return;			# no local PAK (e.g. remote store) — nothing to do
	buf := array[4096] of byte;
	n := sys->read(rfd, buf, len buf);
	rfd = nil;
	if(n <= 0)
		return;
	(curver, nil) := secstore->parseverifier(string buf[0:n]);
	if(curver == "secstore3")
		return;			# already migrated

	pwhash2 := secstore->mkseckey2(pass);
	hexHi := secstore->mkverifier(user, "secstore3", pwhash2);
	secstore->erasekey(pwhash2);
	content := array of byte (secstore->formatverifier("secstore3", hexHi) + "\n");

	tmppath := pakpath + ".new";
	wfd := sys->create(tmppath, Sys->OWRITE, 8r600);
	if(wfd == nil){
		sys->fprint(stderr, "logon: PAK migrate: create %s: %r\n", tmppath);
		return;
	}
	if(sys->write(wfd, content, len content) != len content){
		sys->fprint(stderr, "logon: PAK migrate: write %s: %r\n", tmppath);
		wfd = nil;
		sys->remove(tmppath);
		return;
	}
	wfd = nil;

	# Validate the staged file parses as secstore3 before committing.
	vfd := sys->open(tmppath, Sys->OREAD);
	if(vfd == nil){
		sys->remove(tmppath);
		return;
	}
	vn := sys->read(vfd, buf, len buf);
	vfd = nil;
	(nver, nil) := secstore->parseverifier(string buf[0:vn]);
	if(nver != "secstore3"){
		sys->fprint(stderr, "logon: PAK migrate: staged verifier failed validation; leaving legacy PAK in place\n");
		sys->remove(tmppath);
		return;
	}

	# Commit: replace PAK with the validated staged file.
	if(sys->remove(pakpath) < 0){
		sys->fprint(stderr, "logon: PAK migrate: cannot remove old PAK: %r\n");
		sys->remove(tmppath);
		return;
	}
	d := sys->nulldir;
	d.name = "PAK";
	if(sys->wstat(tmppath, d) < 0){
		sys->fprint(stderr, "logon: PAK migrate: rename failed: %r — recover with 'secstore-setup -u %s -V secstore3' (the .new file holds the new verifier)\n", user);
		return;
	}
	sys->fprint(stderr, "logon: upgraded secstore PAK verifier to secstore3 for %s\n", user);
}

createsecstoreacct(pass: string): string
{
	if(secstore == nil)
		return "secstore module not loaded";
	secstore->init();

	user := rf("/dev/user");
	if(user == nil)
		user = "inferno";

	storedir := "/usr/inferno/secstore";
	userdir := storedir + "/" + user;

	sys->create(storedir, Sys->OREAD, Sys->DMDIR | 8r700);
	fd := sys->create(userdir, Sys->OREAD, Sys->DMDIR | 8r700);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", userdir);
	fd = nil;

	pwhash2 := secstore->mkseckey2(pass);
	hexHi := secstore->mkverifier(user, "secstore3", pwhash2);

	pakpath := userdir + "/PAK";
	fd = sys->create(pakpath, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't create %s: %r", pakpath);
	b := array of byte secstore->formatverifier("secstore3", hexHi);
	sys->write(fd, b, len b);
	fd = nil;

	sys->fprint(stderr, "logon: secstore account created for %s\n", user);
	return nil;
}

#
# Tell running factotum to use secstore for persistence.
# This enables the save-back path so new keys are persisted.
#
tohex(a: array of byte): string
{
	h := "0123456789abcdef";
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = h[(int a[i] >> 4) & 16rf];
		s[len s] = h[int a[i] & 16rf];
	}
	return s;
}

enablesecstoresave(pass: string)
{
	user := rf("/dev/user");
	if(user == nil)
		user = "inferno";

	# For a 2FA account, hand factotum the data key so its save-back stays
	# DK-encrypted (auth still uses the password). Ordinary accounts pass no
	# DK and factotum encrypts under the password-derived root key as before.
	cmd := "secstore tcp!127.0.0.1!5356 " + user + " " + pass;
	if(current2fadkhex != "")
		cmd += " " + current2fadkhex;
	fd := sys->open("/mnt/factotum/ctl", Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte cmd;
	sys->write(fd, b, len b);
	if(current2fadkhex != "")
		sys->fprint(stderr, "logon: secstore save-back enabled (DK-encrypted)\n");
	else
		sys->fprint(stderr, "logon: secstore save-back enabled\n");
}

# Check if factotum already has keys (e.g. loaded via -S -P in profile)
factotumhaskeys(): int
{
	fd := sys->open("/mnt/factotum/ctl", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	return n > 0;
}

secstoreacctexists(): int
{
	user := rf("/dev/user");
	if(user == nil)
		user = "inferno";
	(ok, nil) := sys->stat("/usr/inferno/secstore/" + user + "/PAK");
	return ok >= 0;
}

headlessprompt()
{
	# Fallback for headless: use factotum's built-in console prompt
	sys->fprint(stderr, "logon: no display, using console\n");
	# Nothing to do — factotum -S will prompt on its own if needed,
	# or the user can manually run:
	#   auth/factotum -S tcp!localhost!5356
}

loadpng(path: string): ref Image
{
	if(bufio == nil || display_g == nil)
		return nil;
	readpng := load RImagefile RImagefile->READPNGPATH;
	remap := load Imageremap Imageremap->PATH;
	if(readpng == nil || remap == nil)
		return nil;
	readpng->init(bufio);
	remap->init(display_g);
	fd := bufio->open(path, Bufio->OREAD);
	if(fd == nil)
		return nil;
	(raw, nil) := readpng->read(fd);
	if(raw == nil)
		return nil;
	(img, nil) := remap->remap(raw, display_g, 0);
	return img;
}

# Product name, from /lib/lucifer/brand/name (default "InferNode").
brandname(): string
{
	n := rf("/lib/lucifer/brand/name");
	if(n == nil)
		return "InferNode";
	return n;
}

# Footer copyright, from /lib/lucifer/brand/copyright (built-in default below).
brandcopyright(): string
{
	c := rf("/lib/lucifer/brand/copyright");
	if(c == nil)
		return "© 2026 InferNode.io";
	return c;
}

rf(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	while(n > 0 && (buf[n-1] == byte '\n' || buf[n-1] == byte ' '))
		n--;
	if(n == 0)
		return nil;
	return string buf[0:n];
}
