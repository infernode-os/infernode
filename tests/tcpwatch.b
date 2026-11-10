implement Tcpwatch;

#
# tcpwatch: print each change of state of the TCP conversations whose
# remote address holds a string, with the milliseconds since it began,
# for a number of seconds.  To see which end ends a connection, and how
# (Finwait1: this end closed; Close_wait: the far end did; straight to
# Closed: aborted here).  Not a test.
#
#	tcpwatch secs pattern
#

include "sys.m";
	sys: Sys;
include "draw.m";

Tcpwatch: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(len args != 3){
		sys->fprint(sys->fildes(2), "usage: tcpwatch secs pattern\n");
		raise "fail:usage";
	}
	secs := int hd tl args;
	pat := hd tl tl args;
	last := array[1024] of string;
	t0 := sys->millisec();
	while(sys->millisec() - t0 < secs*1000){
		fd := sys->open("/net/tcp", Sys->OREAD);
		if(fd == nil)
			break;
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++){
				c := int d[i].name;
				if(c < 0 || c >= len last || d[i].name[0] < '0' || d[i].name[0] > '9')
					continue;
				r := readfile("/net/tcp/" + d[i].name + "/remote");
				if(!contains(r, pat))
					continue;
				st := readfile("/net/tcp/" + d[i].name + "/status");
				(nil, w) := sys->tokenize(st, " \t\n");
				s := "";
				if(w != nil)
					s = hd w;
				if(s != last[c]){
					sys->print("%d tcp/%d %s %s -> %s\n", sys->millisec() - t0, c, chomp(r), last[c], s);
					last[c] = s;
				}
			}
		}
		sys->sleep(20);
	}
}

contains(s, p: string): int
{
	for(i := 0; i + len p <= len s; i++)
		if(s[i:i+len p] == p)
			return 1;
	return 0;
}

chomp(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		return s[0:len s - 1];
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}
