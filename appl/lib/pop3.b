implement Pop3;

#
# POP3 client (RFC 1939), in clear on port 110 or over TLS on port 995.
#
# The connection is mailconn(2)'s.  TLS is the tree's client (tls(2)):
# the server's chain is verified against the system's roots and its name
# against the certificate.  It was the SSL 3.0 client, which a server
# with no key or certificate could finish a handshake with, and to which
# USER and PASS were then sent.  Every reply has a deadline and a bound;
# a connection that fails is closed.
#

include "sys.m";
	sys : Sys;
include "draw.m";
include "pop3.m";
include "keyring.m";
include "tls.m";
include "mailconn.m";
	mailconn: Mailconn;
	Link: import mailconn;

MAXLINE: con 64*1024;			# a reply's or a message's line
MAXMSG: con 64*1024*1024;		# a message
MAXLIST: con 1000000;			# entries of a listing

c: ref Link;
conn : int = 0;
iotime := 30*1000;

timeout(ms: int)
{
	if(ms > 0)
		iotime = ms;
}

open(user, password, server : string, usessl: int): (int, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(mailconn == nil){
		m := load Mailconn Mailconn->PATH;
		if(m == nil)
			return (-1, "cannot load Mailconn");
		ierr := m->init();
		if(ierr != nil)
			return (-1, ierr);
		mailconn = m;
	}
	if (conn)
		return (-1, "connection is already open");
	if(badarg(user) || badarg(password))
		return (-1, "a line break or NUL in the user name or password");
	# server is a host, or host!port for a port of its own
	port := "110";
	how := Mailconn->CLEAR;
	if(usessl){
		# the certificate is checked against the server's name, which
		# a name for the connection server to look up ($pop3) is not
		if (server == nil || server[0] == '$')
			return (-1, "TLS needs the server's name");
		port = "995";
		how = Mailconn->IMPLICIT;
	}else if (server == nil)
		server = defaultserver();
	for(i := 0; i < len server; i++)
		if(server[i] == '!'){
			port = server[i+1:];
			server = server[0:i];
			break;
		}
	addr := "tcp!" + server + "!" + port;
	(nc, derr) := Link.dial(addr, server, how, nil, iotime);
	if(derr != nil){
		if(derr == "timed out")
			derr = "connecting to " + server + " timed out";
		return (-1, derr);
	}
	c = nc;
	(ok, s) := mread();
	if (ok >= 0 && !isok(s))
		(ok, s) = (-1, "greeting: " + s);
	if (ok < 0)
		return (-1, teardown(s));
	(ok, s) = mcmd("USER " + user);
	if (ok < 0)
		return (-1, teardown(s));
	(ok, s) = mcmd("PASS " + password);
	if (ok < 0)
		# a server may say back what it was sent
		return (-1, teardown(redact(s, password)));
	conn = 1;
	return (1, nil);
}

stat() : (int, string, int, int)
{
	if (!conn)
		return (-1, "not connected", 0, 0);
	(ok, s) := mcmd("STAT");
	if (ok < 0)
		return (-1, s, 0, 0);
	(n, ls) := sys->tokenize(s, " ");
	if (n >= 3)
		return (1, nil, int hd tl ls, int hd tl tl ls);
	return (-1, "stat failed", 0, 0);
}

uidl(m: int) : (int, string)
{
	if (!conn)
		return (-1, "not connected");
	(ok, s) := mcmd(sys->sprint("UIDL %d", m));
	if (ok < 0)
		return (-1, s);
	(n, ls) := sys->tokenize(s, " ");
	if (n == 3)
		return (1, hd tl tl ls);
	return (-1, s);
}

# The lines of a listing after its +OK, to the "." that ends it: each
# two fields.
listing(cmd: string): (int, string, list of (string, string))
{
	ls : list of (string, string);

	if (!conn)
		return (-1, "not connected", nil);
	(ok, s) := mcmd(cmd);
	if (ok < 0)
		return (-1, s, nil);
	for (n := 0; ; n++) {
		(ok, s) = mread();
		if (ok < 0)
			return (-1, s, nil);
		if (s == ".")
			break;
		if (n >= MAXLIST)
			return (-1, teardown("the server's list is longer than is taken"), nil);
		(nf, sl) := sys->tokenize(s, " ");
		if (nf != 2)
			return (-1, teardown("bad list format"), nil);
		ls = (hd sl, hd tl sl) :: ls;
	}
	rl : list of (string, string);
	for ( ; ls != nil; ls = tl ls)
		rl = hd ls :: rl;
	return (1, nil, rl);
}
	
msglist() : (int, string, list of (int, int))
{
	(ok, s, l) := listing("LIST");
	if (ok < 0)
		return (-1, s, nil);
	ls, rl : list of (int, int);
	for ( ; l != nil; l = tl l) {
		(a, b) := hd l;
		ls = (int a, int b) :: ls;
	}
	for ( ; ls != nil; ls = tl ls)
		rl = hd ls :: rl;
	return (1, nil, rl);
}

uidllist() : (int, string, list of (int, string))
{
	(ok, s, l) := listing("UIDL");
	if (ok < 0)
		return (-1, s, nil);
	ls, rl : list of (int, string);
	for ( ; l != nil; l = tl l) {
		(a, b) := hd l;
		ls = (int a, b) :: ls;
	}
	for ( ; ls != nil; ls = tl ls)
		rl = hd ls :: rl;
	return (1, nil, rl);
}

