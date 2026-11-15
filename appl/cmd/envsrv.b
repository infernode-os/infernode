implement Envsrv;

#
# envsrv [-t] [-d dir] [-b bus] [-a addr]: a sensor's readings of the
# room as files, served on standard input (mount {envsrv} /mnt/env):
#
#	temp		degrees Celsius ("24.34\n")
#	humidity	relative humidity, percent ("57.4\n"); absent where the
#			sensor has none (a BMP280)
#	pressure	hPa ("970.84\n")
#	ctl		the sensor: "chip=0x60 addr=0x76 bus=1 dir=#J\n", or "sim\n"
#
# A read of a value file at offset 0 is a measurement taken then, all
# three values at once; reads within a second of one get its values,
# so a reader of the three files sees one measurement. A sensor that
# stops answering is an error on the read, saying why, and the next
# read finds it again (its calibration read again): a BME280 has been
# seen to stop on its bus and come back only with its power.
#
# The sensor is a Bosch BME280 or BMP280 on #J, the board's I2C, at
# 0x76 or 0x77 (-a one of them); -d names another directory of I2C
# files (another machine's #J, mounted). The compensation is the
# datasheet's (BST-BME280-DS002, section 4.2.3, the floating-point
# version), from the trimming values in 0x88-0xA1 and 0xE1-0xE7.
#
# -t simulates one, as camsrv -t simulates a camera: the temperature
# swings 6 degrees over the day, highest mid-afternoon, humidity against
# it, the pressure has its twice-daily tide and a slower drift, each
# with a little noise. The values are a function of the time, so two
# readers at one moment agree.
#
# Another sensor is another server serving these names; what reads
# them does not know which. history-svc (Matrix) records them.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "math.m";
	math: Math;
include "daytime.m";
	daytime: Daytime;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Envsrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Qdir, Qtemp, Qhum, Qpress, Qctl: con iota;

Idreg:	con 16rD0;
Ctrlhum:	con 16rF2;
Status:	con 16rF3;
Ctrlmeas:	con 16rF4;
Data:	con 16rF7;

# the sensor
sim := 0;
dir := "#J";
bus := "1";
addrs: list of int;
data: ref Sys->FD;
chip := -1;
addr := -1;
hum := 0;
t1, t2, t3, p1: real;
p: array of real;
h1, h2, h3, h4, h5, h6: real;

# the last measurement
lastms := 0;
have := 0;
vtemp, vhum, vpress: real;

user := "inferno";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	daytime = load Daytime Daytime->PATH;
	arg := load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	if(math == nil || daytime == nil || arg == nil || styx == nil || styxservers == nil || nametree == nil)
		fail(sys->sprint("cannot load a module: %r"));
	arg->init(args);
	arg->setusage("envsrv [-t] [-d dir] [-b bus] [-a addr]");
	addrs = 16r76 :: 16r77 :: nil;
	while((c := arg->opt()) != 0)
		case c {
		't' =>
			sim = 1;
		'b' =>
			bus = arg->earg();
		'd' =>
			dir = arg->earg();
		'a' =>
			(a, err) := toint(arg->earg());
			if(err != nil)
				arg->usage();
			addrs = a :: nil;
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	user = getuser();

	# find the sensor before serving: a missing one is said at once,
	# not as an empty directory
	if(!sim){
		err := probe();
		if(err != nil)
			fail(err);
	}

	styx->init();
	styxservers->init(styx);
	nametree->init();
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, mkdir(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, mkdir("temp", 8r444, Qtemp));
	if(sim || hum)
		tree.create(big Qdir, mkdir("humidity", 8r444, Qhum));
	tree.create(big Qdir, mkdir("pressure", 8r444, Qpress));
	tree.create(big Qdir, mkdir("ctl", 8r444, Qctl));
	(tc, srv) := Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qdir);
	serve(tc, srv);
	tree.quit();
}

