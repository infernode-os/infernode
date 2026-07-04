implement Samengine;

#
# Native Dis sam engine — Phase 1 skeleton.
#
# This is the "host" half of the sam split, ported to run inside Inferno
# instead of shelling out to a host `sam -R` binary over the #C command
# device.  It reads the terminal's T* messages and replies with H*
# messages using the wire framing defined by samstub:
#
#	[mtype:1][mcount:2 little-endian][mdata:mcount]
#
# Phase 1 completes only the version handshake and logs everything else.
# The command window, file display (rasp/Hgrow/Hdata) and the command
# language (reusing acme's Edit subsystem) land in later phases.
#

include "sys.m";
	sys: Sys;
	FD: import Sys;

include "draw.m";

include "samengine.m";

# samterm.m declares the Context/Text/Flayer/Section types that
# samstub.m's signatures reference; the engine only needs them to be
# declared so it can pull in the shared protocol constants below.
include "samterm.m";
	Context, Text, Flayer, Section: import Samterm;

include "samstub.m";
	Tversion, Texit, Hversion, VERSION, DATASIZE: import Samstub;

LOG:	con "samengine.log";
logfd:	ref Sys->FD;

run(io: ref Sys->FD, nil: list of string)
{
	sys = load Sys Sys->PATH;

	logfd = sys->create(LOG, Sys->OWRITE, 8r666);
	if(logfd == nil)
		logfd = sys->fildes(2);
	sys->fprint(logfd, "sam engine started\n");

	hdr := array[3] of byte;
	for(;;){
		if(readn(io, hdr, 3) != 3)
			break;
		mtype := int hdr[0];
		mcount := int hdr[1] | (int hdr[2] << 8);
		if(mcount < 0 || mcount > DATASIZE){
			sys->fprint(logfd, "sam engine: bad count %d\n", mcount);
			break;
		}
		data: array of byte;
		if(mcount > 0){
			data = array[mcount] of byte;
			if(readn(io, data, mcount) != mcount)
				break;
		}

		case mtype {
		Tversion =>
			sys->fprint(logfd, "Tversion -> Hversion %d\n", VERSION);
			sendmsg(io, Hversion, shortbytes(VERSION));
		Texit =>
			sys->fprint(logfd, "Texit -> engine exit\n");
			return;
		* =>
			# Not yet implemented; acknowledged silently for now.
			sys->fprint(logfd, "T msg type=%d count=%d (unhandled)\n", mtype, mcount);
		}
	}
	sys->fprint(logfd, "sam engine: pipe closed, exiting\n");
}

# read exactly n bytes into buf (pipes may return short reads); returns
# the number actually read (< n only at EOF/error).
readn(fd: ref Sys->FD, buf: array of byte, n: int): int
{
	got := 0;
	while(got < n){
		r := sys->read(fd, buf[got:], n - got);
		if(r <= 0)
			return got;
		got += r;
	}
	return got;
}

sendmsg(io: ref Sys->FD, mtype: int, data: array of byte)
{
	n := 0;
	if(data != nil)
		n = len data;
	buf := array[3 + n] of byte;
	buf[0] = byte mtype;
	buf[1] = byte n;
	buf[2] = byte (n >> 8);
	if(n > 0)
		buf[3:] = data;
	sys->write(io, buf, len buf);
}

shortbytes(v: int): array of byte
{
	a := array[2] of byte;
	a[0] = byte v;
	a[1] = byte (v >> 8);
	return a;
}
