implement AlertWatcher;

#
# alert-watcher - Matrix service module for TBL4 alerts
#
# Monitors <mount>/signals for high-confidence signals and
# <mount>/portfolio/defense/status for status changes.
# Writes alert files to its output directory: one per signal id that
# qualifies, once, and one per status change.  Numbering carries on
# from the alert files already there, so a restart neither overwrites
# nor reorders them.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "readdir.m";

include "matrix.m";

AlertWatcher: module
{
	init:	fn(mount: string, outdir: string): string;
	run:	fn();
	shutdown:	fn();
};

mountpath: string;
outdir_g: string;
running: int;
alertseq: int;
lastdefense: string;
alerted: list of string;	# ids of the qualifying signals already alerted

POLL_MS: con 5000;
CONFIDENCE_THRESHOLD: con 0.7;

init(mount: string, outdir: string): string
{
	sys = load Sys Sys->PATH;

	mountpath = mount;
	outdir_g = outdir;
	running = 1;
	alertseq = nextseq(outdir);
	lastdefense = "";
	alerted = nil;
	return nil;
}

# One past the highest alert-NNNN in the outdir.
nextseq(dir: string): int
{
	rd := load Readdir Readdir->PATH;
	if(rd == nil)
		return 0;
	(ents, n) := rd->init(dir, Readdir->NAME);
	next := 0;
	for(i := 0; i < n; i++) {
		nm := ents[i].name;
		if(len nm <= 6 || nm[0:6] != "alert-")
			continue;
		v := int nm[6:];
		if(v + 1 > next)
			next = v + 1;
	}
	return next;
}

run()
{
	while(running) {
		checksignals();
		checkdefense();
		sys->sleep(POLL_MS);
	}
}

shutdown()
{
	running = 0;
}

# Parse Plan 9 text: one signal per line
# Format: id asset direction confidence signal_type timestamp
checksignals()
{
	fd := sys->open(mountpath + "/signals", Sys->OREAD);
	if(fd == nil)
		return;
	content := "";
	buf := array[32768] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		content += string buf[0:n];
	}
	fd = nil;
	if(content == "")
		return;

	# Process line by line.  A signal is alerted once, when it first
	# qualifies; the ids still qualifying are kept for the next poll
	# (and only those, so the list follows the file, not its history).
	seen: list of string;
	start := 0;
	for(i := 0; i <= len content; i++) {
		if(i == len content || content[i] == '\n') {
			if(i > start) {
				line := content[start:i];
				(ntoks, toks) := sys->tokenize(line, " \t");
				if(ntoks >= 6) {
					id := hd toks; toks = tl toks;
					asset := hd toks; toks = tl toks;
					dir := hd toks; toks = tl toks;
					conf := hd toks; toks = tl toks;
					stype := hd toks;
					if(real conf >= CONFIDENCE_THRESHOLD && !member(id, seen)) {
						seen = id :: seen;
						if(!member(id, alerted)) {
							msg := sys->sprint(
								"high-confidence signal: %s %s %s (conf=%s)",
								asset, dir, stype, conf);
							writealert(msg);
						}
					}
				}
			}
			start = i + 1;
		}
	}
	alerted = seen;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

checkdefense()
{
	fd := sys->open(mountpath + "/portfolio/defense/status", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return;
	status := trim(string buf[0:n]);
	if(lastdefense != "" && status != lastdefense) {
		msg := sys->sprint("defense status changed: %s -> %s", lastdefense, status);
		writealert(msg);
	}
	lastdefense = status;
}

writealert(msg: string)
{
	path := sys->sprint("%s/alert-%04d", outdir_g, alertseq);
	afd := sys->create(path, Sys->OWRITE, 8r644);
	if(afd != nil) {
		data := array of byte msg;
		sys->write(afd, data, len data);
		afd = nil;
	}
	alertseq++;
}

trim(s: string): string
{
	end := len s;
	while(end > 0 && (s[end-1] == '\n' || s[end-1] == ' '))
		end--;
	return s[0:end];
}