msgnolist() : (int, string, list of int)
{
	(ok, s, l) := listing("LIST");
	if (ok < 0)
		return (-1, s, nil);
	ls, rl : list of int;
	for ( ; l != nil; l = tl l) {
		(a, nil) := hd l;
		ls = int a :: ls;
	}
	for ( ; ls != nil; ls = tl ls)
		rl = hd ls :: rl;
	return (1, nil, rl);
}

top(m : int) : (int, string, string)
{
	if (!conn)
		return (-1, "not connected", nil);
	(ok, s) := mcmd("TOP " + string m + " 1");
	if (ok < 0)
		return (-1, s, nil);
	return getbdy();
}

get(m : int) : (int, string, string)
{
	if (!conn)
		return (-1, "not connected", nil);
	(ok, s) := mcmd("RETR " + string m);
	if (ok < 0)
		return (-1, s, nil);
	return getbdy();
}

# A message's lines after +OK, to the "." that ends them, their dots
# unstuffed.  They are gathered in pieces, not one string added to a
# line at a time.
getbdy() : (int, string, string)
{
	parts : list of array of byte;
	b := "";
	n := 0;

	for (;;) {
		(ok, s) := mread();
		if (ok < 0)
			return (-1, s, nil);
		if (s == ".")
			break;
		if (len s > 1 && s[0] == '.' && s[1] == '.')
			s = s[1:];
		b += s + "\n";
		if (len b > 64*1024) {
			a := array of byte b;
			n += len a;
			if (n > MAXMSG)
				return (-1, teardown("the message is longer than is taken"), nil);
			parts = a :: parts;
			b = "";
		}
	}
	a := array of byte b;
	n += len a;
	whole := array[n] of byte;
	whole[n - len a:] = a;
	n -= len a;
	for ( ; parts != nil; parts = tl parts) {
		p := hd parts;
		n -= len p;
		whole[n:] = p;
	}
	return (1, nil, string whole);
}

fetch(dir: string, m: int): (int, string)
{
	if (!conn)
		return (-1, "not connected");
	# The file is named by the server's unique id only if that is a
	# file's name: with a slash in it, it was a path to anywhere.
	f := dir + "/" + string m;
	(ok, s) := uidl(m);
	if(ok == 1 && safename(s))
		f = dir + "/" + s;
	
	msg : string;
	(ok, s, msg) = get(m);
	if (ok < 0)
		return (-1, s);
	fd := sys->create(f, Sys->OWRITE, 8r600);
	if (fd == nil) 
		return (-1, sys->sprint("could not create '%s': %r", f));
	b := array of byte msg;
	if(sys->write(fd, b, len b) != len b) {
		e := sys->sprint("could not write '%s': %r", f);
		sys->remove(f);
		return (-1, e);
	}
	return (1, nil);
}

safename(s: string): int
{
	if(s == nil || s == "." || s == ".." || len s > 255)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] <= ' ' || s[i] == '/' || s[i] == 16r7F)
			return 0;
	return 1;
}
	
delete(m : int) : (int, string)
{
	if (!conn)
		return (-1, "not connected");
	return mcmd("DELE " + string m);
}

# QUIT is what makes the server remove deleted messages (RFC 1939 6):
# its answer is read, and the close fails without it.
close(): (int, string)
{
	if (!conn)
		return (-1, "connection not open");
	t := iotime;
	if(iotime > 10000)
		iotime = 10000;
	(ok, s) := mcmd("QUIT");
	iotime = t;
	teardown(nil);
	if (ok < 0)
		return (-1, "failed to close connection: " + s);
	return (1, nil);
}

# The session is over: the connection closed and its processes gone.  A
# failed open and a timeout used to leave them, and a session that had
# timed out was written to again.
teardown(why: string): string
{
	if(c != nil)
		c.close();
	c = nil;
	conn = 0;
	return why;
}

# A line from the server, within the deadline.
mread() : (int, string)
{
	if(c == nil)
		return (-1, "not connected");
	c.deadline(iotime, 0);
	(line, err) := c.getline(MAXLINE);
	if(err != nil){
		if(err == "timed out")
			err = "pop3 timed out";
		return (-1, teardown(err));
	}
	return (1, line);
}
 
mcmd(s : string) : (int, string)
{
	if(c == nil)
		return (-1, "not connected");
	c.deadline(iotime, 0);
	werr := c.write(array of byte (s + "\r\n"));
	if (werr != nil)
		return (-1, teardown(err(s) + " send failed: " + werr));
	(ok, r) := mread();
	if (ok < 0)
		return (-1, err(s) + " receive failed (" + r + ")");
	if (isok(r))
		return (1, r);
	return (-1, r);
}

# A positive reply is "+OK" (RFC 1939 3), not any line beginning "+".
isok(r: string): int
{
	return len r >= 3 && r[0:3] == "+OK";
}

badarg(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\r' || s[i] == '\n' || s[i] == 0)
			return 1;
	return 0;
}

redact(s, secret: string): string
{
	if(len secret == 0)
		return s;
	for(i := 0; i + len secret <= len s; i++)
		if(s[i:i+len secret] == secret){
			s = s[0:i] + "[...]" + s[i+len secret:];
			i += 4;
		}
	return s;
}

defaultserver() : string
{
	return "$pop3";
}

# The command's name, for an error: never what follows it (PASS's
# password).
err(s : string) : string
{
	for (i := 0; i < len s; i++)
		if (s[i] == ' ' || s[i] == ':')
			return s[0:i];
	return s;
}
