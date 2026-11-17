implement Mailconn;

#
# A mail server's connection under deadlines: see mailconn.m.
#
# A connection has three processes: a reader that hands on what arrives,
# a writer that writes what it is given, and a ticker by which the caller
# measures its wait.  The caller never reads or writes the connection
# itself, so it is never the one held by a server that has stopped.
# Closing kills the three and closes the connection.  The reader and
# writer use the TLS connection directly, not through a pipe and two
# more processes: nothing is left blocked on a server that says no more.
#

include "sys.m";
	sys: Sys;

include "keyring.m";

include "tls.m";
	tls: TLS;
	Conn: import tls;

include "mailconn.m";

Tick: con 100;		# ms between looks at the clock
Rawline: con 8192;	# a line of the clear part of a STARTTLS exchange
Rawlines: con 100;	# and how many of them one reply may have

init(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(tls == nil){
		t := load TLS TLS->PATH;
		if(t == nil)
			return sys->sprint("cannot load %s: %r", TLS->PATH);
		err := t->init();
		if(err != nil)
			return "tls init: " + err;
		tls = t;
	}
	return nil;
}

Link.dial(addr, servername: string, how: int, helo: string, ms: int): (ref Link, string)
{
	c := ref Link;
	c.rc = chan of array of byte;
	c.wc = chan of array of byte;
	c.wdone = chan of string;
	c.tick = chan of int;
	c.never = chan of int;
	pidc := chan of int;
	spawn ticker(c.tick, pidc);
	c.tpid = <-pidc;
	c.deadline(0, ms);

	# The dial, the handshake and what precedes it in clear are done by
	# a process of their own, killed at the deadline: none of them has
	# one (a name that does not resolve, a host that does not answer, a
	# handshake left unfinished).
	res := chan[1] of (ref Sys->FD, ref Conn, string);
	spawn dialer(addr, servername, how, helo, res, pidc);
	dpid := <-pidc;
	fd: ref Sys->FD;
	tc: ref Conn;
	err: string;
	for(done := 0; !done; ) alt {
	(fd, tc, err) = <-res =>
		done = 1;
	<-c.tick =>
		if(expired(c)){
			kill(dpid);
			fd = nil;
			err = "timed out";
			done = 1;
		}
	}
	if(fd == nil){
		if(err == nil)
			err = "dial failed";
		c.err = err;
		c.close();
		return (nil, err);
	}
	c.fd = fd;
	c.tc = tc;
	spawn reader(fd, tc, c.rc, pidc);
	c.rpid = <-pidc;
	spawn writer(fd, tc, c.wc, c.wdone, pidc);
	c.wpid = <-pidc;
	c.deadline(0, 0);
	return (c, nil);
}

dialer(addr, servername: string, how: int, helo: string, res: chan of (ref Sys->FD, ref Conn, string), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	{
		res <-= dial0(addr, servername, how, helo);
	} exception e {
	"*" =>
		res <-= (nil, nil, "dial: " + e);
	}
}

dial0(addr, servername: string, how: int, helo: string): (ref Sys->FD, ref Conn, string)
{
	(ok, nc) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, nil, sys->sprint("dial %s: %r", addr));
	fd := nc.dfd;
	err: string;
	case how {
	CLEAR =>
		return (fd, nil, nil);
	IMPLICIT =>
		err = nil;
	IMAPSTARTTLS =>
		err = imapstarttls(fd);
	SMTPSTARTTLS =>
		err = smtpstarttls(fd, servername, helo);
	* =>
		err = "unknown connection mode";
	}
	if(err != nil)
		return (nil, nil, err);
	# The tree's TLS client, as webclient(2) configures it: the chain
	# verified against the system's roots, the name against the
	# certificate.
	cfg := tls->defaultconfig();
	cfg.servername = servername;
	(tc, terr) := tls->client(fd, cfg);
	if(terr != nil) {
		if(len terr < 4 || terr[0:4] != "tls:")
			terr = "tls: " + terr;
		if(how == IMPLICIT)
			return (nil, nil, "tlsdial: " + terr);
		return (nil, nil, "STARTTLS: " + terr);
	}
	return (fd, tc, nil);
}

