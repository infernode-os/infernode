implement Smtp;
 
include "sys.m";
	sys : Sys;
include "bufio.m";
	bufio : Bufio;
include "smtp.m";
include "encoding.m";
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbentry, Tuples: import attrdb;
include "ip.m";
	ip: IP;
include "ipattr.m";
	ipattr: IPattr;
include "webclient.m";
	webclient: Webclient;

usessl:= 0;

FD, Connection: import sys;
Iobuf : import bufio;

ibuf : ref Bufio->Iobuf;
sfd : ref Sys->FD;	# connection fd; writes go here directly (like imap.b)
conn : int = 0;
init : int = 0;
 
rpid : int = -1;
cread : chan of (int, string);
base64: Encoding;
db: ref Db;
dbfile := "/lib/ndb/local";

DEBUG : con 0;

open(server : string): (int, string)
{
	s : string;
 
	if (!init) {
		sys = load Sys Sys->PATH;
		bufio = load Bufio Bufio->PATH;
		init = 1;
	}
	if (conn)
		return (-1, "connection is already open");
	if (server == nil)
		server = "$smtp";
	(ok, c) := sys->dial ("tcp!" + server + "!25", nil);
	if (ok < 0)
		return (-1, "dialup failed");
 
	sfd = c.dfd;
	ibuf = bufio->fopen(c.dfd, Bufio->OREAD);
	if (ibuf == nil)
		return (-1, "failed to open bufio");
	cread = chan of (int, string);
	spawn mreader(cread);
	(rpid, nil) = <- cread;

 	(ok, s) = mread();
	if (ok < 0)
		return (-1, s);
	conn = 1;
	return (1, nil);
}
 
authopen(user, password, server : string, mode: int): (int, string)
{
	s : string;
	ok: int;

	if (!init) {
		sys = load Sys Sys->PATH;
		bufio = load Bufio Bufio->PATH;
		init = 1;
	}
	if (base64 == nil) {
		base64 = load Encoding Encoding->BASE64PATH;
		attrdb = load Attrdb Attrdb->PATH;
		if(attrdb == nil)
			return (-1, "cannot load Attrdb");
		attrdb->init();
		ip = load IP IP->PATH;
		if(ip == nil)
			return (-1, "cannot load IP");
		ip->init();
		ipattr = load IPattr IPattr->PATH;
		if(ipattr == nil)
			return (-1, "cannot load IPattr");
		ipattr->init(attrdb, ip);
		db = Db.open(dbfile);
	}
	if (webclient == nil) {
		webclient = load Webclient Webclient->PATH;
		if(webclient == nil)
			return (-1, "cannot load Webclient");
		werr := webclient->init();
		if(werr != nil)
			return (-1, "webclient init: " + werr);
	}
	if (conn)
		return (-1, "connection is already open");

	# The password goes in AUTH PLAIN: never in clear.
	port: string;
	case mode {
	IMPLICIT_TLS =>
		port = "465";
	STARTTLS =>
		port = "587";
	PLAIN =>
		return (-1, "authopen: credentials are not sent in clear: use IMPLICIT_TLS or STARTTLS");
	* =>
		return (-1, "authopen: unknown mode " + string mode);
	}
	if (server == nil)
		server = "$smtp";
	# server is a host, or host!port for a port of its own
	(host, p) := split(server, '!');
	if (p != nil)
		port = p;
	addr := "tcp!" + host + "!" + port;
	domain := heloname();

	fd: ref Sys->FD;
	if(mode == IMPLICIT_TLS){
		(tlsfd, terr) := webclient->tlsdial(addr, host);
		if(terr != nil)
			return (-1, "tlsdial: " + terr);
		fd = tlsfd;
	}else{
		(tlsfd, serr) := starttls(addr, host, domain);
		if(serr != nil)
			return (-1, serr);
		fd = tlsfd;
	}
	usessl = 1;
	sfd = fd;
	ibuf = bufio->fopen(fd, Bufio->OREAD);
	if(ibuf == nil)
		return (-1, "failed to open bufio");
	cread = chan of (int, string);
	spawn mreader(cread);
	(rpid, nil) = <- cread;

	if(mode == IMPLICIT_TLS){
		# the greeting; after STARTTLS there is none
		(ok, s) = mread();
		if (ok < 0)
			return (-1, s);
	}
	# EHLO, not HELO: AUTH is an extension (and after STARTTLS the
	# client starts again with EHLO, RFC 3207 4.2)
	(ok, s) = mcmd("EHLO "+domain);
	if(ok < 0)
		return (-1, s);
	(ok, s) = mcmd("AUTH PLAIN");
	if(ok < 0)
		return (-1, s);
	auths := user + "\0" + user + "\0" + password;
	(ok, s) = mcmd(base64->enc(array of byte auths));
	if (ok < 0)
		return (-1, s);

	conn = 1;
	return (1, nil);
}

