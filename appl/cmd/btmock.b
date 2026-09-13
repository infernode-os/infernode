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
# Usage:
#   btmock [-a addr] [-n 'addr class rssi name']... [-s] [-t ms] [path]
#     -a   the controller's BD_ADDR (default b8:27:eb:00:00:01)
#     -n   a device an inquiry finds; repeatable
#     -s   stingy: withhold command credits and refund them on the tick
#     -t   the tick, in ms (default 200): one inquiry result per tick
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bthci.m";
	bthci: Bthci;
	Found: import bthci;
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
	if(arg == nil || bthci == nil || btmock == nil){
		sys->fprint(stderr, "btmock: cannot load modules: %r\n");
		raise "fail:load";
	}
	bthci->init();
	btmock->init(bthci);

	addr := "b8:27:eb:00:00:01";
	nearby: list of ref Found;
	stingy := 0;
	tickms := 200;
	arg->init(args);
	arg->setusage("btmock [-a addr] [-n 'addr class rssi name']... [-s] [-t ms] [path]");
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
			(cls, nil) := hexint(hd tl f);
			nearby = ref Found(hd f, cls, int hd tl tl f, nm) :: nearby;
		's' =>	stingy = 1;
		't' =>	tickms = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	path := "/chan/btmock";
	if(args != nil)
		path = hd args;

	c := Ctlr.new(addr);
	c.nearby = nearby;
	c.stingy = stingy;

	(dir, file) := splitpath(path);
	# the file lives in a srv device; give the directory one, as ramfile does
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0){
		sys->fprint(stderr, "btmock: bind #s %s: %r\n", dir);
		raise "fail:bind";
	}
	fio := sys->file2chan(dir, file);
	if(fio == nil){
		sys->fprint(stderr, "btmock: file2chan %s: %r\n", path);
		raise "fail:file2chan";
	}
	spawn serve(c, fio, tickms);
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
serve(c: ref Ctlr, fio: ref Sys->FileIO, tickms: int)
{
	tick := chan of int;
	spawn ticker(tick, tickms);
	q := array[0] of byte;
	waiting: list of ref Pending;

	for(;;){
		alt {
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
