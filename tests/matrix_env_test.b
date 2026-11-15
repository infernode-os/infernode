implement MatrixEnvTest;

#
# matrix_env_test - a room's readings, from sensor to rings (#1199)
#
# envsrv(4): its simulated sensor's files and values; a BME280's
# arithmetic against the datasheet's worked example (BST-BME280-DS002,
# section 8.2: dig_T1..dig_P9 and adc_T 519888, adc_P 415148 giving
# 25.08 C and 1006.53 hPa), through a fake I2C bus served by file2chan as
# #J serves one (pread and pwrite at the register's offset); a BMP280
# serving no humidity file; a sensor that stops answering an error on
# the read, saying why, and found again when it answers.
#
# history-svc: a directory's numbers sampled at start ("ts value"), what
# is not a number passed over, the history already in its outdir read
# back and kept, a ring of 1440, shutdown within seconds.
#
# line-plot loads as a display. Its drawing needs a display; see
# lib/matrix/compositions/environment.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "matrix.m";

include "testing.m";
	testing: Testing;
	T: import testing;

MatrixEnvTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/matrix_env_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	out := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("%r"));
		if(n == 0)
			break;
		out += string buf[0:n];
	}
	return (out, nil);
}

writefile(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

rm(path: string)
{
	sh := load Sh Sh->PATH;
	if(sh != nil)
		sh->system(nil, "rm -rf " + path);
}

# mount {cmd} dir, as the shell's mount does: cmd serves 9P on its
# standard input
mountcmd(t: ref T, argv: list of string, dir: string)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of int;
	spawn server(argv, p[1], sync);
	<-sync;
	p[1] = nil;
	if(sys->mount(p[0], nil, dir, Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount %s: %r", hd argv));
}

server(argv: list of string, fd: ref Sys->FD, sync: chan of int)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->NEWFD, 2 :: fd.fd :: nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	sync <-= 1;
	cmd := load Command "/dis/" + hd argv + ".dis";
	if(cmd == nil)
		return;
	{
		cmd->init(nil, argv);
	} exception {
	"fail:*" =>
		;
	}
}

isnum(s: string): int
{
	if(s == nil)
		return 0;
	(nt, toks) := sys->tokenize(s, " \n");
	if(nt != 1)
		return 0;
	w := hd toks;
	digits := 0;
	for(i := 0; i < len w; i++)
		if(w[i] >= '0' && w[i] <= '9')
			digits++;
		else if(w[i] != '.' && w[i] != '-')
			return 0;
	return digits > 0;
}

# ── envsrv's simulated sensor ───────────────────────────────

testSim(t: ref T)
{
	d := "/tmp/envtest-sim";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
	mountcmd(t, "envsrv" :: "-t" :: nil, d);
	(ctl, err) := readfile(d + "/ctl");
	t.assertseq(ctl, "sim\n", "ctl names the simulation (" + err + ")");
	lims := array[] of {("temp", 15.0, 35.0), ("humidity", 40.0, 85.0), ("pressure", 995.0, 1025.0)};
	for(i := 0; i < len lims; i++){
		(name, lo, hi) := lims[i];
		(s, e) := readfile(d + "/" + name);
		t.assert(isnum(s), name + " is a number: " + s + e);
		v := real s;
		t.assert(v >= lo && v <= hi, sys->sprint("%s %g within %g..%g", name, v, lo, hi));
	}
	# within a second, one measurement: the same value
	(a, nil) := readfile(d + "/temp");
	(b, nil) := readfile(d + "/temp");
	t.assertseq(b, a, "two reads within a second agree");
	sys->unmount(nil, d);
}

# ── a BME280's arithmetic, on a fake bus ────────────────────

# the datasheet's example (section 8.2), a BMP280's id
cal := array[] of {
	27504, 26435, -1000,	# dig_T1 T2 T3
	36477, -10685, 3024, 2855, 140, -7, 15500, -14600, 6000,	# dig_P1..P9
};
ADCT: con 519888;
ADCP: con 415148;

regs: array of byte;
answering := 1;

fakebus(t: ref T): string
{
	regs = array[256] of { * => byte 0 };
	regs[16rD0] = byte 16r58;
	for(i := 0; i < len cal; i++){
		v := cal[i];
		regs[16r88 + 2*i] = byte v;
		regs[16r88 + 2*i + 1] = byte (v >> 8);
	}
	regs[16rF7] = byte (ADCP >> 12);
	regs[16rF8] = byte (ADCP >> 4);
	regs[16rF9] = byte ((ADCP & 16rF) << 4);
	regs[16rFA] = byte (ADCT >> 12);
	regs[16rFB] = byte (ADCT >> 4);
	regs[16rFC] = byte ((ADCT & 16rF) << 4);

	d := "/tmp/envtest-bus";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
	if(sys->bind("#s", d, Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind #s: %r"));
	ctl := sys->file2chan(d, "i2c1ctl");
	data := sys->file2chan(d, "i2c1data");
	if(ctl == nil || data == nil)
		t.fatal(sys->sprint("file2chan: %r"));
	spawn serveCtl(ctl);
	spawn serveData(data);
	return d;
}

serveCtl(f: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			rc <-= (array of byte "", nil);
	(nil, b, nil, wc) := <-f.write =>
		if(wc != nil)
			wc <-= (len b, nil);
	}
}

serveData(f: ref Sys->FileIO)
{
	for(;;) alt {
	(off, n, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		if(!answering){
			rc <-= (nil, "i2c: no acknowledge");
			continue;
		}
		if(off < 0 || off + n > len regs)
			n = len regs - off;
		rc <-= (regs[off:off+n], nil);
	(off, b, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		if(!answering){
			wc <-= (0, "i2c: no acknowledge");
			continue;
		}
		regs[off:] = b;
		regs[16rF3] = byte 0;	# the measurement done at once
		wc <-= (len b, nil);
	}
}

testBmp280(t: ref T)
{
	bus := fakebus(t);
	d := "/tmp/envtest-bmp";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
	mountcmd(t, "envsrv" :: "-d" :: bus :: "-a" :: "0x76" :: nil, d);
	(ctl, e) := readfile(d + "/ctl");
	t.assertseq(ctl, "chip=0x58 addr=0x76 bus=1 dir=" + bus + "\n", "ctl names the sensor " + e);
	(tv, e1) := readfile(d + "/temp");
	t.assertseq(tv, "25.08\n", "the datasheet's temperature " + e1);
	(pv, e2) := readfile(d + "/pressure");
	t.assertseq(pv, "1006.53\n", "the datasheet's pressure " + e2);
	(ok, nil) := sys->stat(d + "/humidity");
	t.assert(ok < 0, "a BMP280 serves no humidity");

	# stopped: an error on the read, saying why
	sys->sleep(1100);
	answering = 0;
	(s, err) := readfile(d + "/temp");
	t.assert(s == nil && err != nil, "a sensor not answering is an error: " + s);
	t.assert(len err > 0 && contains(err, "no acknowledge"), "saying why: " + err);
	(ctl, nil) = readfile(d + "/ctl");
	t.assertseq(ctl, "chip=none bus=1 dir=" + bus + "\n", "ctl says it has none");

	# answering again: found, its calibration read again
	answering = 1;
	(tv, e1) = readfile(d + "/temp");
	t.assertseq(tv, "25.08\n", "found again " + e1);
	sys->unmount(nil, d);
}

contains(s, w: string): int
{
	for(i := 0; i + len w <= len s; i++)
		if(s[i:i+len w] == w)
			return 1;
	return 0;
}

testNoSensor(t: ref T)
{
	# a directory with no I2C files: said at once, not served empty
	d := "/tmp/envtest-none";
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	sync := chan of int;
	spawn server("envsrv" :: "-d" :: "/tmp/envtest-nothere" :: nil, p[1], sync);
	<-sync;
	p[1] = nil;
	t.assert(sys->mount(p[0], nil, d, Sys->MREPL, nil) < 0, "no sensor, no mount");
}

# ── history-svc ─────────────────────────────────────────────

svc: MatrixService;
done: chan of int;

runsvc()
{
	svc->run();
	done <-= 1;
}

testHistory(t: ref T)
{
	src := "/tmp/envtest-src";
	out := "/tmp/envtest-out";
	rm(src + " " + out);
	sys->create(src, Sys->OREAD, Sys->DMDIR|8r755);
	writefile(src + "/temp", "24.34\n");
	writefile(src + "/pressure", "970.84\n");
	writefile(src + "/ctl", "chip=0x60 addr=0x76 bus=1 dir=#J\n");
	writefile(src + "/note", "no number here\n");

	# a day and a minute already recorded, of which a day is kept
	sys->create(out, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(out + "/temp", Sys->OREAD, Sys->DMDIR|8r755);
	h := "";
	t0 := 1763000000;
	for(i := 0; i < 1441; i++)
		h += sys->sprint("%d %d.5\n", t0 + 60*i, i % 30);
	writefile(out + "/temp/history", h);

	svc = load MatrixService "/dis/matrix/history-svc.dis";
	if(svc == nil)
		t.fatal(sys->sprint("cannot load history-svc: %r"));
	t.assertnil(svc->init(src, out), "init");
	done = chan of int;
	spawn runsvc();
	sys->sleep(1500);

	(p, e) := readfile(out + "/pressure/history");
	(n, ls) := sys->tokenize(p, "\n");
	t.asserteq(n, 1, "one sample at start " + e);
	if(n == 1){
		(nt, toks) := sys->tokenize(hd ls, " ");
		t.asserteq(nt, 2, "ts value");
		if(nt == 2){
			t.assertseq(hd tl toks, "970.84", "the value as written");
			now := int (readnum("/dev/time") / big 1000000);
			ts := int hd toks;
			t.assert(ts >= now - 5 && ts <= now + 5, sys->sprint("its time %d is now (%d)", ts, now));
		}
	}
	(c, nil) := readfile(out + "/pressure/current");
	t.assertseq(c, "970.84\n", "current");
	(ok, nil) := sys->stat(out + "/ctl");
	t.assert(ok < 0, "ctl, not a number, passed over");
	(ok, nil) = sys->stat(out + "/note");
	t.assert(ok < 0, "nor a word");

	(th, nil) := readfile(out + "/temp/history");
	(n, ls) = sys->tokenize(th, "\n");
	t.asserteq(n, 1440, "a day kept");
	t.assertseq(hd ls, sys->sprint("%d 2.5", t0 + 60*2), "the oldest two gone: one by the ring, one by the new sample");
	last := "";
	for(; ls != nil; ls = tl ls)
		last = hd ls;
	t.assert(len last > 6 && last[len last - 6:] == " 24.34", "the new sample last: " + last);

	svc->shutdown();
	alt {
	<-done =>
		;
	<-timer(3000) =>
		t.error("run did not return within 3 s of shutdown");
	}
}

readnum(path: string): big
{
	(s, nil) := readfile(path);
	return big s;
}

timer(ms: int): chan of int
{
	c := chan of int;
	spawn tick(c, ms);
	return c;
}

tick(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

testLoads(t: ref T)
{
	m := load MatrixDisplay "/dis/matrix/line-plot.dis";
	t.assert(m != nil, "line-plot loads as MatrixDisplay");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Sim", testSim);
	run("Bmp280", testBmp280);
	run("NoSensor", testNoSensor);
	run("History", testHistory);
	run("Loads", testLoads);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
