implement Wiki9pSecurityProbe;

#
# Probe used by tests/inferno/wiki9p_security.sh after wiki9p is mounted.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Wiki9pSecurityProbe: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

MNT: con "/tmp/wiki9p-security";

ctl(cmd: string): string
{
	fd := sys->open(MNT + "/ctl", Sys->ORDWR);
	if(fd == nil)
		fail(sys->sprint("open ctl failed: %r"));

	b := array of byte cmd;
	if(sys->write(fd, b, len b) < 0)
		fail(sys->sprint("write ctl failed: %r"));

	sys->sleep(250);
	return readall(fd);
}

readall(fd: ref Sys->FD): string
{
	result := "";
	buf := array[8192] of byte;
	off := big 0;
	for(;;) {
		n := sys->pread(fd, buf, len buf, off);
		if(n <= 0)
			break;
		result += string buf[0:n];
		off += big n;
	}
	return result;
}

check(label, cmd, want: string)
{
	r := ctl(cmd);
	if(!hassubstr(r, "error") || !hassubstr(r, want))
		fail(label + ": got '" + r + "'");
}

hassubstr(s, sub: string): int
{
	if(s == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return 1;
	}
	return 0;
}

fail(msg: string)
{
	sys->print("WIKI9P-SECURITY FAIL: %s\n", msg);
	raise "fail:wiki9p-security";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	check("external ingest path", "ingest /tmp/secret", "under " + MNT + "/raw");
	check("raw traversal", "ingest " + MNT + "/raw/../secret", "unsafe");
	check("control-delimited path", "ingest " + MNT + "/raw/file\nlint", "control");

	sys->print("WIKI9P-SECURITY PASS\n");
}
