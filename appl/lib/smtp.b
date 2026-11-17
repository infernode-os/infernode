implement Smtp;

#
# SMTP client: mail handed to a server in clear on port 25 (open), or
# authenticated over TLS (authopen: from the start on 465, or after
# STARTTLS on 587).
#
# The connection is mailconn(2)'s: every reply has a deadline and a
# bound, and a connection that fails is closed.  A reply is judged by
# its code, the one the command wants.  No error says what was sent as
# a credential.
#

include "sys.m";
	sys : Sys;
include "bufio.m";
include "smtp.m";
include "encoding.m";
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbentry, Tuples: import attrdb;
include "ip.m";
	ip: IP;
include "ipattr.m";
	ipattr: IPattr;
include "keyring.m";
include "tls.m";
include "mailconn.m";
	mailconn: Mailconn;
	Link: import mailconn;

MAXLINE: con 8192;	# a reply's line
MAXLINES: con 100;	# and how many one reply has
CHUNK: con 16*1024;	# of a message's text, a write

usessl := 0;
c: ref Link;
conn := 0;
iotime := 30*1000;
base64: Encoding;
db: ref Db;
dbfile := "/lib/ndb/local";

init(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(mailconn == nil){
		m := load Mailconn Mailconn->PATH;
		if(m == nil)
			return "cannot load Mailconn";
		err := m->init();
		if(err != nil)
			return err;
		mailconn = m;
	}
	return nil;
}

timeout(ms: int)
{
	if(ms > 0)
		iotime = ms;
}

open(server : string): (int, string)
{
	ierr := init();
	if(ierr != nil)
		return (-1, ierr);
	if (conn)
		return (-1, "connection is already open");
	if (server == nil)
		server = "$smtp";
	(nc, derr) := Link.dial("tcp!" + server + "!25", server, Mailconn->CLEAR, nil, iotime);
	if(derr != nil)
		return (-1, "dialup failed: " + derr);
	c = nc;
	usessl = 0;
	(ok, s) := expect("greeting", 220);
	if (ok < 0)
		return (-1, s);
	conn = 1;
	return (1, nil);
}

