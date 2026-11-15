implement ToolLaunch;

#
# launch - Launch a GUI app in the presentation zone
#
# Launches a /dis/wm/* program in lucifer's presentation zone.
# Accepts short name, wm/ prefix, or full path — all equivalent:
#   Launch clock
#   Launch wm/clock
#   Launch /dis/wm/clock.dis
#
# Usage:
#   Launch list         — list available apps
#   Launch <appname>    — launch app in presentation zone
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "publicnet.m";
	publicnet: Publicnet;

include "../tool.m";

Maxurl: con 2048;	# of a URL given to the browser

ToolLaunch: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

UI_MOUNT: con "/mnt/ui";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	# without it no URL is given to the browser (below)
	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet != nil)
		publicnet->init();
	return nil;
}

name(): string
{
	return "launch";
}

doc(): string
{
	return "Launch - Launch a GUI app in the presentation zone\n\n" +
		"Usage:\n" +
		"  Launch list                    — show available apps\n" +
		"  Launch xenith                  — launch Xenith text environment\n" +
		"  Launch shell                   — launch shell terminal\n" +
		"  Launch editor                  — launch text editor\n" +
		"  Launch clock                   — launch by short name\n" +
		"  Launch wm/clock                — launch with wm/ prefix\n" +
		"  Launch /dis/wm/clock           — launch by full path (.dis optional)\n" +
		"  Launch charon <url>            — launch Charon browser at the given URL\n" +
		"                                   (http:// or https:// only)\n\n" +
		"Navigating Charon:\n" +
		"  Launch charon http://example.com  — opens Charon at example.com\n" +
		"  If Charon is already running, it is killed and relaunched at the new URL.\n" +
		"  Right-click inside Charon for back/fwd/stop/start menu.\n" +
		"  Do NOT use exec or shell commands to control Charon.\n\n" +
		"Confirmed working (draw-based, /dis/wm/):\n" +
		"  charon, clock, bounce, coffee, colors, date, editor (edit), about, view, rt, lens, shell, fractals, keyring\n\n" +
		"Also available (full environments, /dis/):\n" +
		"  xenith                — Xenith text environment (Acme-like)\n\n" +
		"Not available (require Tk, which is not built in):\n" +
		"  task, tetris, sh, ftree, deb\n\n" +
		"Returns 'launched <name> in presentation zone' on success, and an\n" +
		"error saying why when the presentation zone refuses.";
}