# IMAP's greeting and STARTTLS (RFC 3501 6.2.1) in clear, then TLS on the
# same connection.  A server refusing it is refused: no LOGIN in clear.
imapstarttls(fd: ref Sys->FD): string
{
	(greeting, gerr) := rawline(fd);
	if(gerr != nil)
		return "greeting: " + gerr;
	if(!hasprefix(greeting, "* OK"))
		return "bad greeting: " + greeting;
	if(rawwrite(fd, "S000 STARTTLS") < 0)
		return sys->sprint("STARTTLS write: %r");
	for(n := 0; ; n++) {
		if(n >= Rawlines)
			return "STARTTLS: too many lines before its answer";
		(line, err) := rawline(fd);
		if(err != nil)
			return "STARTTLS: " + err;
		if(hasprefix(line, "S000 ")) {
			if(!hasprefix(line, "S000 OK"))
				return "STARTTLS refused: " + line[5:];
			break;
		}
	}
	return nil;
}

# RFC 3207 in clear: the greeting, EHLO, STARTTLS offered and taken; then
# TLS on the same connection.  A server not offering it, or refusing it,
# is refused: nothing is sent in clear but EHLO and STARTTLS.
smtpstarttls(fd: ref Sys->FD, host, helo: string): string
{
	(code, lines, err) := rawreply(fd);
	if(err != nil)
		return "greeting: " + err;
	if(code != 220)
		return "greeting: " + hd lines;
	if(rawwrite(fd, "EHLO " + helo) < 0)
		return sys->sprint("EHLO: %r");
	(code, lines, err) = rawreply(fd);
	if(err != nil)
		return "EHLO: " + err;
	if(code != 250)
		return "EHLO: " + hd lines;
	offered := 0;
	for(l := lines; l != nil; l = tl l)
		if(len hd l >= 12 && tolower((hd l)[4:12]) == "starttls")
			offered = 1;
	if(!offered)
		return "STARTTLS not offered by " + host;
	if(rawwrite(fd, "STARTTLS") < 0)
		return sys->sprint("STARTTLS: %r");
	(code, lines, err) = rawreply(fd);
	if(err != nil)
		return "STARTTLS: " + err;
	if(code != 220)
		return "STARTTLS refused: " + hd lines;
	return nil;
}

# An SMTP reply, its lines "250-..." to the last "250 ...": its code and
# lines.  Three digits begin each; a reply has so many lines and no more.
rawreply(fd: ref Sys->FD): (int, list of string, string)
{
	lines: list of string;
	for(n := 0; ; n++) {
		if(n >= Rawlines)
			return (0, nil, "reply of too many lines");
		(line, err) := rawline(fd);
		if(err != nil)
			return (0, nil, err);
		if(len line < 3 || !isdigit(line[0]) || !isdigit(line[1]) || !isdigit(line[2]))
			return (0, nil, "malformed reply");
		lines = line :: lines;
		if(len line == 3 || line[3] != '-'){
			rl: list of string;
			for(; lines != nil; lines = tl lines)
				rl = hd lines :: rl;
			return (int line[0:3], rl, nil);
		}
	}
}

# A line read a byte at a time, so that nothing after it is taken from
# the connection: after STARTTLS's answer comes the TLS handshake.
rawline(fd: ref Sys->FD): (string, string)
{
	line := array[Rawline] of byte;
	n := 0;
	b := array[1] of byte;
	for(;;) {
		if(sys->read(fd, b, 1) != 1)
			return (nil, "connection closed");
		if(b[0] == byte '\n')
			break;
		if(n >= len line)
			return (nil, "line too long");
		line[n++] = b[0];
	}
	if(n > 0 && line[n-1] == byte '\r')
		n--;
	return (string line[0:n], nil);
}

