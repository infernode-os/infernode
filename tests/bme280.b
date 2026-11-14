implement Bme280;

#
# bme280 [-b bus] [-a addr]: one reading of a Bosch BME280 (or BMP280)
# through #J, the board's I2C: the chip's id checked, its calibration
# read, one forced measurement, and a line
#	chip=0x60 addr=0x77 t=23.41 p=1008.62 h=47.3
# temperature in degrees Celsius, pressure in hPa, relative humidity in
# percent (none from a BMP280, chip 0x58). With no -a, 0x76 then 0x77.
# The soak reads the room with it beside the board's own temperature.
#
# The compensation is the datasheet's (BST-BME280-DS002, section 4.2.3,
# the floating-point version), from the trimming values in 0x88-0xA1 and
# 0xE1-0xE7.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Bme280: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Idreg:	con 16rD0;
Ctrlhum:	con 16rF2;
Status:	con 16rF3;
Ctrlmeas:	con 16rF4;
Data:	con 16rF7;

data: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("bme280 [-b bus] [-a addr]");
	bus := "1";
	addrs := 16r76 :: 16r77 :: nil;
	while((c := arg->opt()) != 0)
		case c {
		'b' =>
			bus = arg->earg();
		'a' =>
			(a, nil) := toint(arg->earg());
			addrs = a :: nil;
		* =>
			arg->usage();
		}
	ctl := "#J/i2c" + bus + "ctl";
	dname := "#J/i2c" + bus + "data";
	chip := -1;
	addr := -1;
	for(; addrs != nil; addrs = tl addrs){
		if(sys->fprint(fd(ctl, Sys->OWRITE), "addr %#x", hd addrs) < 0 ||
		   sys->fprint(fd(ctl, Sys->OWRITE), "subaddress 1") < 0)
			fail(sys->sprint("%s: %r", ctl));
		data = sys->open(dname, Sys->ORDWR);
		if(data == nil)
			fail(sys->sprint("%s: %r", dname));
		b := array[1] of byte;
		if(sys->pread(data, b, 1, big Idreg) == 1){
			chip = int b[0];
			addr = hd addrs;
			break;
		}
	}
	if(addr < 0)
		fail("no device answers on i2c" + bus);
	if(chip != 16r60 && chip != 16r58)
		fail(sys->sprint("device at %#x on i2c%s has chip id %#x: not a BME280 (0x60) or BMP280 (0x58)", addr, bus, chip));
	hum := chip == 16r60;

	cal := get(16r88, 26);
	t1 := real u16(cal, 0);
	t2 := real s16(cal, 2);
	t3 := real s16(cal, 4);
	p1 := real u16(cal, 6);
	p := array[10] of real;	# P2..P9 at their own numbers
	for(i := 2; i <= 9; i++)
		p[i] = real s16(cal, 6+2*(i-1));	# P2 at 0x8E ... P9 at 0x9E
	h1, h2, h3, h4, h5, h6: real;
	if(hum){
		h1 = real int cal[25];
		e := get(16rE1, 7);
		h2 = real s16(e, 0);
		h3 = real int e[2];
		h4 = real sext((int e[3] << 4) | (int e[4] & 16rF), 12);
		h5 = real sext((int e[5] << 4) | (int e[4] >> 4), 12);
		h6 = real sext(int e[6], 8);
		put(Ctrlhum, 16r01);		# humidity oversampled once
	}
	put(Ctrlmeas, 16r25);			# temperature and pressure once, forced mode
	for(n := 0; n < 50; n++){
		sys->sleep(10);
		if((int get(Status, 1)[0] & 16r08) == 0)
			break;
	}
	m := get(Data, 8);
	adcp := real ((int m[0] << 12) | (int m[1] << 4) | (int m[2] >> 4));
	adct := real ((int m[3] << 12) | (int m[4] << 4) | (int m[5] >> 4));
	adch := real ((int m[6] << 8) | int m[7]);

	v1 := (adct/16384.0 - t1/1024.0) * t2;
	v2 := (adct/131072.0 - t1/8192.0) * (adct/131072.0 - t1/8192.0) * t3;
	tfine := v1 + v2;
	temp := tfine / 5120.0;

	v1 = tfine/2.0 - 64000.0;
	v2 = v1 * v1 * p[6] / 32768.0;
	v2 = v2 + v1 * p[5] * 2.0;
	v2 = v2/4.0 + p[4] * 65536.0;
	v1 = (p[3] * v1 * v1 / 524288.0 + p[2] * v1) / 524288.0;
	v1 = (1.0 + v1/32768.0) * p1;
	press := 0.0;
	if(v1 != 0.0){
		press = 1048576.0 - adcp;
		press = (press - v2/4096.0) * 6250.0 / v1;
		v1 = p[9] * press * press / 2147483648.0;
		v2 = press * p[8] / 32768.0;
		press = press + (v1 + v2 + p[7]) / 16.0;
	}

	s := sys->sprint("chip=%#x addr=%#x t=%.2f p=%.2f", chip, addr, temp, press/100.0);
	if(hum){
		hh := tfine - 76800.0;
		hh = (adch - (h4*64.0 + h5/16384.0*hh)) * (h2/65536.0 * (1.0 + h6/67108864.0*hh*(1.0 + h3/67108864.0*hh)));
		hh = hh * (1.0 - h1*hh/524288.0);
		if(hh > 100.0)
			hh = 100.0;
		if(hh < 0.0)
			hh = 0.0;
		s += sys->sprint(" h=%.1f", hh);
	}
	sys->print("%s\n", s);
}

fd(name: string, mode: int): ref Sys->FD
{
	f := sys->open(name, mode);
	if(f == nil)
		fail(sys->sprint("%s: %r", name));
	return f;
}

get(reg, n: int): array of byte
{
	b := array[n] of byte;
	if(sys->pread(data, b, n, big reg) != n)
		fail(sys->sprint("read %d at %#x: %r", n, reg));
	return b;
}

put(reg, v: int)
{
	b := array[] of {byte v};
	if(sys->pwrite(data, b, 1, big reg) != 1)
		fail(sys->sprint("write %#x: %r", reg));
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

fail(why: string)
{
	sys->fprint(sys->fildes(2), "bme280: %s\n", why);
	raise "fail:" + why;
}
