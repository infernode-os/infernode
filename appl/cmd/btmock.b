implement Btmockcmd;

#
# btmock - a fake Bluetooth controller as a file
#
# Serves btmock(2) at /chan/btmock (or the path given) through
# file2chan: bytes written are H4 commands, bytes read are the
# controller's answers, so
#
#   btmock &
#   bt9p -t /chan/btmock
#
# gives a bt9p with a controller that answers, on a machine with no
# radio and no kernel. That is what tests/inferno/bt_ns_test.sh drives
# to check the /net/bt contract, and what anyone developing above bt9p
# can run in hosted emu.
#
# A second file, <path>ctl, is the far side's telephone: writing
# "call <addr> <psm> <text>" makes the nearby device addr connect to
# the host and send text on psm once the L2CAP channel is up; reading
# it lists what the peers received on their channels, one "recv <addr>
# <psm> <text>" per line. Every nearby device also answers L2CAP
# connections to PSM 0x1001 by echoing whatever it is sent.
#
# Usage:
#   btmock [-a addr] [-n 'addr class rssi name']... [-s] [-t ms] [path]
#     -a   the controller's BD_ADDR (default b8:27:eb:00:00:01)
#     -n   a device an inquiry finds; repeatable. A fifth word makes it
#          demand pairing before it connects: pin=NNNN for a legacy PIN,
#          ssp for Secure Simple Pairing (numeric comparison, 123456)
#     -s   stingy: withhold command credits and refund them on the tick
#     -t   the tick, in ms (default 200): one inquiry result per tick
#     -H   write a small .hcd patch file there, for exercising bt9p's
#          firmware upload against this controller
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bthci.m";
	bthci: Bthci;
	Found: import bthci;
include "l2cap.m";
	l2cap: L2cap;
include "rfcomm.m";
include "btmock.m";
	btmock: Btmock;
	Ctlr: import btmock;

Btmockcmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	bthci = load Bthci Bthci->PATH;
	btmock = load Btmock Btmock->PATH;
	l2cap = load L2cap L2cap->PATH;
	if(arg == nil || bthci == nil || btmock == nil || l2cap == nil){
		sys->fprint(stderr, "btmock: cannot load modules: %r\n");
		raise "fail:load";
	}
	bthci->init();
	l2cap->init(bthci);
	btmock->init(bthci, l2cap);

	addr := "b8:27:eb:00:00:01";
	nearby: list of ref Found;
	auth: list of (string, string);
	stingy := 0;
	tickms := 200;
	arg->init(args);
	hcd := "";
	arg->setusage("btmock [-a addr] [-n 'addr class rssi name']... [-s] [-t ms] [-H hcdfile] [path]");
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	addr = arg->earg();
		'n' =>
			(nf, f) := sys->tokenize(arg->earg(), " ");
			if(nf < 3)
				arg->usage();
			nm := "";
			if(nf > 3)
				nm = hd tl tl tl f;
			if(nf > 4)
				auth = (hd f, hd tl tl tl tl f) :: auth;
			(cls, nil) := hexint(hd tl f);
			nearby = ref Found(hd f, cls, int hd tl tl f, nm, -1) :: nearby;
		's' =>	stingy = 1;
		't' =>	tickms = int arg->earg();
		'H' =>	hcd = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	path := "/chan/btmock";
	if(args != nil)
		path = hd args;

	c := Ctlr.new(addr);
	c.nearby = nearby;
	c.auth = auth;
	c.stingy = stingy;

	if(hcd != nil && writehcd(hcd) < 0){
		sys->fprint(stderr, "btmock: %s: %r\n", hcd);
		raise "fail:hcd";
	}

	(dir, file) := splitpath(path);
	# the file lives in a srv device; give the directory one, as ramfile does
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0){
		sys->fprint(stderr, "btmock: bind #s %s: %r\n", dir);
		raise "fail:bind";
	}
	fio := sys->file2chan(dir, file);
	cio := sys->file2chan(dir, file + "ctl");
	pio := sys->file2chan(dir, file + "phone");	# the far end of a relaying phone's channel
	if(fio == nil || cio == nil || pio == nil){
		sys->fprint(stderr, "btmock: file2chan %s: %r\n", path);
		raise "fail:file2chan";
	}
	spawn serve(c, fio, cio, pio, tickms);
}

#
# A patch file with the shape of a real one: two Write_RAM records
# and a Launch_RAM, opcode and length and parameters, no indicators.
#
writehcd(path: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	b := array[] of {
		byte 16r4c, byte 16rfc, byte 8,  byte 0, byte 16r10, byte 0, byte 0, byte 16rde, byte 16rad, byte 16rbe, byte 16ref,
		byte 16r4c, byte 16rfc, byte 6,  byte 4, byte 16r10, byte 0, byte 0, byte 16rca, byte 16rfe,
		byte 16r4e, byte 16rfc, byte 4,  byte 16rff, byte 16rff, byte 16rff, byte 16rff,
	};
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

hexint(s: string): (int, string)
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];
	v := 0;
	for(i := 0; i < len s; i++){
		ch := s[i];
		d := -1;
		if(ch >= '0' && ch <= '9')
			d = ch - '0';
		else if(ch >= 'a' && ch <= 'f')
			d = ch - 'a' + 10;
		else if(ch >= 'A' && ch <= 'F')
			d = ch - 'A' + 10;
		if(d < 0)
			return (v, s[i:]);
		v = (v << 4) | d;
	}
	return (v, nil);
}

