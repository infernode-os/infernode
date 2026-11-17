implement Timerec;

#
# timerec name record ...: gpsfs(4)'s time file, scripted, for
# tests/host/timesync_test.sh.  Serves /chan/name; each reading of it
# from its start is the next record of the script, stamped with this
# host's clock as gpsfs stamps a fix's arrival:
#	N	a fix whose time is N seconds from the clock's (sync=yes)
#	same	the record before, again, as a file nothing has rewritten
#	nooffset	a record with no offset=
#	empty	nothing, as the file is before the first fix
# and once the script is done, the last record for ever.  Not a test.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Timerec: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if(len argv < 3) {
		sys->fprint(sys->fildes(2), "usage: timerec name record ...\n");
		raise "fail:usage";
	}
	name := hd tl argv;
	script := tl tl argv;
	sys->bind("#s", "/chan", Sys->MBEFORE);
	fio := sys->file2chan("/chan", name);
	if(fio == nil) {
		sys->fprint(sys->fildes(2), "timerec: /chan/%s: %r\n", name);
		raise "fail:file2chan";
	}
	spawn serve(fio, script);
}

clock(): big
{
	fd := sys->open("/dev/time", Sys->OREAD);
	b := array[32] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return big 0;
	return big string b[0:n];
}

serve(fio: ref Sys->FileIO, script: list of string)
{
	last := "";
	for(;;) alt {
	(off, nil, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		if(off > 0) {
			rc <-= (nil, nil);
			continue;
		}
		if(script != nil) {
			w := hd script;
			script = tl script;
			local := clock();
			case w {
			"same" =>
				;
			"empty" =>
				last = "";
			"nooffset" =>
				last = sys->sprint("time=x gps=%bd local=%bd sync=yes\n", local, local);
			* =>
				o := big w * big 1000000;
				last = sys->sprint("time=x gps=%bd local=%bd offset=%bd sync=yes\n", local + o, local, o);
			}
		}
		rc <-= (array of byte last, nil);
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	}
}