schema(): string
{
	return "{" +
		"\"name\":\"launch\"," +
		"\"description\":\"Launch a GUI app in the Lucifer presentation zone. Pass 'list' to see available apps. For charon, pass a URL as the extra argument.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"app\":{\"type\":\"string\",\"description\":\"App name (e.g. xenith, shell, editor, charon, clock), wm-prefixed path (wm/clock), or full path (/dis/wm/clock).\"}," +
				"\"extra\":{\"type\":\"string\",\"description\":\"Optional extra data; for charon this is the initial URL.\"}" +
			"}," +
			"\"required\":[\"app\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	# Strip leading/trailing whitespace
	while(len args > 0 && (args[0] == ' ' || args[0] == '\t'))
		args = args[1:];
	while(len args > 0 && (args[len args - 1] == ' ' || args[len args - 1] == '\t' || args[len args - 1] == '\n'))
		args = args[0:len args - 1];

	if(args == "" || args == "list")
		return listapps();

	# Take first word as app argument; capture the rest for optional data
	apparg := args;
	for(i := 0; i < len apparg; i++) {
		if(apparg[i] == ' ' || apparg[i] == '\t') {
			apparg = apparg[0:i];
			break;
		}
	}

	# Everything after the first word is extra data (e.g. a URL for charon)
	extradata := "";
	if(len apparg < len args) {
		rest := args[len apparg:];
		while(len rest > 0 && (rest[0] == ' ' || rest[0] == '\t'))
			rest = rest[1:];
		while(len rest > 0 && (rest[len rest-1] == ' ' || rest[len rest-1] == '\t' || rest[len rest-1] == '\n'))
			rest = rest[0:len rest-1];
		extradata = rest;
	}

	# Normalize to bare app name:
	#   /dis/wm/clock.dis  →  clock
	#   /dis/wm/clock      →  clock
	#   wm/clock           →  clock
	#   clock              →  clock
	appname := apparg;
	if(len appname > 8 && appname[0:8] == "/dis/wm/")
		appname = appname[8:];
	else if(len appname > 3 && appname[0:3] == "wm/")
		appname = appname[3:];
	# Strip any remaining path separators
	for(j := len appname - 1; j >= 0; j--) {
		if(appname[j] == '/') {
			appname = appname[j+1:];
			break;
		}
	}
	# Strip .dis suffix
	if(len appname > 4 && appname[len appname - 4:] == ".dis")
		appname = appname[0:len appname - 4];

	if(appname == "")
		return "error: usage: Launch <appname> or Launch list";

	# Reject Tk-dependent apps (Tk is not built into this emu)
	if(istk(appname))
		return "error: " + appname + " requires Tk which is not available.\n" +
			"Try: clock, bounce, coffee, colors, date, view, rt, lens, xenith";

	# User-facing label preserved before .dis resolution aliases.
	label := appname;

	# disname is the .dis filename — normally same as appname.
	disname := appname;
	# (xenith was let by with data it is never given, and the answer
	# said it was launched "with url" what followed its name)
	if(extradata != "" && disname != "charon")
		return "error: launch data is only supported for charon";
	if(disname == "charon" && extradata != "" && !isallowedurl(extradata))
		return "error: charon only accepts http:// and https:// URLs";
	# The browser opens the address with the user's network, not the
	# agent's: one naming this machine or a private network is refused
	# here, by the rule the fetch tools use for a URL's host as written
	# (what a public name resolves to is the browser's own to check).
	if(disname == "charon" && extradata != "") {
		if(len extradata > Maxurl)
			return sys->sprint("error: a URL of more than %d characters is not opened", Maxurl);
		if(publicnet == nil)
			return "error: cannot check the URL's host (publicnet did not load); nothing was opened";
		if(publicnet->hostblocked(publicnet->urlhost(extradata)))
			return "error: charon is not opened at a local or private address";
	}

	# An app's name is letters, digits, - and _, as the presentation zone
	# takes an id: anything else is refused there, after this tool had
	# looked for the file under a name cut short at the odd character.
	for(pi := 0; pi < len disname; pi++) {
		c := disname[pi];
		if(!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		     (c >= '0' && c <= '9') || c == '-' || c == '_'))
			return "error: an app's name is letters, digits, - and _ (Launch list shows the apps)";
	}

	# Resolve the .dis path.
	# /dis/wm/ is the primary pool of launchable WM apps.
	# Apps outside /dis/wm/ must be explicitly whitelisted here; no generic
	# directory search is performed to prevent an agent from reaching
	# arbitrary /dis/*.dis files by guessing names.
	dispath := "/dis/wm/" + disname + ".dis";
	(ok, nil) := sys->stat(dispath);
	if(ok < 0) {
		# Check explicit whitelist for apps that live outside /dis/wm/.
		dispath = extraapp(disname);
		if(dispath == "")
			return "error: " + label + " not found\n" +
				"Use 'Launch list' to see available apps";
	}

	# Register app with luciuisrv via presentation/ctl
	actid := currentactid();
	if(actid < 0)
		return "error: cannot reach presentation zone (is luciuisrv running?)";

	pctl := sys->sprint("%s/activity/%d/presentation/ctl", UI_MOUNT, actid);

	# Build the create command.
	# For xenith: pass -c 1 (single-column, fits presentation zone) and -E (embedded flag
	# so xenith skips killprocs on exit).
	# For other apps with extradata (e.g. a URL for charon): kill any existing instance
	# first, then relaunch with data=<extradata> so the app receives the URL as its starturl.
	# id must match the app's wmsrv registration (derived from .dis name).
	# label is the user-facing tab name.
	cmd: string;
	killed := 0;	# an instance that was running was closed first
	if(disname == "xenith") {
		# no -t: Xenith follows the system theme itself
		xenithargs := "-c 1 -E";
		cmd = sys->sprint("create id=%s type=app dis=%s label=%s data=%s",
			disname, dispath, label, xenithargs);
	} else if(extradata != "") {
		# Navigation: kill any running instance, then relaunch with the new URL/data.
		killfd := sys->open(pctl, Sys->OWRITE);
		if(killfd != nil) {
			kb := array of byte ("kill id=" + disname);
			killed = sys->write(killfd, kb, len kb) == len kb;
			killfd = nil;
		}
		cmd = sys->sprint("create id=%s type=app dis=%s label=%s data=%s",
			disname, dispath, label, extradata);
	} else
		cmd = sys->sprint("create id=%s type=app dis=%s label=%s", disname, dispath, label);
	fd := sys->open(pctl, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("error: cannot open presentation/ctl: %r");
	# What the presentation zone answers is the result.  It was not
	# looked at: a launch it refused (an app already open, too many
	# open, a name it does not take) was reported as launched.
	b := array of byte cmd;
	if(sys->write(fd, b, len b) != len b) {
		why := sys->sprint("%r");
		if(!killed && contains(why, "already exists")) {
			fd = sys->open(pctl, Sys->OWRITE);
			if(fd != nil) {
				b = array of byte ("center id=" + disname);
				sys->write(fd, b, len b);
			}
			return label + " is already open in the presentation zone: shown again, not launched a second time";
		}
		if(killed)
			return "error: " + label + " was closed, and could not be opened again: " + why;
		return "error: " + label + " was not launched: " + why;
	}
	fd = nil;

	# Center the new app tab
	fd = sys->open(pctl, Sys->OWRITE);
	if(fd != nil) {
		b = array of byte ("center id=" + disname);
		sys->write(fd, b, len b);
		fd = nil;
	}

	if(extradata != "")
		return "launched " + label + " with url " + extradata + " in presentation zone";
	return "launched " + label + " in presentation zone";
}