splitpath(p: string): (string, string)
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return (p[0:i], p[i+1:]);
	return (".", p);
}

Pending: adt {
	count:	int;
	rc:	Sys->Rread;
};

ticker(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

#
# One process owns the mock. Writes are fed to it and their output
# queued; reads take what is queued or wait; the tick moves time on.
# Reads are served in order and each gets at most what it asked for,
# as a UART would.
#
serve(c: ref Ctlr, fio, cio, pio: ref Sys->FileIO, tickms: int)
{
	tick := chan of int;
	spawn ticker(tick, tickms);
	q := array[0] of byte;
	waiting: list of ref Pending;
	pwaiting: list of ref Pending;

	for(;;){
		alt {
		(nil, data, nil, wc) := <-pio.write =>
			if(wc == nil)
				continue;
			(pout, perr) := c.phonesend(data);
			if(perr != nil)
				wc <-= (0, perr);
			else{
				q = cat(q, pout);
				wc <-= (len data, nil);
			}
		(nil, count, nil, rc) := <-pio.read =>
			if(rc == nil)
				continue;
			pwaiting = appendp(pwaiting, ref Pending(count, rc));
		(nil, data, nil, wc) := <-fio.write =>
			if(wc == nil)
				continue;
			out := c.feed(data);
			q = cat(q, out);
			wc <-= (len data, nil);
		(nil, count, nil, rc) := <-fio.read =>
			if(rc == nil)
				continue;
			waiting = appendp(waiting, ref Pending(count, rc));
		<-tick =>
			q = cat(q, c.tick());
		(nil, data, nil, wc) := <-cio.write =>
			if(wc == nil)
				continue;
			(nf, f) := sys->tokenize(string data, " \t\r\n");
			if(nf >= 3 && hd f == "notify"){
				# notify <addr> <hex bytes>: an LE device's boot report
				rep := array[nf - 2] of byte;
				i := 0;
				for(t := tl tl f; t != nil; t = tl t){
					(v, nil) := hexint("0x" + hd t);
					rep[i++] = byte v;
				}
				err := c.notify(hd tl f, rep);
				if(err != nil)
					wc <-= (0, err);
				else
					wc <-= (len data, nil);
				continue;
			}
			if(nf >= 3 && hd f == "lecall"){
				# lecall <addr> <text>: a phone finds the host, pairs, opens its le9p channel
				ltext := "";
				for(lt := tl tl f; lt != nil; lt = tl lt){
					if(ltext != "")
						ltext += " ";
					ltext += hd lt;
				}
				lerr := c.lecall(hd tl f, ltext);
				if(lerr != nil)
					wc <-= (0, lerr);
				else
					wc <-= (len data, nil);
				continue;
			}
			if(nf < 4 || hd f != "call"){
				wc <-= (0, "usage: call <addr> <psm>|rfcomm<n> <text> | notify <addr> <hex>...");
				continue;
			}
			port := hd tl tl f;
			text := "";
			for(t := tl tl tl f; t != nil; t = tl t){
				if(text != "")
					text += " ";
				text += hd t;
			}
			err: string;
			if(len port > 6 && port[0:6] == "rfcomm")
				err = c.callrf(hd tl f, int port[6:], text);
			else{
				(psm, nil) := hexint(port);
				err = c.call(hd tl f, psm, text);
			}
			if(err != nil)
				wc <-= (0, err);
			else
				wc <-= (len data, nil);
		(off, count, nil, rc) := <-cio.read =>
			if(rc == nil)
				continue;
			s := "";
			for(rl := c.received; rl != nil; rl = tl rl)
				s = hd rl + "\n" + s;
			b := array of byte s;
			if(off >= len b)
				rc <-= (nil, nil);
			else{
				e := off + count;
				if(e > len b)
					e = len b;
				rc <-= (b[off:e], nil);
			}
		}
		# what the phone has received, to whoever reads at its end
		while(pwaiting != nil && len c.phonerx > 0){
			pp := hd pwaiting;
			pwaiting = tl pwaiting;
			pn := pp.count;
			if(pn > len c.phonerx)
				pn = len c.phonerx;
			pb := array[pn] of byte;
			pb[0:] = c.phonerx[0:pn];
			c.phonerx = c.phonerx[pn:];
			pp.rc <-= (pb, nil);
		}
		# satisfy readers, oldest first, while there is anything
		while(waiting != nil && len q > 0){
			p := hd waiting;
			waiting = tl waiting;
			n := p.count;
			if(n > len q)
				n = len q;
			out := array[n] of byte;
			out[0:] = q[0:n];
			q = q[n:];
			p.rc <-= (out, nil);
		}
	}
}

appendp(l: list of ref Pending, p: ref Pending): list of ref Pending
{
	if(l == nil)
		return p :: nil;
	return hd l :: appendp(tl l, p);
}

cat(a, b: array of byte): array of byte
{
	if(len b == 0)
		return a;
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}