# The name EHLO gives: the system's domain from ndb, or its name
heloname(): string
{
	hostname := readfile("/dev/sysname");
	(domain, err) := ipattr->findnetattr(db, "sys", hostname, "dom");
	if(err != nil || domain == nil)
		return hostname;
	return domain;
}

# RFC 3207 in clear: the greeting, EHLO, STARTTLS offered and taken,
# read a byte at a time so that nothing of the TLS handshake after
# STARTTLS's 220 is taken; then TLS on the same connection.  A server
# not offering it, or refusing it, is refused: nothing is sent in clear
# but EHLO and STARTTLS.
starttls(addr, host, domain: string): (ref Sys->FD, string)
{
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("dial %s: %r", addr));
	(code, lines, err) := reply(c.dfd);
	if(err != nil)
		return (nil, "greeting: " + err);
	if(code != 220)
		return (nil, "greeting: " + hd lines);
	if(rawwrite(c.dfd, "EHLO " + domain) < 0)
		return (nil, sys->sprint("EHLO: %r"));
	(code, lines, err) = reply(c.dfd);
	if(err != nil)
		return (nil, "EHLO: " + err);
	if(code != 250)
		return (nil, "EHLO: " + hd lines);
	offered := 0;
	for(l := lines; l != nil; l = tl l)
		if(len hd l >= 12 && tolower((hd l)[4:12]) == "starttls")
			offered = 1;
	if(!offered)
		return (nil, "STARTTLS not offered by " + host);
	if(rawwrite(c.dfd, "STARTTLS") < 0)
		return (nil, sys->sprint("STARTTLS: %r"));
	(code, lines, err) = reply(c.dfd);
	if(err != nil)
		return (nil, "STARTTLS: " + err);
	if(code != 220)
		return (nil, "STARTTLS refused: " + hd lines);
	(tlsfd, terr) := webclient->tlsclient(c.dfd, host);
	if(terr != nil)
		return (nil, "STARTTLS: " + terr);
	return (tlsfd, nil);
}

# A reply, its lines "250-..." to the last "250 ...": its code and lines
reply(fd: ref Sys->FD): (int, list of string, string)
{
	lines: list of string;
	for(;;) {
		(line, err) := rawline(fd);
		if(err != nil)
			return (0, nil, err);
		if(len line < 3)
			return (0, nil, "short reply: " + line);
		lines = line :: lines;
		if(len line == 3 || line[3] != '-')
			return (int line[0:3], reverse(lines), nil);
	}
}

# A line read a byte at a time, so that nothing after it is taken
rawline(fd: ref Sys->FD): (string, string)
{
	line := "";
	b := array[1] of byte;
	for(;;) {
		if(sys->read(fd, b, 1) != 1)
			return (nil, "connection closed");
		if(b[0] == byte '\n')
			break;
		if(len line >= 4096)
			return (nil, "line too long");
		line[len line] = int b[0];
	}
	if(len line > 0 && line[len line - 1] == '\r')
		line = line[0:len line - 1];
	if(DEBUG)
		sys->print("smtp: S: %s\n", line);
	return (line, nil);
}

