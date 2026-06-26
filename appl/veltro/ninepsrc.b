implement Ninepsrc;

#
# ninepsrc - generic event-only MsgSrc bridging ANY 9P "events" file
#            into the /mnt/msg agent mailbox.
#
# This is the GENERIC, upstreamable source (lives in veltro alongside msg9p,
# not a one-off adapter). It bridges any 9P service that exposes a blocking
# "events" file (the standard Inferno park-and-wake event-file pattern) into
# the protocol-agnostic /mnt/msg mailbox. New services feed the
# agent by REGISTRATION/CONFIG ALONE — no per-service code:
#
#   echo 'register <name> /dis/veltro/ninepsrc.dis mount=tcp!host!port file=events name=<name>' > /mnt/msg/ctl
#
# It implements the MsgSrc interface (module/msgsrc.m) so msg9p loads it
# identically to every other source: load MsgSrc dispath; init(config);
# watch(updates, stop). Being event-only it declares CAP_WATCH only; the
# pull/send/reply/flag methods are safe no-ops.
#
# The inbound mapping is intentionally GENERIC: each newline-delimited line
# of the events file becomes one Message whose body is the raw line. The
# agent triages on body keywords downstream — this source does NOT parse any
# service-specific line grammar.
#
# Config schema (key=value tokens, whitespace-separated):
#   mount=    9P dial string to mount, e.g. tcp!127.0.0.1!6610 (required unless
#             the service is already mounted and you pass mounted=1)
#   mountpt=  where to mount it (default /n/<name>)
#   file=     path of the blocking events file under the mount (default "events")
#   name=     source name reported to msg9p / the agent (default "ninep")
#   urgent=   "1" to set FURGENT on every emitted message (default off)
#   mounted=  "1" if <mountpt> is already mounted by someone else; skip mount
#             and just open <mountpt>/<file> (default off — we mount it)
#   tsfield=  "unixnanos" or "unixsecs": derive the message timestamp from a
#             leading numeric token on each line instead of "now". Any other
#             value (or unset) uses the current time. (default unset)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "daytime.m";
	daytime: Daytime;

include "msgsrc.m";

Ninepsrc: module {
	init:    fn(config: string): string;
	name:    fn(): string;
	capabilities: fn(): int;
	status:  fn(): string;
	close:   fn(): string;
	watch:   fn(updates: chan of ref MsgSrc->Notification, stop: chan of int): string;
	enumerate: fn(channel: string, count: int): (list of ref MsgSrc->Message, string);
	fetch:   fn(id: string): (ref MsgSrc->Message, string);
	search:  fn(query: string): (list of ref MsgSrc->Message, string);
	send:    fn(msg: ref MsgSrc->Message): string;
	reply:   fn(origid, body: string): string;
	setflag: fn(id: string, flag, add: int): string;
};

Message: import MsgSrc;
Notification: import MsgSrc;

# Configuration (parsed in init from the register config string).
srcname  := "ninep";
mountdial: string;	# 9P dial string (mount=)
mountpt:   string;	# mount point (mountpt=)
evfile    := "events";	# events file under the mount (file=)
urgent    := 0;		# set FURGENT on each message (urgent=1)
mounted   := 0;		# service already mounted; skip our mount (mounted=1)
tsfield:   string;	# unixnanos|unixsecs|"" — timestamp derivation

mountdone := 0;		# whether we have mounted (so close can clean up)
seq := 0;		# running counter for per-line unique ids

stderr: ref Sys->FD;

init(config: string): string
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		return "ninepsrc: cannot load String";

	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return "ninepsrc: cannot load Daytime";

	# Parse key=value config.
	if((v := getcfg(config, "name")) != nil)
		srcname = v;
	mountdial = getcfg(config, "mount");
	mountpt = getcfg(config, "mountpt");
	if(mountpt == nil)
		mountpt = "/n/" + srcname;
	if((v = getcfg(config, "file")) != nil)
		evfile = v;
	if(getcfg(config, "urgent") == "1")
		urgent = 1;
	if(getcfg(config, "mounted") == "1")
		mounted = 1;
	tsfield = getcfg(config, "tsfield");

	if(!mounted && mountdial == nil)
		return "ninepsrc: config: mount= required (or mounted=1 if pre-mounted)";

	return nil;
}

