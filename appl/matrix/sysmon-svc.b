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
#   <outdir>/proc/cpurates one "pid pct" line per live process:
#                          tick delta since the previous poll,
#                          normalised to percent (new pids read 0)
#   <outdir>/net/current   connection census: "tcp total connected
#                          announced" and "udp ..." lines derived
#                          from /net/<proto>/<conv>/status
#   <outdir>/net/history   60-sample ring: ts tcp_total tcp_conn
#                          udp_total
#   <outdir>/net/stats     verbatim /net/tcp/stats when the platform
#                          implements it (emu does not; native ports
#                          do) — absent otherwise
#
# Sources (no /dev/sysstat in emu — derive CPU from /prog tick
# totals; /dev/memory replaces /dev/swap):
#   /dev/memory            emu pool stats (main / heap / image)
#   /prog/<pid>/status     per-process state and tick count
#   /net/{tcp,udp}         per-connection status files
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

last_poll_ms:		int;

# Per-pid tick counts from the previous poll, for proc/cpurates.
lastticks:	list of (string, big);

# Net census rings (share ts_hist/hist_n/hist_w with the others).
tcp_tot_hist:	array of int;
tcp_conn_hist:	array of int;
udp_tot_hist:	array of int;

init(nil: string, outdir: string): string
{
	sys = load Sys Sys->PATH;

	outdir_g = outdir;
	running = 1;
	hist_n = 0;
	hist_w = 0;
	last_poll_ms = 0;

	lastticks = nil;
	tcp_tot_hist = array[HISTLEN] of int;
	tcp_conn_hist = array[HISTLEN] of int;
	udp_tot_hist = array[HISTLEN] of int;

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
	mkdir(outdir_g + "/net");
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

	# CPU: each proc's CPU time against the previous poll, over the
	# elapsed real time.  The whole is the sum over the procs seen at
	# both polls, so one that exits takes its time with it rather
	# than making the total go backwards.
	(proc_snapshot, busy_count, proc_count, perproc) := scanprog();
	writefile(outdir_g + "/proc/list", proc_snapshot);

	dt_ms := 0;
	if(last_poll_ms != 0)
		dt_ms = now - last_poll_ms;
	last_poll_ms = now;

	# Per-process rates from CPU-time deltas against the previous poll.
	dcpu := writecpurates(perproc, dt_ms);
	pct := 0;
	if(dt_ms > 0)
		pct = clamppct(dcpu * big 100 / big dt_ms);

	# Net census (+ verbatim stats where the platform provides them).
	(tcp_tot, tcp_conn, tcp_ann) := censusproto("tcp");
	(udp_tot, udp_conn, udp_ann) := censusproto("udp");
	writefile(outdir_g + "/net/current",
		sys->sprint("tcp %d %d %d\nudp %d %d %d\n",
			tcp_tot, tcp_conn, tcp_ann, udp_tot, udp_conn, udp_ann));
	stats := readfile("/net/tcp/stats");
	if(stats != "")
		writefile(outdir_g + "/net/stats", stats);

	# Push into history.
	tcp_tot_hist[hist_w] = tcp_tot;
	tcp_conn_hist[hist_w] = tcp_conn;
	udp_tot_hist[hist_w] = udp_tot;
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

	# Emit mem/history and net/history.
	writememhistory();
	writenethistory();
}

# ─── Per-process CPU rates ─────────────────────────────────

# Writes proc/cpurates; returns the CPU ms used since the last poll
# by the procs seen at both.
writecpurates(perproc: list of (string, big), dt_ms: int): big
{
	out := "";
	total := big 0;
	newlast: list of (string, big);
	for(pl := perproc; pl != nil; pl = tl pl) {
		(pid, cpu) := hd pl;
		pct := 0;
		if(dt_ms > 0) {
			for(ol := lastticks; ol != nil; ol = tl ol) {
				(opid, ocpu) := hd ol;
				if(opid == pid) {
					if(cpu > ocpu)
						total += cpu - ocpu;
					pct = clamppct((cpu - ocpu) * big 100 / big dt_ms);
					break;
				}
			}
		}
		out += sys->sprint("%s %d\n", pid, pct);
		newlast = (pid, cpu) :: newlast;
	}
	lastticks = newlast;
	writefile(outdir_g + "/proc/cpurates", out);
	return total;
}