rawwrite(fd: ref Sys->FD, s: string): int
{
	if(DEBUG)
		sys->print("smtp: C: %s\n", s);
	b := array of byte (s + "\r\n");
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

reverse(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

tolower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

sendmail (fromwho : string, towho : list of string, cc : list of string, mlist: list of string): (int, string)
{
	ok : int;
	s, t, line : string;

	if (!conn)
		return (-1, "connection is not open");
	(ok, s) = mcmd("RSET");
	if (ok < 0)
		return (-1, s);
	(user, dom) := split(fromwho, '@');
	if (fromwho == nil || user == nil)
		return (-1, "no 'from' name");
	if (towho == nil)
		return (-1, "no 'to' name");
	if (dom == nil)
		return (-1, "no domain name");
	if(!usessl){
		(ok, s) = mcmd("HELO " + dom);
		if (ok < 0)
			return (-1, s);
	}
	(ok, s) = mcmd("MAIL FROM:<" + fromwho + ">");
	if (ok < 0)
		return (-1, s);
	all := concat(towho, cc);
	t = nil;
	for ( ; all != nil; all = tl all) {
		(ok, s) = mcmd("RCPT TO:<" + hd all + ">");
		if (ok < 0)
			t += " " + s;
	}
	if (t != nil)
		return (-1, t);
	(ok, s) = mcmd("DATA");
	if (ok < 0)
		return (-1, s);
	for ( ; mlist != nil; mlist = tl mlist) {
		for (msg := hd mlist; msg != nil; ) {
			(line, msg) = split(msg, '\n');	# BUG: too much copying for larger messages
			if (putline(line) < 0)
				return (-1, sys->sprint("write to server failed: %r"));
		}
	}
#	obuf.flush();
	(ok, s) = mcmd(".");      
	if (ok < 0)  
		return (-1, s);  
	return (1, nil);
}

putline(line: string): int
{
	ln := len line;
	if (ln > 0 && line[ln-1] == '\r')
		line = line[0:ln-1];
	if (line != nil && line[0] == '.'){
		line = "." + line;
	}
	return mwrite(line);
}

close(): (int, string)
{
	ok : int;
 
	if (!conn)
		return (-1, "connection is not open");
	ok = mwrite("QUIT");
	kill(rpid);
	if(!usessl)
		ibuf.close();
	conn = 0;
	if (ok < 0)
		return (-1, "failed to close connection");
	return (1, nil);
}
 
SLPTIME : con 100;
MAXSLPTIME : con 10000;

mread() : (int, string)
{
	t := 0;
	while (t < MAXSLPTIME) {
		alt {
			(ok, s) := <- cread =>
				return (ok, s);
			* =>
				t += SLPTIME;
				sys->sleep(SLPTIME);
		}
	}
	kill(rpid);
	return (-1, "smtp timed out\n");		
}

mreader(c : chan of (int, string))
{
	c <- = (sys->pctl(0, nil), nil);
	for (;;) {
		line := ibuf.gets('\n');
		if (DEBUG)
			sys->print("mread : %s", line);
		if (line == nil) {
			c <- = (-1, "could not read response from server");
			continue;
		}
		l := len line;
		if (line[l-1] == '\n')
			l--;
		if (line[l-1] == '\r')
			l--;
		if (l < 3) {
			c <- = (-1, "short response from server");
			continue;
		}
		if (l > 3 && line[3] == '-')
			continue;	# a reply's line before its last (EHLO's)
		if (l > 0 && (line[0] == '1' || line[0] == '2' || line[0] == '3')) {
			c <- = (1, nil);
			continue;
		}
		c <- = (-1, line[3:l]);
	}
}
 
mwrite(s : string): int
{
	s += "\r\n";
	if (DEBUG)
		sys->print("mwrite : %s", s);
	b := array of byte s;
	l := len b;
	nb: int;
	# Write straight to the connection fd (TLS is transparent via tlsdial),
	# mirroring imap.b — a second OWRITE bufio on the same fd breaks reads.
	nb = sys->write(sfd, b, len b);
	if (nb != l)
		return -1;
	return 1;
}
 
mcmd(s : string) : (int, string)
{
	ok : int;
	r : string;

	ok = mwrite(s);
	if (ok < 0)
		return (-1, err(s) + " send failed");
	(ok, r) = mread();
	if (ok < 0)
		return (-1, err(s) + " receive failed (" + r + ")");
	return (1, nil);
}

split(s : string, c : int) : (string, string)
{
	for (i := 0; i < len s; i++)
		if (s[i] == c)
			return (s[0:i], s[i+1:]);
	return (s, nil);
}

concat(l1, l2 : list of string) : list of string
{
	ls : list of string;

	ls = nil;
	for (l := l1; l != nil; l = tl l)
		ls = hd l :: ls;
	for (l = l2; l != nil; l = tl l)
		ls = hd l :: ls;
	return ls;
}

err(s : string) : string
{
	for (i := 0; i < len s; i++)
		if (s[i] == ' ' || s[i] == ':')
			return s[0:i];
	return s;
}

kill(pid : int) : int
{
	if (pid < 0)
		return 0;
	fd := sys->open("#p/" + string pid + "/ctl", sys->OWRITE);
	if (fd == nil || sys->fprint(fd, "kill") < 0)
		return -1;
	return 0;
}

readfile(f : string) : string
{
	fd := sys->open(f, sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];	
}
