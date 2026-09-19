implement Lan78stats;

#
# lan78stats: the LAN78xx's own hardware counters, read over USB.
#
#	lan78stats [epN.0]
#
# The part counts what it drops before any driver sees a frame --
# rx dropped frames is the receive FIFO overflowing -- and nothing above
# it can: /net/ether0/stats, ipifc and tcp count only what was handed
# up, so a machine that loses one frame in three hundred to a full FIFO
# reads as lossless from the inside while its TCP peers collapse their
# congestion windows (#633). This asks the part. It is the statistics
# block Linux's lan78xx driver reads (vendor request 0xA2, 47 words);
# the counters run free, so take one reading before a transfer and one
# after.
#
# The control endpoint is exclusive-open and os/init/etherusb.b closes
# it once the kernel data path is bound, which is what lets this open
# it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Lan78stats: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Rvendorin: con 16rC0;
Rgetstats: con 16rA2;
Rvendorout: con 16r40;
Rwritereg: con 16rA0;
Rreadreg: con 16rA1;
Nstat: con 47;

names := array[] of {
	"rx fcs errors", "rx alignment errors", "rx fragment errors", "rx jabber errors",
	"rx undersize", "rx oversize", "rx dropped frames",
	"rx unicast bytes", "rx broadcast bytes", "rx multicast bytes",
	"rx unicast frames", "rx broadcast frames", "rx multicast frames", "rx pause frames",
	"rx 64", "rx 65-127", "rx 128-255", "rx 256-511", "rx 512-1023", "rx 1024-1518", "rx >1518",
	"eee rx lpi transitions", "eee rx lpi time",
	"tx fcs errors", "tx excess deferral", "tx carrier errors", "tx bad bytes",
	"tx single collisions", "tx multiple collisions", "tx excessive collisions", "tx late collisions",
	"tx unicast bytes", "tx broadcast bytes", "tx multicast bytes",
	"tx unicast frames", "tx broadcast frames", "tx multicast frames", "tx pause frames",
};

hex(s: string): int
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d := 0;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		v = (v << 4) | d;
	}
	return v;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	dev := "ep4.0";
	if(args != nil)
		args = tl args;
	if(args != nil && hd args == "reg"){
		# lan78stats reg addr [value]: read, or write, one device
		# register (hex). Lets the receive tuning -- burst cap,
		# bulk-in delay, flow thresholds -- be changed on a live link.
		args = tl args;
		if(args == nil){
			sys->fprint(sys->fildes(2), "usage: lan78stats reg addr [value]\n");
			raise "fail:usage";
		}
		addr := hex(hd args);
		args = tl args;
		cfd := sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
		if(cfd == nil){
			sys->fprint(sys->fildes(2), "lan78stats: %s: %r\n", dev);
			raise "fail:open";
		}
		if(args != nil){
			v := hex(hd args);
			w := array[12] of { byte Rvendorout, byte Rwritereg, byte 0, byte 0,
				byte (addr & 16rFF), byte ((addr >> 8) & 16rFF), byte 4, byte 0,
				byte v, byte (v >> 8), byte (v >> 16), byte (v >> 24) };
			if(sys->write(cfd, w, len w) != len w){
				sys->fprint(sys->fildes(2), "lan78stats: write reg: %r\n");
				raise "fail:write";
			}
		}
		r := array[8] of { byte Rvendorin, byte Rreadreg, byte 0, byte 0,
			byte (addr & 16rFF), byte ((addr >> 8) & 16rFF), byte 4, byte 0 };
		rb := array[4] of byte;
		if(sys->write(cfd, r, len r) != len r || sys->read(cfd, rb, 4) != 4){
			sys->fprint(sys->fildes(2), "lan78stats: read reg: %r\n");
			raise "fail:read";
		}
		sys->print("%.3ux %.8ux\n", addr, int rb[0] | (int rb[1] << 8) | (int rb[2] << 16) | (int rb[3] << 24));
		return;
	}
	if(args != nil)
		dev = hd args;
	fd := sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "lan78stats: %s: %r\n", dev);
		raise "fail:open";
	}
	buf := array[Nstat*4] of byte;
	setup := array[8] of { byte Rvendorin, byte Rgetstats, byte 0, byte 0, byte 0, byte 0,
		byte (len buf & 16rFF), byte ((len buf >> 8) & 16rFF) };
	if(sys->write(fd, setup, len setup) != len setup){
		sys->fprint(sys->fildes(2), "lan78stats: setup: %r\n");
		raise "fail:setup";
	}
	n := sys->read(fd, buf, len buf);
	if(n < 4){
		sys->fprint(sys->fildes(2), "lan78stats: read %d: %r\n", n);
		raise "fail:read";
	}
	for(i := 0; i*4+4 <= n && i < len names; i++){
		v := big buf[i*4] | (big buf[i*4+1] << 8) | (big buf[i*4+2] << 16) | (big buf[i*4+3] << 24);
		if(v != big 0 || i == 6 || i == 13 || i == 37)
			sys->print("%-24s %bd\n", names[i], v);
	}
}
