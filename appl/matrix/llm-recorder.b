implement LlmRecorder;

#
# llm-recorder - Matrix service module recording per-session LLM stats.
#
# Polls the llmsrv 9P tree at `mount` (typically /mnt/llm), enumerating
# numeric session directories.  For each session it reads `usage`
# ("estimated/limit\n") and `model`, keeping an in-memory ring of the
# last RING_N samples.  Each tick it rewrites flat files under
# `outdir` for display modules to consume:
#
#     outdir/sessions          one session id per line
#     outdir/<id>/current      "<ms> <model> <tokens> <limit>\n"
#     outdir/<id>/history      "<ms> <tokens> <limit>\n" per sample
#
# This is a write-only side; display modules just read the files.
# A session disappears from /sessions on the first poll where it is
# no longer visible in the source tree; stale per-session directories
# under outdir are left in place.
#

include "sys.m";
	sys: Sys;
	Dir: import sys;

include "draw.m";

include "matrix.m";

LlmRecorder: module
{
	init:	fn(mount: string, outdir: string): string;
	run:	fn();
	shutdown:	fn();
};

POLL_MS: con 1000;
RING_N:  con 60;

Sample: adt {
	ms:     int;
	tokens: int;
	limit:  int;
};

SessRing: adt {
	id:      int;
	model:   string;
	samples: list of Sample;  # newest first
	count:   int;
};

mountpath: string;
outdirpath: string;
running: int;
rings: list of ref SessRing;

init(mount: string, outdir: string): string
{
	sys = load Sys Sys->PATH;

	mountpath = mount;
	outdirpath = outdir;
	running = 1;
	rings = nil;
	return nil;
}

run()
{
	while(running) {
		ids := pollsessions();
		writesessionsfile(ids);
		for(il := ids; il != nil; il = tl il) {
			id := hd il;
			r := getring(id);
			(tokens, limit, model) := readsession(id);
			if(limit <= 0)
				continue;
			r.model = model;
			append(r, Sample(sys->millisec(), tokens, limit));
			writesession(r);
		}
		sys->sleep(POLL_MS);
	}
}

shutdown()
{
	running = 0;
}

# ── Source-side reads ────────────────────────────────────────

# Return list of numeric session ids visible under mountpath.
pollsessions(): list of int
{
	fd := sys->open(mountpath, Sys->OREAD);
	if(fd == nil)
		return nil;
	ids: list of int;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := d[i].name;
			if(!isnumeric(name))
				continue;
			ids = int name :: ids;
		}
	}
	return ids;
}

# Read /<mount>/<id>/usage and /model.  Returns (tokens, limit, model).
# Returns (0, 0, "") if usage is unreadable or malformed.
readsession(id: int): (int, int, string)
{
	base := sys->sprint("%s/%d", mountpath, id);
	usage := trim(readf(base + "/usage"));
	if(usage == nil)
		return (0, 0, "");
	slash := -1;
	for(i := 0; i < len usage; i++)
		if(usage[i] == '/') { slash = i; break; }
	if(slash < 0)
		return (0, 0, "");
	tokens := int usage[0:slash];
	limit := int usage[slash+1:];
	model := trim(readf(base + "/model"));
	if(model == nil)
		model = "?";
	return (tokens, limit, model);
}

# ── Ring management ──────────────────────────────────────────

getring(id: int): ref SessRing
{
	for(rl := rings; rl != nil; rl = tl rl) {
		r := hd rl;
		if(r.id == id)
			return r;
	}
	r := ref SessRing(id, "", nil, 0);
	rings = r :: rings;
	return r;
}

append(r: ref SessRing, s: Sample)
{
	r.samples = s :: r.samples;
	r.count++;
	if(r.count > RING_N)
		r.samples = trimring(r.samples, RING_N);
	if(r.count > RING_N)
		r.count = RING_N;
}

trimring(l: list of Sample, n: int): list of Sample
{
	# Keep first n; drop the rest.
	if(n <= 0)
		return nil;
	out: list of Sample;
	i := 0;
	for(; l != nil && i < n; l = tl l) {
		out = hd l :: out;
		i++;
	}
	# Reverse back to newest-first.
	rev: list of Sample;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return rev;
}

# ── Output-side writes ───────────────────────────────────────

writesessionsfile(ids: list of int)
{
	ensuredir(outdirpath);
	text := "";
	for(; ids != nil; ids = tl ids)
		text += sys->sprint("%d\n", hd ids);
	writefile(outdirpath + "/sessions", text);
}

writesession(r: ref SessRing)
{
	d := sys->sprint("%s/%d", outdirpath, r.id);
	ensuredir(d);

	# current — newest sample only
	if(r.samples != nil) {
		s := hd r.samples;
		writefile(d + "/current",
			sys->sprint("%d %s %d %d\n", s.ms, r.model, s.tokens, s.limit));
	}

	# history — oldest first, one sample per line
	text := "";
	# r.samples is newest-first; flip it.
	rev: list of Sample;
	for(sl := r.samples; sl != nil; sl = tl sl)
		rev = hd sl :: rev;
	for(; rev != nil; rev = tl rev) {
		s := hd rev;
		text += sys->sprint("%d %d %d\n", s.ms, s.tokens, s.limit);
	}
	writefile(d + "/history", text);
}

# ── Filesystem helpers ───────────────────────────────────────

ensuredir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == 0)
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd != nil)
		fd = nil;
}

# Replace via tmp + rename so readers never see a torn write: they
# get the old content, the complete new content, or (briefly) no
# file — and every reader here already treats open-failure as empty.
writefile(path, text: string)
{
	tmp := path + ".tmp";
	fd := sys->create(tmp, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
	fd = nil;
	sys->remove(path);
	nd := sys->nulldir;
	nd.name = basename(path);
	sys->wstat(tmp, nd);
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i+1:];
	return p;
}

readf(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

trim(s: string): string
{
	if(s == nil)
		return nil;
	end := len s;
	while(end > 0 && (s[end-1] == '\n' || s[end-1] == ' ' || s[end-1] == '\t'))
		end--;
	start := 0;
	while(start < end && (s[start] == ' ' || s[start] == '\t'))
		start++;
	return s[start:end];
}

isnumeric(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}
