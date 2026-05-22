implement SysmonSvc;

#
# sysmon-svc — Matrix service module: system stats collector.
#
# Polls the Inferno namespace at 1 Hz and writes ring-buffer
# snapshots that the cpu-gauge / mem-gauge / proc-list display
# modules consume:
#
#   <outdir>/mem/current   one line per pool, latest sample
#                          (cursize maxsize hw nalloc nfree nbrk
#                          poolmax name) — verbatim format of
#                          /dev/memory
#   <outdir>/mem/history   60-sample ring: ts heap_cur heap_max
#                          main_cur main_max image_cur image_max
#   <outdir>/cpu/current   pct busy_procs total_procs
#   <outdir>/cpu/history   60-sample ring: ts pct
#   <outdir>/proc/list     snapshot of /prog/*/status, one row per
#                          live process (PID GRP USER TIME STATE
#                          SIZE_K MODULE) — fixed-width fields per
#                          devprog.c
#
# Sources (no /dev/sysstat in emu — derive CPU from /prog tick
# totals; /dev/memory replaces /dev/swap):
#   /dev/memory            emu pool stats (main / heap / image)
#   /prog/<pid>/status     per-process state and tick count
#
# No external mount required: the service inherits the host
# namespace.  Compositions assign `service sysmon-svc /` for
# clarity even though `mount` is unused.

include "sys.m";
	sys: Sys;

include "draw.m";

include "matrix.m";

SysmonSvc: module
{
	init:		fn(mount: string, outdir: string): string;
	run:		fn();
	shutdown:	fn();
};

outdir_g:	string;
running:	int;
POLL_MS:	con 1000;
HISTLEN:	con 60;

# Per-pool ring buffers.  index [0..HISTLEN-1] is a wrap pointer.
cpu_hist:	array of int;		# busy percent samples
heap_cur_hist:	array of big;
heap_max_hist:	array of big;
main_cur_hist:	array of big;
main_max_hist:	array of big;
image_cur_hist:	array of big;
image_max_hist:	array of big;
ts_hist:	array of int;
hist_n:		int;			# samples written so far
hist_w:		int;			# next write index

last_total_ticks:	big;
last_poll_ms:		int;

init(nil: string, outdir: string): string
{
	sys = load Sys Sys->PATH;

	outdir_g = outdir;
	running = 1;
	hist_n = 0;
	hist_w = 0;
	last_total_ticks = big 0;
	last_poll_ms = 0;

	cpu_hist = array[HISTLEN] of int;
	heap_cur_hist = array[HISTLEN] of big;
	heap_max_hist = array[HISTLEN] of big;
	main_cur_hist = array[HISTLEN] of big;
	main_max_hist = array[HISTLEN] of big;
	image_cur_hist = array[HISTLEN] of big;
	image_max_hist = array[HISTLEN] of big;
	ts_hist = array[HISTLEN] of int;

	mkdir(outdir_g);
	mkdir(outdir_g + "/mem");
	mkdir(outdir_g + "/cpu");
	mkdir(outdir_g + "/proc");
	return nil;
}

run()
{
	while(running) {
		poll();
		sys->sleep(POLL_MS);
	}
}

shutdown()
{
	running = 0;
}

# ─── Polling ────────────────────────────────────────────────

poll()
{
	now := sys->millisec();

	# Memory snapshot.  Verbatim copy of /dev/memory into mem/current;
	# parsed values fed into the history ring.
	mem := readfile("/dev/memory");
	writefile(outdir_g + "/mem/current", mem);
	(heap_cur, heap_max, main_cur, main_max, image_cur, image_max) :=
		parsemem(mem);

	# CPU: aggregate ticks across /prog and divide by elapsed real time.
	(proc_snapshot, total_ticks, busy_count, proc_count) := scanprog();
	writefile(outdir_g + "/proc/list", proc_snapshot);

	pct := 0;
	if(last_poll_ms != 0 && last_total_ticks != big 0) {
		dt_ms := now - last_poll_ms;
		dt_ticks := total_ticks - last_total_ticks;
		# Inferno tick is roughly 1ms; for portability, normalise:
		# 1 tick per ms means pct = dt_ticks * 100 / dt_ms.  If
		# dt_ticks > dt_ms, clamp to 100.
		if(dt_ms > 0) {
			p := int (dt_ticks * big 100 / big dt_ms);
			if(p < 0) p = 0;
			if(p > 100) p = 100;
			pct = p;
		}
	}
	last_total_ticks = total_ticks;
	last_poll_ms = now;

	# Push into history.
	cpu_hist[hist_w] = pct;
	heap_cur_hist[hist_w] = heap_cur;
	heap_max_hist[hist_w] = heap_max;
	main_cur_hist[hist_w] = main_cur;
	main_max_hist[hist_w] = main_max;
	image_cur_hist[hist_w] = image_cur;
	image_max_hist[hist_w] = image_max;
	ts_hist[hist_w] = now;
	hist_w = (hist_w + 1) % HISTLEN;
	if(hist_n < HISTLEN)
		hist_n++;

	# Emit cpu/current and cpu/history.
	writefile(outdir_g + "/cpu/current",
		sys->sprint("%d %d %d\n", pct, busy_count, proc_count));
	writehistory();

	# Emit mem/history.
	writememhistory();
}