name(): string   { return srcname; }

# Event-only source: it pushes notifications (watch) and nothing else. It does
# not list history, fetch bodies, originate, reply, or track flags — so it
# declares CAP_WATCH only. msg9p / agents check the bit rather than calling a
# method that returns "not supported".
capabilities(): int { return MsgSrc->CAP_WATCH; }

status(): string {
	src := mountdial;
	if(mounted)
		src = "(pre-mounted)";
	return sys->sprint("%s: 9P events %s/%s via %s", srcname, mountpt, evfile, src);
}

close(): string  { return nil; }

# Mount the configured 9P service (no-auth) if we own the mount. Mirrors the
# `mount -A net!addr mountpt` path: dial, then sys->mount the dialled fd with
# no authentication (the target is an anon/localhost service). Idempotent.
domount(): string
{
	if(mounted || mountdone)
		return nil;

	dest := netmkaddr(mountdial, "net", "styx");
	(ok, c) := sys->dial(dest, nil);
	if(ok < 0)
		return sys->sprint("ninepsrc: cannot dial %s: %r", dest);

	ensuredir(mountpt);
	if(sys->mount(c.dfd, nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0)
		return sys->sprint("ninepsrc: mount %s at %s: %r", dest, mountpt);

	mountdone = 1;
	return nil;
}

# Push interface. Mount the service, open <mountpt>/<file> ONCE (long-lived fd:
# the events file is park-and-wake — a single blocking read returns the next
# event batch; we do NOT open/close per event), then loop: read -> split into
# lines -> emit one generic Message per line. Select on `stop` to terminate.
# On a read error/EOF, attempt one reopen; if that also fails, surface a
# kind="error" Notification (matching takmsg's behaviour) and keep retrying.
watch(updates: chan of ref Notification, stop: chan of int): string
{
	if((e := domount()) != nil) {
		sys->fprint(stderr, "%s\n", e);
		updates <-= ref Notification("error", nil, e);
		# fall through and keep trying to mount/open in the loop
	}

	evpath := mountpt + "/" + evfile;
	sys->fprint(stderr, "ninepsrc: watch start; reading %s (name=%s urgent=%d)\n",
		evpath, srcname, urgent);

	buf := array[16384] of byte;
	fd: ref Sys->FD;
	reopened := 0;

	for(;;) {
		# Check for stop without blocking the read path.
		alt {
		<-stop =>
			return nil;
		* =>
			;
		}

		if(mountdone == 0 && mounted == 0) {
			if(domount() != nil) {
				sys->sleep(500);
				continue;
			}
		}

		if(fd == nil) {
			fd = sys->open(evpath, Sys->OREAD);
			if(fd == nil) {
				sys->fprint(stderr, "ninepsrc: cannot open %s: %r\n", evpath);
				sys->sleep(500);
				continue;
			}
		}

		n := sys->read(fd, buf, len buf);	# blocks until next event(s)
		if(n <= 0) {
			fd = nil;	# reopen next iteration
			if(reopened) {
				# Two consecutive failures — surface an error and back off.
				updates <-= ref Notification("error", nil,
					sys->sprint("%s: read %s failed", srcname, evpath));
				reopened = 0;
				sys->sleep(1000);
			} else {
				reopened = 1;
				sys->sleep(200);
			}
			continue;
		}
		reopened = 0;

		# Split the batch into lines; emit one Message per non-empty line.
		(nil, lines) := sys->tokenize(string buf[0:n], "\n");
		for(; lines != nil; lines = tl lines) {
			line := strip(hd lines);
			if(line == "")
				continue;
			updates <-= ref Notification("new", mkmsg(line), "");
		}
	}
}

# Generic line -> Message mapping. The body is the RAW line. The subject is a
# short generic summary (the line truncated). The id is a per-line unique
# running counter prefixed with the source name. The timestamp is RFC 3339
# now, unless tsfield is configured and a leading numeric token is present.
mkmsg(line: string): ref Message
{
	flags := MsgSrc->FUNREAD;
	if(urgent)
		flags |= MsgSrc->FURGENT;

	ts := derivetime(line);

	subj := line;
	if(len subj > 80)
		subj = subj[:80] + "...";

	id := sys->sprint("%s-%d", srcname, seq++);

	return ref Message(
		id,		# id (per-line unique)
		srcname,	# source
		srcname,	# channel
		srcname,	# sender (the service)
		"",		# recipient
		subj,		# subject (generic summary)
		line,		# body (raw line)
		ts,		# timestamp (RFC 3339)
		"",		# threadid
		"",		# replyto
		flags,		# flags
		"");		# headers
}

# Derive an RFC 3339 timestamp. If tsfield requests it and the line begins with
# a numeric token, interpret it as unix seconds/nanoseconds. Otherwise use now.
derivetime(line: string): string
{
	if(tsfield == "unixnanos" || tsfield == "unixsecs") {
		(tok, nil) := splitword(strip(line));
		secs := parseunixsecs(tok, tsfield);
		if(secs > 0)
			return isotime(secs);
	}
	return isotime(daytime->now());
}

# Parse a leading numeric token into unix seconds. For unixnanos, divide by 1e9.
# Returns 0 if the token is not a plausible numeric timestamp.
parseunixsecs(tok, mode: string): int
{
	if(tok == "")
		return 0;
	for(i := 0; i < len tok; i++)
		if(tok[i] < '0' || tok[i] > '9')
			return 0;
	# big to tolerate nanosecond magnitudes.
	v := big tok;
	if(mode == "unixnanos")
		v /= big 1000000000;
	return int v;
}

# --- pull/send/reply/flag: event-only source, safe no-ops ---
enumerate(nil: string, nil: int): (list of ref Message, string) { return (nil, nil); }
fetch(nil: string): (ref Message, string) { return (nil, "ninepsrc: fetch not supported"); }
search(nil: string): (list of ref Message, string) { return (nil, nil); }
send(nil: ref Message): string { return "ninepsrc: send not supported (event-only)"; }
reply(nil, nil: string): string { return "ninepsrc: reply not supported (event-only)"; }
setflag(nil: string, nil, nil: int): string { return nil; }

# --- helpers ---

isotime(unixsecs: int): string
{
	tm := daytime->gmt(unixsecs);
	return sys->sprint("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
		tm.year + 1900, tm.mon + 1, tm.mday, tm.hour, tm.min, tm.sec);
}

# getcfg: extract the value of key= from a whitespace-separated config string.
# Same shape as the email source's parser.
getcfg(config, key: string): string
{
	target := key + "=";
	tlen := len target;
	i := 0;
	for(;;) {
		while(i < len config && (config[i] == ' ' || config[i] == '\t'))
			i++;
		if(i >= len config)
			return nil;
		if(i + tlen <= len config && config[i:i+tlen] == target) {
			start := i + tlen;
			end := start;
			while(end < len config && config[end] != ' ' && config[end] != '\t')
				end++;
			return config[start:end];
		}
		while(i < len config && config[i] != ' ' && config[i] != '\t')
			i++;
	}
}

netmkaddr(addr, net, svc: string): string
{
	if(net == nil)
		net = "net";
	(n, nil) := sys->tokenize(addr, "!");
	if(n <= 1){
		if(svc == nil)
			return sys->sprint("%s!%s", net, addr);
		return sys->sprint("%s!%s!%s", net, addr, svc);
	}
	if(svc == nil || n > 2)
		return addr;
	return sys->sprint("%s!%s", addr, svc);
}

ensuredir(path: string)
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r777);
	if(fd != nil)
		fd = nil;
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

splitword(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			return (s[0:i], s[i+1:]);
	return (s, "");
}
