implement Twofa;

#
# Twofa — Limbo wrapper over the #F (2fa) device. See module/twofa.m and
# doc/second-factor-auth.md.
#
include "sys.m";
	sys: Sys;
include "twofa.m";

init()
{
	sys = load Sys Sys->PATH;
}

mount(): string
{
	(ok, nil) := sys->stat(Dev);
	if(ok < 0){
		fd := sys->create(Dev, Sys->OREAD, Sys->DMDIR | 8r700);
		if(fd == nil)
			return sys->sprint("cannot create %s: %r", Dev);
		fd = nil;
	}
	if(sys->bind("#F", Dev, Sys->MREPL) < 0)
		return sys->sprint("bind #F %s: %r", Dev);
	return nil;
}

# read a whole synthetic file (small) -> (contents, error)
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", path));
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return (nil, sys->sprint("read %s: %r", path));
	return (string buf[0:n], nil);
}

strip(s: string): string
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

hasstr(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

hexc(v: int): int
{
	if(v < 10)
		return v + '0';
	return v - 10 + 'a';
}

tohex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++){
		s[len s] = hexc((int a[i] >> 4) & 16rf);
		s[len s] = hexc(int a[i] & 16rf);
	}
	return s;
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

fromhex(s: string): array of byte
{
	if((len s & 1) != 0)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		hi := hexv(s[2*i]);
		lo := hexv(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte((hi << 4) | lo);
	}
	return a;
}

available(): int
{
	(s, err) := readfile(Dev + "/providers");
	if(err != nil)
		return 0;
	return hasstr(s, "available=1");
}

enroll(pin: string): (string, string)
{
	fd := sys->open(Dev + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return (nil, sys->sprint("open ctl: %r"));
	cmd := "enroll";
	if(pin != nil && pin != "")
		cmd += " " + pin;
	b := array of byte cmd;
	if(sys->write(fd, b, len b) < 0)		# blocks on touch (+PIN if UV)
		return (nil, sys->sprint("enroll: %r"));
	fd = nil;
	(cred, err) := readfile(Dev + "/cred");
	if(err != nil)
		return (nil, err);
	cred = strip(cred);
	if(cred == nil)
		return (nil, "enroll produced no credential");
	return (cred, nil);
}

derive(cred: string, salt: array of byte, pin: string): (array of byte, string)
{
	if(len salt != 32)
		return (nil, "salt must be 32 bytes");
	if(cred == nil || cred == "")
		return (nil, "no credential id");
	fd := sys->open(Dev + "/derive", Sys->OWRITE);
	if(fd == nil)
		return (nil, sys->sprint("open derive: %r"));
	cmd := cred + " " + tohex(salt);
	if(pin != nil && pin != "")
		cmd += " " + pin;
	b := array of byte cmd;
	if(sys->write(fd, b, len b) < 0)		# blocks on touch (+PIN if UV)
		return (nil, sys->sprint("derive: %r"));
	fd = nil;
	(sec, err) := readfile(Dev + "/derive");
	if(err != nil)
		return (nil, err);
	raw := fromhex(strip(sec));
	if(raw == nil)
		return (nil, "derive returned malformed secret");
	return (raw, nil);
}