# ─── /dev/memory parsing ───────────────────────────────────

# Lines: "%11lud %11lud %11lud %11lud %11lud %11d %11lud %s\n"
# fields: cursize maxsize hw nalloc nfree nbrk poolmax name
# We care about cursize, maxsize, and name for the named pools
# (main, heap, image).
parsemem(content: string): (big, big, big, big, big, big)
{
	heap_cur, heap_max, main_cur, main_max, image_cur, image_max: big;
	start := 0;
	for(i := 0; i <= len content; i++) {
		if(i == len content || content[i] == '\n') {
			if(i > start) {
				line := content[start:i];
				(ntoks, toks) := sys->tokenize(line, " \t");
				if(ntoks >= 8) {
					cur := big hd toks; toks = tl toks;
					max := big hd toks; toks = tl toks;
					# skip hw nalloc nfree nbrk poolmax
					for(k := 0; k < 5; k++)
						toks = tl toks;
					name := hd toks;
					case name {
					"main" =>
						main_cur = cur; main_max = max;
					"heap" =>
						heap_cur = cur; heap_max = max;
					"image" =>
						image_cur = cur; image_max = max;
					}
				}
			}
			start = i + 1;
		}
	}
	return (heap_cur, heap_max, main_cur, main_max, image_cur, image_max);
}

# ─── /prog scanning ────────────────────────────────────────

scanprog(): (string, big, int, int)
{
	snapshot := "";
	total_ticks := big 0;
	busy := 0;
	count := 0;

	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return ("", big 0, 0, 0);

	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			pid := dirs[i].name;
			status := readfile("/prog/" + pid + "/status");
			if(status == "")
				continue;
			snapshot += status;
			if(status[len status - 1] != '\n')
				snapshot += "\n";
			# status: "%8d %8d %10s %s %10s %5dK %s"
			# fields: pid grpid user time state size_k module
			# "time" is "ticks" — parse the leading integer.
			(ntoks, toks) := sys->tokenize(status, " \t\n");
			if(ntoks >= 7) {
				toks = tl toks; toks = tl toks; toks = tl toks;
				ticks := big hd toks;
				total_ticks += ticks;
				toks = tl toks;
				state := hd toks;
				if(state != "Sleep" && state != "Wait" &&
				   state != "Exit" && state != "exiting" &&
				   state != "exiting]" && state != "broken")
					busy++;
			}
			count++;
		}
	}
	fd = nil;
	return (snapshot, total_ticks, busy, count);
}

# ─── History writers ───────────────────────────────────────

writehistory()
{
	out := "";
	# Emit oldest-first.
	start := 0;
	if(hist_n == HISTLEN)
		start = hist_w;
	for(i := 0; i < hist_n; i++) {
		idx := (start + i) % HISTLEN;
		out += sys->sprint("%d %d\n", ts_hist[idx], cpu_hist[idx]);
	}
	writefile(outdir_g + "/cpu/history", out);
}

writememhistory()
{
	out := "";
	start := 0;
	if(hist_n == HISTLEN)
		start = hist_w;
	for(i := 0; i < hist_n; i++) {
		idx := (start + i) % HISTLEN;
		out += sys->sprint("%d %bd %bd %bd %bd %bd %bd\n",
			ts_hist[idx],
			heap_cur_hist[idx], heap_max_hist[idx],
			main_cur_hist[idx], main_max_hist[idx],
			image_cur_hist[idx], image_max_hist[idx]);
	}
	writefile(outdir_g + "/mem/history", out);
}

# ─── File I/O ──────────────────────────────────────────────

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	fd = nil;
	return out;
}

writefile(path, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte content;
	sys->write(fd, data, len data);
	fd = nil;
}

mkdir(path: string)
{
	# Ignore failure: directory may already exist (after reload).
	(ok, nil) := sys->stat(path);
	if(ok == 0)
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	fd = nil;
}