serve(tc: chan of ref Tmsg, srv: ref Styxserver)
{
	while((tmsg := <-tc) != nil){
		pick tm := tmsg {
		Readerror =>
			break;
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);
			Qctl =>
				srv.reply(styxservers->readstr(tm, describe()));
			Qtemp or Qhum or Qpress =>
				if(tm.offset == big 0 || !have){
					err := measure();
					if(err != nil){
						srv.reply(ref Rmsg.Error(tm.tag, err));
						continue;
					}
				}
				s: string;
				case int c.path {
				Qtemp =>	s = sys->sprint("%.2f\n", vtemp);
				Qhum =>	s = sys->sprint("%.1f\n", vhum);
				* =>		s = sys->sprint("%.2f\n", vpress);
				}
				srv.reply(styxservers->readstr(tm, s));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			}
		* =>
			srv.default(tmsg);
		}
	}
}

describe(): string
{
	if(sim)
		return "sim\n";
	if(chip < 0)
		return sys->sprint("chip=none bus=%s dir=%s\n", bus, dir);
	return sys->sprint("chip=%#x addr=%#x bus=%s dir=%s\n", chip, addr, bus, dir);
}

# take a measurement unless the last is under a second old
measure(): string
{
	now := sys->millisec();
	if(have && now - lastms < 1000 && now >= lastms)
		return nil;
	err: string;
	if(sim)
		simulate();
	else{
		if(chip < 0)
			err = probe();
		if(err == nil)
			err = readsensor();
		if(err != nil){
			chip = -1;	# find it again next time
			data = nil;
			have = 0;
			return err;
		}
	}
	lastms = now;
	have = 1;
	return nil;
}

simulate()
{
	t := real daytime->now() + real (sys->millisec() % 1000) / 1000.0;
	day := 2.0 * Math->Pi * fmod(t, 86400.0) / 86400.0;
	# coolest about 03:00, warmest about 15:00 (UTC)
	w := math->sin(day - Math->Pi * 0.75);
	vtemp = 26.0 + 3.0 * w + 0.05 * noise(t, 1);
	vhum = 62.0 - 10.0 * w + 0.3 * noise(t, 2);
	vpress = 1010.0 + 1.2 * math->sin(2.0 * day) + 4.0 * math->sin(2.0 * Math->Pi * t / (5.0 * 86400.0)) + 0.03 * noise(t, 3);
}

fmod(a, b: real): real
{
	return a - b * math->floor(a / b);
}

# a value in [-1, 1) for each second and stream, the same for both readers
noise(t: real, k: int): real
{
	x := int fmod(t, 1.0e6) * 7919 + k * 104729;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	return real (x & 16rFFFF) / 32768.0 - 1.0;
}

# find the sensor and read its calibration
probe(): string
{
	ctl := dir + "/i2c" + bus + "ctl";
	dname := dir + "/i2c" + bus + "data";
	chip = -1;
	for(a := addrs; a != nil; a = tl a){
		cfd := sys->open(ctl, Sys->OWRITE);
		if(cfd == nil)
			return sys->sprint("%s: %r", ctl);
		if(sys->fprint(cfd, "addr %#x", hd a) < 0 || sys->fprint(cfd, "subaddress 1") < 0)
			return sys->sprint("%s: %r", ctl);
		data = sys->open(dname, Sys->ORDWR);
		if(data == nil)
			return sys->sprint("%s: %r", dname);
		b := array[1] of byte;
		if(sys->pread(data, b, 1, big Idreg) == 1){
			chip = int b[0];
			addr = hd a;
			break;
		}
	}
	if(chip < 0)
		return "no device answers on i2c" + bus;
	if(chip != 16r60 && chip != 16r58){
		err := sys->sprint("device at %#x on i2c%s has chip id %#x: not a BME280 (0x60) or BMP280 (0x58)", addr, bus, chip);
		chip = -1;
		return err;
	}
	hum = chip == 16r60;
	(cal, err) := get(16r88, 26);
	if(err != nil)
		return err;
	t1 = real u16(cal, 0);
	t2 = real s16(cal, 2);
	t3 = real s16(cal, 4);
	p1 = real u16(cal, 6);
	p = array[10] of real;	# P2..P9 at their own numbers
	for(i := 2; i <= 9; i++)
		p[i] = real s16(cal, 6+2*(i-1));	# P2 at 0x8E ... P9 at 0x9E
	if(hum){
		h1 = real int cal[25];
		e: array of byte;
		(e, err) = get(16rE1, 7);
		if(err != nil)
			return err;
		h2 = real s16(e, 0);
		h3 = real int e[2];
		h4 = real sext((int e[3] << 4) | (int e[4] & 16rF), 12);
		h5 = real sext((int e[5] << 4) | (int e[4] >> 4), 12);
		h6 = real sext(int e[6], 8);
	}
	return nil;
}