rawwrite(fd: ref Sys->FD, s: string): int
{
	b := array of byte (s + "\r\n");
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

Link.deadline(c: self ref Link, idlems, totalms: int)
{
	c.idle = idlems;
	c.total = totalms;
	c.t0 = c.tlast = sys->millisec();
}

expired(c: ref Link): int
{
	now := sys->millisec();
	if(c.total > 0 && now - c.t0 >= c.total)
		return 1;
	if(c.idle > 0 && now - c.tlast >= c.idle)
		return 1;
	return 0;
}

Link.getline(c: self ref Link, max: int): (string, string)
{
	return c.waitline(max, nil);
}

Link.waitline(c: self ref Link, max: int, stop: chan of int): (string, string)
{
	if(c.err != nil)
		return (nil, c.err);
	seen := 0;	# bytes from rp already looked at
	for(;;){
		for(i := c.rp + seen; i < c.wp; i++)
			if(c.buf[i] == byte '\n'){
				e := i;
				if(e > c.rp && c.buf[e-1] == byte '\r')
					e--;
				if(e - c.rp > max)
					return (nil, fail(c, "line too long"));
				s := string c.buf[c.rp:e];
				c.rp = i+1;
				return (s, nil);
			}
		seen = c.wp - c.rp;
		if(seen > max+1)
			return (nil, fail(c, "line too long"));
		err := fill(c, stop);
		if(err != nil)
			return (nil, err);
	}
}

Link.getbytes(c: self ref Link, n: int): (array of byte, string)
{
	if(c.err != nil)
		return (nil, c.err);
	if(n < 0)
		return (nil, "negative count");
	# The array grows with what has come: a server's count takes no
	# memory until its bytes do.
	size := n;
	if(size > 64*1024)
		size = 64*1024;
	out := array[size] of byte;
	have := 0;
	for(;;){
		avail := c.wp - c.rp;
		if(avail > n - have)
			avail = n - have;
		if(avail > 0){
			if(have + avail > len out){
				size = 2 * len out;
				if(size < have + avail)
					size = have + avail;
				if(size > n)
					size = n;
				nout := array[size] of byte;
				nout[0:] = out[0:have];
				out = nout;
			}
			out[have:] = c.buf[c.rp:c.rp+avail];
			c.rp += avail;
			have += avail;
		}
		if(have >= n)
			break;
		err := fill(c, nil);
		if(err != nil)
			return (nil, err);
	}
	return (out[0:n], nil);
}

Link.write(c: self ref Link, b: array of byte): string
{
	if(c.err != nil)
		return c.err;
	c.tlast = sys->millisec();
	c.wc <-= b;
	for(;;) alt {
	e := <-c.wdone =>
		if(e != nil)
			return fail(c, e);
		c.tlast = sys->millisec();
		return nil;
	<-c.tick =>
		if(expired(c))
			return fail(c, "timed out");
	}
}

Link.close(c: self ref Link)
{
	kill(c.rpid);
	kill(c.wpid);
	kill(c.tpid);
	c.rpid = c.wpid = c.tpid = 0;
	if(c.tc != nil)
		spawn tlsclose(c.tc);
	c.tc = nil;
	c.fd = nil;
	c.buf = nil;
	c.rp = c.wp = 0;
	if(c.err == nil)
		c.err = "not connected";
}

fail(c: ref Link, why: string): string
{
	if(c.err == nil)
		c.err = why;
	c.close();
	return c.err;
}

# Wait for more from the reader: nil when some has come.
fill(c: ref Link, stop: chan of int): string
{
	nodeadline := stop != nil;
	if(stop == nil)
		stop = c.never;
	for(;;) alt {
	b := <-c.rc =>
		if(b == nil)
			return fail(c, "connection closed");
		n := len b;
		if(c.buf == nil || c.wp + n > len c.buf){
			live := c.wp - c.rp;
			size := len c.buf;
			if(size < 32*1024)
				size = 32*1024;
			while(live + n > size)
				size *= 2;
			nb := array[size] of byte;
			if(live > 0)
				nb[0:] = c.buf[c.rp:c.wp];
			c.buf = nb;
			c.rp = 0;
			c.wp = live;
		}
		c.buf[c.wp:] = b;
		c.wp += n;
		c.tlast = sys->millisec();
		return nil;
	<-c.tick =>
		if(!nodeadline && expired(c))
			return fail(c, "timed out");
	<-stop =>
		return STOPPED;
	}
}

reader(fd: ref Sys->FD, tc: ref Conn, rc: chan of array of byte, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		buf := array[16*1024] of byte;
		n: int;
		{
			if(tc != nil)
				n = tc.read(buf, len buf);
			else
				n = sys->read(fd, buf, len buf);
		} exception {
		"*" =>
			n = -1;
		}
		if(n <= 0){
			rc <-= nil;
			return;
		}
		rc <-= buf[0:n];
	}
}

writer(fd: ref Sys->FD, tc: ref Conn, wc: chan of array of byte, wdone: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		b := <-wc;
		e: string;
		{
			n: int;
			if(tc != nil)
				n = tc.write(b, len b);
			else
				n = sys->write(fd, b, len b);
			if(n != len b)
				e = sys->sprint("write failed: %r");
		} exception x {
		"*" =>
			e = "write failed: " + x;
		}
		wdone <-= e;
	}
}

# A TLS connection's close says so to the server, which may not be
# listening: it is not waited for.
tlsclose(tc: ref Conn)
{
	{
		tc.close();
	} exception {
	"*" =>
		;
	}
}

ticker(tick: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(Tick);
		tick <-= 1;
	}
}

kill(pid: int)
{
	if(pid <= 0)
		return;
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

tolower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}