isallowedurl(url: string): int
{
	url = tolower(url);
	for(i := 0; i < len url; i++) {
		c := url[i];
		if(c <= ' ' || c == 16r7F)
			return 0;
	}
	return hasprefix(url, "http://") || hasprefix(url, "https://");
}

tolower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

# Read this tool's own activity ID from tools9p.
# /tool/activity is served by the tools9p instance this tool belongs to.
# Falls back to /mnt/ui/activity/current for backward compatibility.
currentactid(): int
{
	s := readfile("/tool/activity");
	if(s == nil)
		s = readfile(UI_MOUNT + "/activity/current");
	if(s == nil)
		return -1;
	s = strip(s);
	(n, nil) := str->toint(s, 10);
	return n;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
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

# List available (non-Tk) apps from /dis/wm/ plus known top-level apps.
listapps(): string
{
	fd := sys->open("/dis/wm", Sys->OREAD);
	if(fd == nil)
		return "error: cannot open /dis/wm";

	apps := "";
	count := 0;
	for(;;) {
		(n, dir) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			nm := dir[i].name;
			if(len nm <= 4 || nm[len nm - 4:] != ".dis")
				continue;
			nm = nm[0:len nm - 4];
			if(istk(nm))
				continue;
			if(count > 0)
				apps += "\n";
			apps += "  " + nm;
			count++;
		}
	}

	# Also list whitelisted apps that live outside /dis/wm/.
	# This mirrors extraapp() — both must stay in sync.
	# Note: charon is now in /dis/wm/charon.dis and appears in the main listing above.
	extra := array[] of {
		("xenith", "/dis/xenith/xenith.dis"),
	};
	for(i := 0; i < len extra; i++) {
		(nm, path) := extra[i];
		(ok, nil) := sys->stat(path);
		if(ok < 0)
			continue;
		if(count > 0)
			apps += "\n";
		apps += "  " + nm;
		count++;
	}

	if(count == 0)
		return "no apps available";
	return sys->sprint("%d apps available:\n%s", count, apps);
}

# Explicit whitelist of apps that live outside /dis/wm/.
# Returns the full .dis path for known safe apps, or "" if not listed.
# Add entries here only after confirming the app implements GuiApp and is safe
# to run in lucifer's presentation zone.
extraapp(name: string): string
{
	# Each entry: (short-name, absolute-dis-path)
	# To add a new app: add a row here, review the .dis for GuiApp interface.
	# Note: paths must be under a /dis/ subdirectory (not top-level /dis/*.dis)
	# so they are visible in the tool's restricted namespace when that
	# subdirectory is listed in caps.paths (e.g. "/dis/xenith" → /dis/xenith/).
	# Also update lucifer.b ALLOWED_PREFIXES and listapps() extra array.
	# charon is now /dis/wm/charon.dis — found automatically, not needed here.
	apps := array[] of {
		("xenith", "/dis/xenith/xenith.dis"),
	};
	for(i := 0; i < len apps; i++) {
		(nm, path) := apps[i];
		if(nm == name) {
			(ok, nil) := sys->stat(path);
			if(ok >= 0)
				return path;
			return "";	# whitelisted but not installed
		}
	}
	return "";
}

# Returns 1 if the app requires Tk (not available in this build)
istk(name: string): int
{
	tkapps := array[] of {
		"task", "tetris", "sh", "ftree", "deb",
	};
	for(i := 0; i < len tkapps; i++) {
		if(name == tkapps[i])
			return 1;
	}
	return 0;
}