# one forced measurement
readsensor(): string
{
	err: string;
	if(hum && (err = put(Ctrlhum, 16r01)) != nil)	# humidity oversampled once
		return err;
	if((err = put(Ctrlmeas, 16r25)) != nil)	# temperature and pressure once, forced mode
		return err;
	for(n := 0; n < 50; n++){
		sys->sleep(10);
		st: array of byte;
		(st, err) = get(Status, 1);
		if(err != nil)
			return err;
		if((int st[0] & 16r08) == 0)
			break;
	}
	m: array of byte;
	(m, err) = get(Data, 8);
	if(err != nil)
		return err;
	adcp := real ((int m[0] << 12) | (int m[1] << 4) | (int m[2] >> 4));
	adct := real ((int m[3] << 12) | (int m[4] << 4) | (int m[5] >> 4));
	adch := real ((int m[6] << 8) | int m[7]);

	v1 := (adct/16384.0 - t1/1024.0) * t2;
	v2 := (adct/131072.0 - t1/8192.0) * (adct/131072.0 - t1/8192.0) * t3;
	tfine := v1 + v2;
	vtemp = tfine / 5120.0;

	v1 = tfine/2.0 - 64000.0;
	v2 = v1 * v1 * p[6] / 32768.0;
	v2 = v2 + v1 * p[5] * 2.0;
	v2 = v2/4.0 + p[4] * 65536.0;
	v1 = (p[3] * v1 * v1 / 524288.0 + p[2] * v1) / 524288.0;
	v1 = (1.0 + v1/32768.0) * p1;
	if(v1 == 0.0)
		return "pressure calibration is zero";
	press := 1048576.0 - adcp;
	press = (press - v2/4096.0) * 6250.0 / v1;
	v1 = p[9] * press * press / 2147483648.0;
	v2 = press * p[8] / 32768.0;
	vpress = (press + (v1 + v2 + p[7]) / 16.0) / 100.0;

	if(hum){
		hh := tfine - 76800.0;
		hh = (adch - (h4*64.0 + h5/16384.0*hh)) * (h2/65536.0 * (1.0 + h6/67108864.0*hh*(1.0 + h3/67108864.0*hh)));
		hh = hh * (1.0 - h1*hh/524288.0);
		if(hh > 100.0)
			hh = 100.0;
		if(hh < 0.0)
			hh = 0.0;
		vhum = hh;
	}
	return nil;
}

get(reg, n: int): (array of byte, string)
{
	b := array[n] of byte;
	if(sys->pread(data, b, n, big reg) != n)
		return (nil, sys->sprint("i2c%s: read %d at %#x: %r", bus, n, reg));
	return (b, nil);
}

put(reg, v: int): string
{
	b := array[] of {byte v};
	if(sys->pwrite(data, b, 1, big reg) != 1)
		return sys->sprint("i2c%s: write %#x: %r", bus, reg);
	return nil;
}

u16(b: array of byte, o: int): int
{
	return int b[o] | (int b[o+1] << 8);
}

s16(b: array of byte, o: int): int
{
	return sext(u16(b, o), 16);
}

sext(v, bits: int): int
{
	if(v & (1 << (bits-1)))
		v -= 1 << bits;
	return v;
}

toint(s: string): (int, string)
{
	if(len s <= 2 || s[0:2] != "0x")
		return (int s, nil);
	v := 0;
	for(i := 2; i < len s; i++){
		c := s[i];
		case c {
		'0' to '9' =>	v = v*16 + c - '0';
		'a' to 'f' =>	v = v*16 + c - 'a' + 10;
		'A' to 'F' =>	v = v*16 + c - 'A' + 10;
		* =>	return (0, "bad address");
		}
	}
	return (v, nil);
}

mkdir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

getuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "inferno";
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "inferno";
	return string b[0:n];
}

fail(why: string)
{
	sys->fprint(sys->fildes(2), "envsrv: %s\n", why);
	raise "fail:" + why;
}