clamppct(p: big): int
{
	if(p < big 0)
		return 0;
	if(p > big 100)
		return 100;
	return int p;
}

# /prog/<pid>/status gives CPU time as minutes:seconds.tenths
# ("   1:02.3", devprog's progtime): to ms.
cputime(s: string): big
{
	m := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == ':')
			break;
	if(i == len s)
		return big 0;
	m = int s[0:i];
	rest := s[i+1:];
	sec := 0;
	tenths := 0;
	for(j := 0; j < len rest; j++)
		if(rest[j] == '.')
			break;
	sec = int rest[0:j];
	if(j + 1 < len rest)
		tenths = int rest[j+1:j+2];
	return (big m * big 60 + big sec) * big 1000 + big tenths * big 100;
}

# ─── Net census ────────────────────────────────────────────

# Count conversations by state under /net/<proto>: total,
# Connected, Announced.  Each numeric directory's status file
# leads with the state word (see devip.c ipstates).
censusproto(proto: string): (int, int, int)
{
	total := 0;
	connected := 0;
	announced := 0;
	fd := sys->open("/net/" + proto, Sys->OREAD);
	if(fd == nil)
		return (0, 0, 0);
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(name == "" || name[0] < '0' || name[0] > '9')
				continue;
			status := readfile("/net/" + proto + "/" + name + "/status");
			if(status == "")
				continue;
			total++;
			(ntoks, toks) := sys->tokenize(status, " \t\n");
			if(ntoks < 1)
				continue;
			case hd toks {
			"Connected" or "Established" =>
				connected++;
			"Announced" or "Listen" =>
				announced++;
			}
		}
	}
	fd = nil;
	return (total, connected, announced);
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

scanprog(): (string, int, int, list of (string, big))
{
	snapshot := "";
	busy := 0;
	count := 0;
	perproc: list of (string, big);

	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return ("", 0, 0, nil);

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
			# time is CPU time, M:SS.t.  state is devprog's: ready
			# is runnable; alt, send, recv are blocked on channels,
			# release in a system call, and so on.
			(ntoks, toks) := sys->tokenize(status, " \t\n");
			if(ntoks >= 7) {
				toks = tl toks; toks = tl toks; toks = tl toks;
				perproc = (pid, cputime(hd toks)) :: perproc;
				toks = tl toks;
				if(hd toks == "ready")
					busy++;
			}
			count++;
		}
	}
	fd = nil;
	return (snapshot, busy, count, perproc);
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

writenethistory()
{
	out := "";
	start := 0;
	if(hist_n == HISTLEN)
		start = hist_w;
	for(i := 0; i < hist_n; i++) {
		idx := (start + i) % HISTLEN;
		out += sys->sprint("%d %d %d %d\n",
			ts_hist[idx], tcp_tot_hist[idx],
			tcp_conn_hist[idx], udp_tot_hist[idx]);
	}
	writefile(outdir_g + "/net/history", out);
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

# Replace via tmp + rename so readers never see a torn write: they
# get the old content, the complete new content, or (briefly) no
# file — and every reader here already treats open-failure as empty.
writefile(path, content: string)
{
	tmp := path + ".tmp";
	fd := sys->create(tmp, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte content;
	sys->write(fd, data, len data);
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

mkdir(path: string)
{
	# Ignore failure: directory may already exist (after reload).
	(ok, nil) := sys->stat(path);
	if(ok == 0)
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	fd = nil;
}
