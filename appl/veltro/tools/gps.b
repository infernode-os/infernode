implement ToolGps;

#
# gps - where this machine is, from the GPS receiver at /mnt/gps.
#
# Reads gpsfs(4)'s files: position ("lat lon"), fix (the whole fix,
# attr=value), status, satellites, and event, for waiting for the next
# fix.  Read only: the tool's grant (nsconstruct) binds just those
# five files, never ctl or feed, so an agent can learn where it is but
# cannot choose the receiver or put a position in.
#
# A location is personal data.  The tool is not granted unless asked
# for, as every tool is; what an agent does with the position is
# bounded by its other grants (a location and a way to send it are two
# capabilities, granted separately).
#
# Usage:
#   gps [position]
#   gps fix
#   gps status
#   gps satellites
#   gps wait [seconds]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolGps: module {
	init:	fn(): string;
	name:	fn(): string;
	doc:	fn(): string;
	exec:	fn(args: string): string;
	schema:	fn(): string;
};

GPS: con "/mnt/gps/";
WAIT: con 30;
MAXWAIT: con 300;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "gps";
}

doc(): string
{
	return "Gps - Where this machine is, from its GPS receiver.\n\n" +
		"Usage:\n" +
		"  gps [position]       latitude and longitude, decimal degrees\n" +
		"  gps fix              the whole fix: time lat lon alt speed course mode q sats ...\n" +
		"  gps status           the receiver's state\n" +
		"  gps satellites       satellites in view: system prn elevation azimuth snr used\n" +
		"  gps wait [seconds]   wait for the next fix (default 30, at most 300)\n\n" +
		"Examples:\n" +
		"  gps\n" +
		"  gps fix\n" +
		"  gps wait 10\n\n" +
		"Requires /mnt/gps (gpsfs).";
}

schema(): string
{
	return "{" +
		"\"name\":\"gps\"," +
		"\"description\":\"Where this machine is, from its GPS receiver. " +
			"position gives 'lat lon' in decimal degrees (north and east positive); " +
			"fix gives the whole fix as attr=value fields (time, lat, lon, alt in metres, " +
			"speed in m/s, course in degrees true, mode, sats, err in metres); " +
			"status says whether there is a fix; satellites lists those in view; " +
			"wait waits for the next fix.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\"," +
					"\"description\":\"position (the default), fix, status, satellites, or wait\"}," +
				"\"seconds\":{\"type\":\"string\"," +
					"\"description\":\"for wait: how long to wait, in seconds (default 30, at most 300)\"}" +
			"}" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();
	(n, l) := sys->tokenize(args, " \t\r\n");
	cmd := "position";
	if(n > 0) {
		cmd = hd l;
		l = tl l;
		n--;
	}
	case cmd {
	"position" or "fix" or "status" or "satellites" =>
		if(n != 0)
			return "error: usage: gps " + cmd;
		return readgps(cmd);
	"wait" =>
		secs := WAIT;
		if(n == 1) {
			secs = int hd l;
			if(secs <= 0 || string secs != hd l)
				return "error: bad number of seconds: " + hd l;
			if(secs > MAXWAIT)
				secs = MAXWAIT;
		} else if(n > 1)
			return "error: usage: gps wait [seconds]";
		return wait(secs);
	}
	return "error: unknown command " + cmd + " (position, fix, status, satellites, wait)";
}

readgps(file: string): string
{
	fd := sys->open(GPS + file, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: no GPS receiver: %s%s: %r", GPS, file);
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		r := sys->read(fd, buf, len buf);
		if(r < 0)
			return sys->sprint("error: %r");	# "no fix", from position
		if(r == 0)
			break;
		s += string buf[0:r];
	}
	if(s == "") {
		case file {
		"fix" =>
			return "no fix yet";
		"satellites" =>
			return "no satellites reported";
		}
	}
	return s;
}

# The agent's /prog holds only its own process, so the reader and the
# timer cannot be killed: each sends on a buffered channel and ends by
# itself, the timer when it wakes, a reader left by a timeout when the
# next fix comes.
wait(secs: int): string
{
	fd := sys->open(GPS + "event", Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: no GPS receiver: %sevent: %r", GPS);
	rc := chan[1] of string;
	spawn reader(fd, rc);
	tc := chan[1] of int;
	spawn timer(secs, tc);
	alt {
	s := <-rc =>
		return s;
	<-tc =>
		return sys->sprint("no fix within %d seconds", secs);
	}
}

reader(fd: ref Sys->FD, rc: chan of string)
{
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		rc <-= sys->sprint("error: %r");
	else
		rc <-= string buf[0:n];
}

timer(secs: int, tc: chan of int)
{
	sys->sleep(secs * 1000);
	tc <-= 1;
}