authopen(user, password, server : string, mode: int): (int, string)
{
	ierr := init();
	if(ierr != nil)
		return (-1, ierr);
	if (base64 == nil) {
		base64 = load Encoding Encoding->BASE64PATH;
		if(base64 == nil)
			return (-1, "cannot load base64");
	}
	if (conn)
		return (-1, "connection is already open");

	# The password goes in AUTH PLAIN: never in clear.
	port: string;
	how: int;
	case mode {
	IMPLICIT_TLS =>
		port = "465";
		how = Mailconn->IMPLICIT;
	STARTTLS =>
		port = "587";
		how = Mailconn->SMTPSTARTTLS;
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

	(nc, derr) := Link.dial(addr, host, how, domain, iotime);
	if(derr != nil){
		if(derr == "timed out")
			derr = "connecting to " + host + " timed out";
		return (-1, derr);
	}
	c = nc;
	usessl = 1;

	ok: int;
	s: string;
	if(mode == IMPLICIT_TLS){
		# the greeting; after STARTTLS there is none
		(ok, s) = expect("greeting", 220);
		if (ok < 0)
			return (-1, teardown(s));
	}
	# EHLO, not HELO: AUTH is an extension (and after STARTTLS the
	# client starts again with EHLO, RFC 3207 4.2)
	(ok, s) = cmd("EHLO "+domain, "EHLO", 250);
	if(ok < 0)
		return (-1, teardown(s));
	(ok, s) = cmd("AUTH PLAIN", "AUTH", 334);
	if(ok < 0)
		return (-1, teardown(s));
	# The credential is named, not shown: the error of a refused or
	# unanswered AUTH used to begin with this line, the base64 of the
	# user and the password, and went to whoever had asked for mail to
	# be sent.  A server's own words are kept, less the credential if
	# it says it back.
	cred := base64->enc(array of byte (user + "\0" + user + "\0" + password));
	(ok, s) = cmd(cred, "AUTH credentials", 235);
	if (ok < 0)
		return (-1, teardown(redact(redact(s, cred), password)));

	conn = 1;
	return (1, nil);
}

# The name EHLO gives: the system's domain from ndb, or its name
heloname(): string
{
	hostname := readfile("/dev/sysname");
	if(hostname == nil)
		hostname = "localhost";
	if(attrdb == nil){
		attrdb = load Attrdb Attrdb->PATH;
		ip = load IP IP->PATH;
		ipattr = load IPattr IPattr->PATH;
		if(attrdb == nil || ip == nil || ipattr == nil){
			attrdb = nil;
			return hostname;
		}
		attrdb->init();
		ip->init();
		ipattr->init(attrdb, ip);
		db = Db.open(dbfile);
	}
	if(db == nil)
		return hostname;
	(domain, err) := ipattr->findnetattr(db, "sys", hostname, "dom");
	if(err != nil || domain == nil || !okaddr(domain))
		return hostname;
	return domain;
}

okaddr(addr: string): int
{
	if(len addr == 0 || len addr > 998)
		return 0;
	for(i := 0; i < len addr; i++){
		ch := addr[i];
		if(ch <= ' ' || ch == 16r7F || ch == '<' || ch == '>')
			return 0;
	}
	return 1;
}

okheader(value: string): int
{
	for(i := 0; i < len value; i++)
		if(value[i] == '\r' || value[i] == '\n' || value[i] == 0)
			return 0;
	return 1;
}

sendmail (fromwho : string, towho : list of string, cc : list of string, mlist: list of string): (int, string)
{
	ok : int;
	s : string;

	# An address goes between < and > on a command's line: with a line
	# break in it, it was the commands after it too (a second RCPT TO,
	# whatever else), and callers pass addresses taken from mail.  All
	# are looked at before anything is sent.
	if(fromwho != nil && !okaddr(fromwho))
		return (-1, "the 'from' address is not an address");
	all := concat(towho, cc);
	for(l := all; l != nil; l = tl l)
		if(!okaddr(hd l))
			return (-1, "a recipient is not an address");
	(data, derr) := wiretext(mlist);
	if(derr != nil)
		return (-1, derr);
	if (!conn)
		return (-1, "connection is not open");
	(user, dom) := split(fromwho, '@');
	if (fromwho == nil || user == nil)
		return (-1, "no 'from' name");
	if (towho == nil)
		return (-1, "no 'to' name");
	if (dom == nil)
		return (-1, "no domain name");

	(ok, s) = cmd("RSET", "RSET", 250);
	if (ok < 0)
		return (-1, s);
	if(!usessl){
		(ok, s) = cmd("HELO " + heloname(), "HELO", 250);
		if (ok < 0)
			return (-1, s);
	}
	(ok, s) = cmd("MAIL FROM:<" + fromwho + ">", "MAIL FROM", 250);
	if (ok < 0)
		return (-1, s);
	t := "";
	for ( ; all != nil; all = tl all) {
		(ok, s) = cmd("RCPT TO:<" + hd all + ">", "RCPT TO:<" + hd all + ">", 250);
		if (ok < 0){
			if(c == nil)
				return (-1, s);
			t += " " + s;
		}
	}
	if (t != nil){
		cmd("RSET", "RSET", 250);
		return (-1, t[1:]);
	}
	# Only 354 asks for the message.  Any reply not an error used to
	# count: after a 250 the text was sent all the same, and read by
	# the server as commands.
	(ok, s) = cmd("DATA", "DATA", 354);
	if (ok < 0)
		return (-1, s);
	c.deadline(iotime, 0);
	for(o := 0; o < len data; o += CHUNK){
		e := o + CHUNK;
		if(e > len data)
			e = len data;
		werr := c.write(data[o:e]);
		if(werr != nil)
			return (-1, teardown("write to server failed: " + werr));
	}
	(ok, s) = cmd(".", "end of message", 250);
	if (ok < 0)  
		return (-1, s);  
	return (1, nil);
}

# The message as it goes after DATA: each line ended CR LF, a line that
# begins with a dot given another (RFC 5321 4.5.2).  A carriage return
# that is not a line's end is one all the same to some receivers, for
# whom "a CR . CR b" then held the dot that ends the message and the
# commands after it: inside a body line it ends the line here, so the
# dot is doubled like any other; inside a header line, where a new line
# is a new header, the message is refused.  So is a NUL anywhere.
wiretext(mlist: list of string): (array of byte, string)
{
	out := "";
	parts: list of array of byte;
	n := 0;
	inhdr := 1;
	for ( ; mlist != nil; mlist = tl mlist) {
		msg := hd mlist;
		i := 0;
		do {
			j := i;
			while(j < len msg && msg[j] != '\n' && msg[j] != '\r'){
				if(msg[j] == 0)
					return (nil, "the message holds a NUL");
				j++;
			}
			line := msg[i:j];
			if(j < len msg && msg[j] == '\r'){
				if(j+1 < len msg && msg[j+1] == '\n')
					j++;
				else if(j+1 < len msg && inhdr)
					return (nil, "a header line of the message holds a carriage return");
			}
			if(len line == 0)
				inhdr = 0;
			else if(line[0] == '.')
				line = "." + line;
			out += line + "\r\n";
			if(len out >= CHUNK){
				b := array of byte out;
				parts = b :: parts;
				n += len b;
				out = "";
			}
			i = j + 1;
		} while(i < len msg);
	}
	b := array of byte out;
	parts = b :: parts;
	n += len b;
	data := array[n] of byte;
	for(; parts != nil; parts = tl parts){
		p := hd parts;
		n -= len p;
		data[n:] = p;
	}
	return (data, nil);
}

close(): (int, string)
{
	if (!conn)
		return (-1, "connection is not open");
	# QUIT's answer is not waited for long: the mail has gone
	t := iotime;
	if(iotime > 5000)
		iotime = 5000;
	(ok, nil) := cmd("QUIT", "QUIT", 221);
	iotime = t;
	teardown(nil);
	if (ok < 0)
		return (-1, "failed to close connection");
	return (1, nil);
}

# The session is over, whatever state it was in: the connection closed
# and its processes gone.  A failed authopen used to leave them all, and
# a timeout left the session to be written to again.
teardown(why: string): string
{
	if(c != nil)
		c.close();
	c = nil;
	conn = 0;
	usessl = 0;
	return why;
}

# Send a command and take its reply, which must have the code want
# (RCPT's 251 is 250).  name is what an error calls the command: never
# the line sent, which may be a credential.
cmd(s, name: string, want: int) : (int, string)
{
	if(c == nil)
		return (-1, name + ": connection is not open");
	c.deadline(iotime, 4*iotime);
	werr := c.write(array of byte (s + "\r\n"));
	if(werr != nil)
		return (-1, teardown(name + " send failed: " + werr));
	return expect(name, want);
}

expect(name: string, want: int): (int, string)
{
	if(c == nil)
		return (-1, name + ": connection is not open");
	c.deadline(iotime, 4*iotime);
	(code, text, err) := reply();
	if(err != nil)
		return (-1, teardown(name + " receive failed (" + err + ")"));
	if(code == want || want == 250 && code == 251)
		return (1, nil);
	return (-1, name + " refused: " + text);
}

# A reply: its code and its last line.  Each line is three digits, then
# "-" on all but the last (RFC 5321 4.2); anything else is not SMTP and
# ends the session (a line of no characters used to end the reader).
reply(): (int, string, string)
{
	for(n := 0; n < MAXLINES; n++){
		(line, err) := c.getline(MAXLINE);
		if(err != nil){
			if(err == "timed out")
				err = "smtp timed out";
			return (0, nil, err);
		}
		if(len line < 3 || !isdigit(line[0]) || !isdigit(line[1]) || !isdigit(line[2]))
			return (0, nil, "not an SMTP reply");
		if(len line > 3 && line[3] == '-')
			continue;	# a reply's line before its last (EHLO's)
		return (int line[0:3], line, nil);
	}
	return (0, nil, "a reply of too many lines");
}

# s without secret, where a server's words are put in an error.
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

isdigit(ch: int): int
{
	return ch >= '0' && ch <= '9';
}

split(s : string, ch : int) : (string, string)
{
	for (i := 0; i < len s; i++)
		if (s[i] == ch)
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

readfile(f : string) : string
{
	fd := sys->open(f, sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];	
}
