implement Imap;

#
# IMAP4rev1 client (RFC 3501)
#
# Connects over TLS (port 993), or in clear on port 143 upgraded with
# STARTTLS, through mailconn(2): the server's certificate is verified,
# and every read and write has a deadline.
#
# What a server sends is bounded and is data: a line, a literal and the
# whole answer to a command have limits (MAXLINE, MAXLITERAL,
# MAXRESPONSE), past which the connection is closed with an error; a
# literal's bytes are kept beside the line they belong to and are never
# read as protocol.  What a caller gives is sent as a quoted string, or
# refused if it holds a line break or a NUL.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "keyring.m";

include "tls.m";

include "mailconn.m";
	mailconn: Mailconn;
	Link: import mailconn;

include "factotum.m";
	factotum: Factotum;

include "imap.m";

MAXLINE:	con 1024*1024;		# one line of an answer, without its literals
MAXLITERAL:	con 64*1024*1024;	# one literal (a message's text)
MAXRESPONSE:	con 128*1024*1024;	# everything kept of one command's answer
MAXLITS:	con 4096;		# literals in one line

# Connection state
conn: ref Link;
tagnum := 0;
connected := 0;
currentmbox: string;
iotime := 30*1000;

# An answer's line: its text, with each literal's "{count}" replaced by
# "{k}", and the literals themselves, lits[k].  The parsers below read
# the text; where they meet "{k}" at a string's place they take lits[k]
# whole.  The literal's bytes used to be put into the text and parsed
# with it: a subject sent as a literal could close the envelope's
# parentheses and supply the From and Reply-To that followed, and a
# second literal in one line was read as the lines after it, where
# "A004 OK" ended the command early.
Line: adt {
	text:	string;
	lits:	array of array of byte;
};

# the literals of the line being parsed (nil for a caller's bare string)
curlits: array of array of byte;

# what parsefetchdata found for a BODY[...] or RFC822 item
fhasbody := 0;
fbody: string;

# Tagged response structure
Response: adt {
	status:		string;		# "OK", "NO", "BAD"
	statusline:	string;		# full status line text
	untagged:	list of ref Line;	# untagged * lines
};

# Each module is loaded when it is first wanted and is nil: the parsers
# are called by tests with no connection, and used to leave the rest
# unloaded for an open after them.
ensureloaded()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
}

loadall(): string
{
	ensureloaded();
	if(str == nil)
		return "cannot load String";
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

isup(): int
{
	return connected;
}

open(user, password, server: string, mode: int): string
{
	lerr := loadall();
	if(lerr != nil)
		return lerr;

	if(connected)
		return "already connected";

	# server is a host, or host!port for a port of its own (a local
	# bridge's, say); the key and the certificate are the host's
	port := "993";
	if(mode == STARTTLS)
		port = "143";
	(host, bang) := str->splitl(server, "!");
	if(bang != nil)
		port = bang[1:];

	# Try factotum first if no credentials given
	if(user == nil || password == nil) {
		factotum = load Factotum Factotum->PATH;
		if(factotum != nil) {
			factotum->init();
			(u, p) := factotum->getuserpasswd(
				"proto=pass service=imap dom=" + host);
			if(u != nil && p != nil) {
				user = u;
				password = p;
			}
		}
		if(user == nil || password == nil)
			return "no credentials: supply user/password or configure factotum";
	}
	if(badarg(user) || badarg(password))
		return "LOGIN: a line break or NUL in the user name or password";

	addr := "tcp!" + host + "!" + port;
	how := Mailconn->IMPLICIT;
	if(mode == STARTTLS)
		# Plaintext until the server takes STARTTLS (port 143); the
		# greeting is read before it, and nothing else is sent in clear
		how = Mailconn->IMAPSTARTTLS;
	(c, derr) := Link.dial(addr, host, how, nil, iotime);
	if(derr != nil) {
		if(derr == "timed out")
			derr = "connecting to " + host + " timed out";
		return derr;
	}
	conn = c;
	tagnum = 0;
	connected = 1;
	currentmbox = nil;

	if(mode == IMPLICIT_TLS) {
		# Read server greeting
		conn.deadline(iotime, iotime);
		(greeting, gerr) := conn.getline(MAXLINE);
		if(gerr != nil)
			return "greeting: " + down(gerr);

		# Check for OK greeting
		if(!hasprefix(greeting, "* OK")) {
			down(nil);
			return "bad greeting: " + greeting;
		}
	}

	# Authenticate
	err := authenticate(user, password);
	if(err != nil) {
		down(nil);
		return err;
	}

	return nil;
}

# Authenticate with LOGIN command
# SASL PLAIN would be better but LOGIN works everywhere over TLS
authenticate(user, password: string): string
{
	(resp, rerr) := command("LOGIN " + quote(user) + " " + quote(password));
	if(rerr != nil)
		return "LOGIN: " + rerr;
	if(resp.status != "OK")
		# a server may say back what it was sent
		return "LOGIN failed: " + redact(resp.statusline, password);

	return nil;
}

folders(): (list of string, string)
{
	(resp, rerr) := command("LIST \"\" *");
	if(rerr != nil)
		return (nil, "LIST: " + rerr);
	if(resp.status != "OK")
		return (nil, "LIST failed: " + resp.statusline);

	# Parse untagged LIST responses
	# * LIST (\HasNoChildren) "/" "INBOX"
	result: list of string;
	for(l := resp.untagged; l != nil; l = tl l) {
		ln := hd l;
		if(!hasprefix(ln.text, "* LIST "))
			continue;
		curlits = ln.lits;
		name := parselistname(ln.text);
		curlits = nil;
		if(name != nil)
			result = name :: result;
	}

	return (reverse(result), nil);
}

select(mailbox: string): (ref Mailbox, string)
{
	if(badarg(mailbox))
		return (nil, "SELECT: a line break or NUL in the mailbox's name");
	(resp, rerr) := command("SELECT " + quote(mailbox));
	if(rerr != nil)
		return (nil, "SELECT: " + rerr);
	if(resp.status != "OK")
		return (nil, "SELECT failed: " + resp.statusline);

	mbox := ref Mailbox(mailbox, 0, 0, 0, 0, 0);

	# Parse untagged responses for mailbox info
	for(l := resp.untagged; l != nil; l = tl l) {
		line := (hd l).text;
		# * 172 EXISTS
		if(hassuffix(line, " EXISTS"))
			mbox.exists = parsenumber(line);
		# * 1 RECENT
		else if(hassuffix(line, " RECENT"))
			mbox.recent = parsenumber(line);
		# * OK [UNSEEN 12]
		else if(hasprefix(line, "* OK [UNSEEN "))
			mbox.unseen = parsebracketnum(line, "UNSEEN");
		# * OK [UIDNEXT 4392]
		else if(hasprefix(line, "* OK [UIDNEXT "))
			mbox.uidnext = parsebracketnum(line, "UIDNEXT");
		# * OK [UIDVALIDITY 3857529045]
		else if(hasprefix(line, "* OK [UIDVALIDITY "))
			mbox.uidvalidity = parsebracketnum(line, "UIDVALIDITY");
	}

	currentmbox = mailbox;
	return (mbox, nil);
}

msglist(first, last: int): (list of ref Msg, string)
{
	range := string first + ":" + string last;
	(resp, rerr) := command("FETCH " + range + " (FLAGS UID RFC822.SIZE ENVELOPE)");
	if(rerr != nil)
		return (nil, "FETCH: " + rerr);
	if(resp.status != "OK")
		return (nil, "FETCH failed: " + resp.statusline);

	# Parse FETCH responses
	msgs: list of ref Msg;
	for(l := resp.untagged; l != nil; l = tl l) {
		# * N FETCH (...)
		msg := parsefetch(hd l);
		if(msg != nil)
			msgs = msg :: msgs;
	}

	return (reversemsg(msgs), nil);
}

search(criteria: string): (list of int, string)
{
	return search1("SEARCH", criteria);
}

uidsearch(criteria: string): (list of int, string)
{
	return search1("UID SEARCH", criteria);
}

# The criteria are IMAP's own syntax and are sent as written, on one
# line: with a line break in them they were the commands after it too,
# from whoever could ask for a search.
search1(verb, criteria: string): (list of int, string)
{
	if(badarg(criteria))
		return (nil, "SEARCH: a line break or NUL in the criteria");
	(resp, rerr) := command(verb + " " + criteria);
	if(rerr != nil)
		return (nil, "SEARCH: " + rerr);
	if(resp.status != "OK")
		return (nil, "SEARCH failed: " + resp.statusline);

	# Parse * SEARCH 2 5 7 ...
	result: list of int;
	for(l := resp.untagged; l != nil; l = tl l) {
		line := (hd l).text;
		if(!hasprefix(line, "* SEARCH"))
			continue;
		rest := line[len "* SEARCH":];
		(nil, toks) := sys->tokenize(rest, " ");
		for(; toks != nil; toks = tl toks) {
			(v, ok) := touint(hd toks);
			if(ok)
				result = v :: result;
		}
	}

	return (reverseint(result), nil);
}

fetch(seq: int): (string, string)
{
	return fetchsection(seq, "BODY[]");
}

fetchhdr(seq: int): (string, string)
{
	return fetchsection(seq, "BODY[HEADER]");
}

fetchsection(seq: int, section: string): (string, string)
{
	return fetchbody(0, seq, "FETCH " + string seq + " " + section);
}

uidfetch(uid: int): (string, string)
{
	return fetchbody(1, uid, "UID FETCH " + uidstr(uid) + " (UID BODY[])");
}

# The text asked for is the one in the FETCH line of the message asked
# for (its sequence number, or its UID item).  The last literal of the
# whole answer was taken, whichever line it came in: another message's
# text, if the server said anything about another.
fetchbody(byuid, id: int, cmd: string): (string, string)
{
	(resp, rerr) := command(cmd);
	if(rerr != nil)
		return (nil, "FETCH: " + rerr);
	if(resp.status != "OK")
		return (nil, "FETCH failed: " + resp.statusline);

	for(l := resp.untagged; l != nil; l = tl l) {
		m := parsefetch(hd l);
		if(m == nil || !fhasbody)
			continue;
		if(byuid && m.uid != id || !byuid && m.seq != id)
			continue;
		body := fbody;
		fbody = nil;
		return (body, nil);
	}
	fbody = nil;
	if(byuid)
		return (nil, "no message with that UID");
	return (nil, "no content in FETCH response");
}

store(seq, flags, add: int): string
{
	return store1("STORE " + string seq, flags, add);
}

uidstore(uid, flags, add: int): string
{
	return store1("UID STORE " + uidstr(uid), flags, add);
}

store1(cmd: string, flags, add: int): string
{
	action := "-FLAGS";
	if(add)
		action = "+FLAGS";

	(resp, rerr) := command(cmd + " " + action + " (" + flagstostring(flags) + ")");
	if(rerr != nil)
		return "STORE: " + rerr;
	if(resp.status != "OK")
		return "STORE failed: " + resp.statusline;

	return nil;
}

copy(seqs: string, dest: string): string
{
	if(!seqset(seqs))
		return "COPY: not a sequence set";
	return copy1("COPY " + seqs, dest);
}

uidcopy(uid: int, dest: string): string
{
	return copy1("UID COPY " + uidstr(uid), dest);
}

copy1(cmd, dest: string): string
{
	if(badarg(dest))
		return "COPY: a line break or NUL in the mailbox's name";
	(resp, rerr) := command(cmd + " " + quote(dest));
	if(rerr != nil)
		return "COPY: " + rerr;
	if(resp.status != "OK")
		return "COPY failed: " + resp.statusline;

	return nil;
}

# IDLE (RFC 2177).  The caller's own process reads the connection, here,
# until stop speaks; then DONE is sent and the tagged answer read, so
# that the connection is in step when idle returns.  A second process
# used to read, was never stopped, and went on taking lines of the next
# command's answer.
idle(updates: chan of string, stop: chan of int): string
{
	if(!connected)
		return "not connected";

	tag := nexttag();
	conn.deadline(iotime, iotime);
	err := conn.write(array of byte (tag + " IDLE\r\n"));
	if(err != nil)
		return "IDLE write: " + down(err);

	stopped := 0;
	for(;;) {
		line: string;
		if(stopped)
			(line, err) = conn.getline(MAXLINE);
		else
			(line, err) = conn.waitline(MAXLINE, stop);
		if(err == Mailconn->STOPPED) {
			stopped = 1;
			conn.deadline(iotime, iotime);
			err = conn.write(array of byte "DONE\r\n");
			if(err == nil)
				continue;
		}
		if(err != nil) {
			down(err);
			if(!stopped)
				alt {
				updates <-= nil =>
					;
				<-stop =>
					;
				}
			return "IDLE: " + err;
		}

		# + continuation response - IDLE started
		if(hasprefix(line, "+"))
			continue;

		# Tagged response - IDLE ended
		if(hasprefix(line, tag + " ")) {
			if(!stopped) {
				# refused, or ended by the server: the caller is told
				# when it stops, and meanwhile nothing more comes
				rest := line[len tag + 1:];
				<-stop;
				return "IDLE ended: " + rest;
			}
			return nil;
		}

		# Untagged data (EXISTS, EXPUNGE, etc.)
		if(stopped)
			continue;
		alt {
		updates <-= line =>
			;
		<-stop =>
			stopped = 1;
			conn.deadline(iotime, iotime);
			err = conn.write(array of byte "DONE\r\n");
			if(err != nil)
				return "IDLE: " + down(err);
		}
	}
}

logout(): string
{
	if(!connected)
		return "not connected";

	# Read BYE and tagged OK, but don't fail on errors, and do not
	# wait long for a server that has gone
	t := iotime;
	if(iotime > 5000)
		iotime = 5000;
	command("LOGOUT");
	iotime = t;
	down(nil);
	return nil;
}

hangup()
{
	down(nil);
}

# ---- Protocol I/O ----

nexttag(): string
{
	tagnum++;
	return sys->sprint("A%03d", tagnum);
}

# The connection is over: closed, its processes gone.  The next open
# starts again.
down(why: string): string
{
	if(conn != nil)
		conn.close();
	conn = nil;
	connected = 0;
	currentmbox = nil;
	return why;
}

# Send one command and read to its tagged answer.
command(s: string): (ref Response, string)
{
	if(!connected)
		return (nil, "not connected");
	tag := nexttag();
	conn.deadline(iotime, 20*iotime);
	err := conn.write(array of byte (tag + " " + s + "\r\n"));
	if(err != nil)
		return (nil, down(err));
	return readresponse(tag);
}

# Read response lines until we see our tag.
# Collects untagged * lines, each with its literals.
readresponse(tag: string): (ref Response, string)
{
	untagged: list of ref Line;
	used := 0;

	for(;;) {
		(ln, size, err) := readline();
		if(err != nil)
			return (nil, down(err));
		line := ln.text;

		# Tagged response: our tag followed by OK/NO/BAD
		if(hasprefix(line, tag + " ")) {
			rest := line[len tag + 1:];
			status := "BAD";
			(nil, toks) := sys->tokenize(rest, " ");
			if(toks != nil)
				status = hd toks;
			rl: list of ref Line;
			for(; untagged != nil; untagged = tl untagged)
				rl = hd untagged :: rl;
			return (ref Response(str->toupper(status), rest, rl), nil);
		}

		# Untagged response, or a + continuation: kept.  Anything
		# else is not ours and is dropped.
		if(hasprefix(line, "* ") || hasprefix(line, "+")) {
			used += size;
			if(used > MAXRESPONSE)
				return (nil, down(sys->sprint("the server's answer to one command is more than is taken (%d bytes)", MAXRESPONSE)));
			untagged = ln :: untagged;
		}
	}
}

# One line of an answer with the literals inside it (RFC 3501 4.3): each
# piece that ends "{count}" is followed by count bytes, then the line
# goes on.  Returns the line and the memory it takes.
readline(): (ref Line, int, string)
{
	text := "";
	lits: list of array of byte;
	nlits := 0;
	size := 0;
	for(;;) {
		(frag, err) := conn.getline(MAXLINE);
		if(err != nil)
			return (nil, 0, err);
		size += len frag + 64;
		(brace, n) := litsize(frag);
		if(brace < 0) {
			text += frag;
			break;
		}
		if(n > big MAXLITERAL)
			return (nil, 0, sys->sprint("the server sent a literal of %bd bytes, more than is taken (%d)", n, MAXLITERAL));
		if(nlits >= MAXLITS)
			return (nil, 0, "the server sent a line of too many literals");
		size += int n;
		if(size > MAXRESPONSE)
			return (nil, 0, sys->sprint("the server sent a line of more than is taken (%d bytes)", MAXRESPONSE));
		(b, berr) := conn.getbytes(int n);
		if(berr != nil)
			return (nil, 0, berr);
		text += frag[0:brace] + "{" + string nlits + "}";
		lits = b :: lits;
		nlits++;
	}
	a := array[nlits] of array of byte;
	for(i := nlits - 1; lits != nil; lits = tl lits)
		a[i--] = hd lits;
	return (ref Line(text, a), size, nil);
}

# A line that ends "{digits}": where the brace is and the count; (-1, 0)
# for any other line.
litsize(line: string): (int, big)
{
	l := len line;
	if(l < 3 || line[l-1] != '}')
		return (-1, big 0);
	i := l - 2;
	while(i >= 0 && line[i] >= '0' && line[i] <= '9')
		i--;
	ndig := l - 2 - i;
	if(i < 0 || line[i] != '{' || ndig == 0)
		return (-1, big 0);
	if(ndig > 12)
		return (i, big MAXLITERAL + big 1);
	return (i, big line[i+1:l-1]);
}

# Check if line ends with {N} literal indicator (exported for testing):
# N, or 0 if it does not, or N is 0 or more than a literal may be.
checkliteral(line: string): int
{
	(brace, n) := litsize(line);
	if(brace < 0 || n > big MAXLITERAL)
		return 0;
	return int n;
}

# A string a caller gave that cannot be sent as one quoted string: it
# would end the command's line.
badarg(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\r' || s[i] == '\n' || s[i] == 0)
			return 1;
	return 0;
}

# A sequence set (RFC 3501 9: numbers, ":", ",", "*") and nothing else.
seqset(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= '0' && c <= '9') && c != ':' && c != ',' && c != '*')
			return 0;
	}
	return 1;
}

# s without secret, where a server's text is put in an error.
redact(s, secret: string): string
{
	if(len secret == 0)
		return s;
	for(;;) {
		i := strindex(s, secret);
		if(i < 0)
			return s;
		s = s[0:i] + "[...]" + s[i + len secret:];
	}
}

# A UID is 32 bits unsigned (RFC 3501 2.3.1.1) and is kept in an int:
# one past 2^31 is negative there, and is printed and compared as what
# it is.  Each used to be read as the largest int, so they were all one.
uidstr(uid: int): string
{
	return string (big uid & big 16rFFFFFFFF);
}

# Decimal digits as 32 bits unsigned: (value, 1), or (0, 0) if they are
# not digits or do not fit.
touint(s: string): (int, int)
{
	if(len s == 0 || len s > 10)
		return (0, 0);
	v := big 0;
	for(i := 0; i < len s; i++) {
		if(s[i] < '0' || s[i] > '9')
			return (0, 0);
		v = v * big 10 + big (s[i] - '0');
	}
	if(v > big 16rFFFFFFFF)
		return (0, 0);
	return (int v, 1);
}

# Decimal digits as a count: at most the largest int.
tocount(s: string): int
{
	v := big 0;
	for(i := 0; i < len s; i++) {
		if(s[i] < '0' || s[i] > '9')
			break;
		v = v * big 10 + big (s[i] - '0');
		if(v > big 16r7FFFFFFF)
			return 16r7FFFFFFF;
	}
	return int v;
}

# ---- FETCH response parser ----

# A FETCH line with its literals
parsefetch(ln: ref Line): ref Msg
{
	curlits = ln.lits;
	m := parsefetchline(ln.text);
	curlits = nil;
	return m;
}

# Parse "* N FETCH (...)" line into a Msg
parsefetchline(line: string): ref Msg
{
	ensureloaded();
	fhasbody = 0;
	fbody = nil;
	# * 1 FETCH (FLAGS (\Seen) UID 123 RFC822.SIZE 4567 ENVELOPE (...))
	if(!hasprefix(line, "* "))
		return nil;

	# Extract sequence number
	rest := line[2:];
	(seq, rest2) := gettoken(rest);
	seqnum := tocount(seq);
	if(seqnum <= 0)
		return nil;

	# Skip "FETCH"
	(tok, rest3) := gettoken(rest2);
	if(str->toupper(tok) != "FETCH")
		return nil;

	# Parse the parenthesized data
	msg := ref Msg(seqnum, 0, 0, 0, nil);
	parsefetchdata(rest3, msg);
	return msg;
}

# Parse the parenthesized FETCH data items
parsefetchdata(data: string, msg: ref Msg)
{
	# Strip outer parens
	data = stripws(data);
	if(len data > 0 && data[0] == '(')
		data = data[1:];
	if(len data > 0 && data[len data - 1] == ')')
		data = data[:len data - 1];

	# Parse key-value pairs
	i := 0;
	while(i < len data) {
		# Skip whitespace
		while(i < len data && (data[i] == ' ' || data[i] == '\t'))
			i++;
		if(i >= len data)
			break;

		# Read key
		keystart := i;
		while(i < len data && data[i] != ' ' && data[i] != '(')
			i++;
		key := str->toupper(data[keystart:i]);

		# Skip whitespace
		while(i < len data && data[i] == ' ')
			i++;

		# a message's text: BODY[...] or RFC822, a literal or a string
		if(hasprefix(key, "BODY[") || key == "RFC822" || key == "RFC822.HEADER" || key == "RFC822.TEXT") {
			(fbody, i) = parseatom(data, i);
			fhasbody = 1;
			continue;
		}

		case key {
		"FLAGS" =>
			# (flag flag ...)
			(flags, ni) := parseflaglist(data, i);
			msg.flags = flags;
			i = ni;
		"UID" =>
			(val, ni) := getuint(data, i);
			msg.uid = val;
			i = ni;
		"RFC822.SIZE" =>
			(val, ni) := getint(data, i);
			msg.size = val;
			i = ni;
		"ENVELOPE" =>
			(env, ni) := parseenvelope(data, i);
			msg.envelope = env;
			i = ni;
		* =>
			# Skip unknown item value; a character that is no
			# value's start (a stray parenthesis) is stepped over
			ni := skipvalue(data, i);
			if(ni == i && i == keystart)
				ni++;
			i = ni;
		}
	}
}

# Parse a parenthesized flag list like (\Seen \Flagged)
parseflaglist(data: string, pos: int): (int, int)
{
	flags := 0;
	if(pos >= len data || data[pos] != '(')
		return (0, pos);
	pos++;

	while(pos < len data && data[pos] != ')') {
		# Skip whitespace
		while(pos < len data && data[pos] == ' ')
			pos++;
		if(pos >= len data || data[pos] == ')')
			break;

		# Read flag atom
		start := pos;
		while(pos < len data && data[pos] != ' ' && data[pos] != ')')
			pos++;
		flag := data[start:pos];
		flags |= flagfromstring(flag);
	}

	if(pos < len data && data[pos] == ')')
		pos++;

	return (flags, pos);
}

# Parse ENVELOPE structure
# (date subject from to cc bcc replyto messageid)
# Each address is ((name route mailbox host)) or NIL
parseenvelope(data: string, pos: int): (ref Envelope, int)
{
	if(pos >= len data || data[pos] != '(')
		return (nil, pos);
	pos++;	# skip (

	env := ref Envelope(nil, nil, nil, nil, nil, nil, nil, nil, nil);

	# date
	(env.date, pos) = parseatom(data, pos);
	pos = skipws2(data, pos);

	# subject
	(env.subject, pos) = parseatom(data, pos);
	pos = skipws2(data, pos);

	# from (address list) -> stored in .sender
	(env.sender, env.fromaddrs, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# sender (IMAP envelope sender) - skip
	(nil, nil, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# reply-to
	(env.replyto, env.replytoaddrs, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# to -> stored in .recipient
	(env.recipient, nil, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# cc
	(env.cc, nil, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# bcc - skip
	(nil, nil, pos) = parseaddrlist(data, pos);
	pos = skipws2(data, pos);

	# in-reply-to - skip
	(nil, pos) = parseatom(data, pos);
	pos = skipws2(data, pos);

	# message-id
	(env.messageid, pos) = parseatom(data, pos);

	# Find closing paren
	while(pos < len data && data[pos] != ')')
		pos++;
	if(pos < len data)
		pos++;

	return (env, pos);
}

# Parse an IMAP atom, quoted string, literal, or NIL
parseatom(data: string, pos: int): (string, int)
{
	pos = skipws2(data, pos);
	if(pos >= len data)
		return (nil, pos);

	# NIL
	if(pos + 3 <= len data && str->toupper(data[pos:pos+3]) == "NIL") {
		return (nil, pos + 3);
	}

	# Quoted string: its characters, each \x the x.  One that ends in
	# a backslash, or is not closed, ends with the data (the index ran
	# past it: an exception in whoever had asked for the mailbox).
	if(data[pos] == '"') {
		pos++;
		val := "";
		start := pos;
		while(pos < len data && data[pos] != '"') {
			if(data[pos] == '\\') {
				val += data[start:pos];
				pos++;	# the escaped character is kept as it is
				start = pos;
				if(pos >= len data)
					break;
			}
			pos++;
		}
		val += data[start:pos];
		if(pos < len data)
			pos++;	# skip closing "
		return (val, pos);
	}

	# A literal: "{k}", the line's k'th (see Line).  Its bytes are the
	# string, whatever they are.
	if(data[pos] == '{') {
		lend := pos + 1;
		while(lend < len data && data[lend] != '}')
			lend++;
		if(lend >= len data)
			return (nil, len data);
		val: string;
		(k, ok) := touint(data[pos+1:lend]);
		if(ok && k >= 0 && k < len curlits)
			val = string curlits[k];
		return (val, lend + 1);
	}

	# Parenthesized list - skip it
	if(data[pos] == '(') {
		depth := 0;
		start := pos;
		while(pos < len data) {
			if(data[pos] == '(')
				depth++;
			else if(data[pos] == ')') {
				depth--;
				if(depth == 0) {
					pos++;
					return (data[start:pos], pos);
				}
			} else if(data[pos] == '"') {
				pos = skipquoted(data, pos + 1);
			}
			pos++;
		}
		# not closed: what there is of it
		if(pos > len data)
			pos = len data;
		return (data[start:pos], pos);
	}

	# Bare atom
	start := pos;
	while(pos < len data && data[pos] != ' ' && data[pos] != ')'
		&& data[pos] != '(' && data[pos] != '"')
		pos++;
	return (data[start:pos], pos);
}

# Parse an address list: ((name route mbox host) ...) or NIL
# Returns a formatted string like "Name <mbox@host>" for showing, and
# the addresses themselves, "mbox@host" each, in order
parseaddrlist(data: string, pos: int): (string, list of string, int)
{
	pos = skipws2(data, pos);
	if(pos >= len data)
		return (nil, nil, pos);

	# NIL
	if(pos + 3 <= len data && str->toupper(data[pos:pos+3]) == "NIL")
		return (nil, nil, pos + 3);

	if(data[pos] != '(')
		return (nil, nil, pos);
	pos++;	# skip outer (

	addrs := "";
	bare: list of string;
	while(pos < len data && data[pos] != ')') {
		pos = skipws2(data, pos);
		if(pos >= len data || data[pos] == ')')
			break;

		if(data[pos] != '(') {
			pos++;
			continue;
		}
		pos++;	# skip (

		# (name route mailbox host)
		(name, npos) := parseatom(data, pos);
		pos = npos;
		pos = skipws2(data, pos);

		# route - skip
		(nil, rpos) := parseatom(data, pos);
		pos = rpos;
		pos = skipws2(data, pos);

		# mailbox
		(mbox, mpos) := parseatom(data, pos);
		pos = mpos;
		pos = skipws2(data, pos);

		# host
		(host, hpos) := parseatom(data, pos);
		pos = hpos;

		# Skip to closing )
		while(pos < len data && data[pos] != ')')
			pos++;
		if(pos < len data)
			pos++;

		# Format address
		addr := "";
		if(mbox != nil && host != nil)
			addr = mbox + "@" + host;
		else if(mbox != nil)
			addr = mbox;

		if(addr != "")
			bare = addr :: bare;
		if(name != nil && addr != nil)
			addr = name + " <" + addr + ">";

		if(addrs != "" && addr != "")
			addrs += ", ";
		if(addr != "")
			addrs += addr;
	}

	# Skip closing )
	if(pos < len data && data[pos] == ')')
		pos++;

	return (addrs, reverse(bare), pos);
}

# From inside a quoted string to its closing quote, or the data's end.
skipquoted(data: string, pos: int): int
{
	while(pos < len data && data[pos] != '"') {
		if(data[pos] == '\\')
			pos++;
		pos++;
	}
	if(pos > len data)
		pos = len data;
	return pos;
}

# Skip a value in FETCH data (atom, quoted string, or paren list)
skipvalue(data: string, pos: int): int
{
	pos = skipws2(data, pos);
	if(pos >= len data)
		return pos;

	if(data[pos] == '(') {
		depth := 0;
		while(pos < len data) {
			if(data[pos] == '(')
				depth++;
			else if(data[pos] == ')') {
				depth--;
				if(depth == 0) {
					pos++;
					return pos;
				}
			} else if(data[pos] == '"') {
				pos = skipquoted(data, pos + 1);
			}
			pos++;
		}
		if(pos > len data)
			pos = len data;
		return pos;
	}

	if(data[pos] == '"') {
		pos = skipquoted(data, pos + 1);
		if(pos < len data)
			pos++;
		return pos;
	}

	# Atom
	while(pos < len data && data[pos] != ' ' && data[pos] != ')')
		pos++;
	return pos;
}

# ---- Flag conversion ----

flagfromstring(s: string): int
{
	ls := str->tolower(s);
	case ls {
	"\\seen" =>		return FSEEN;
	"\\answered" =>	return FANSWERED;
	"\\flagged" =>	return FFLAGGED;
	"\\deleted" =>	return FDELETED;
	"\\draft" =>	return FDRAFT;
	}
	return 0;
}

flagstostring(flags: int): string
{
	s := "";
	if(flags & FSEEN) s = addws(s, "\\Seen");
	if(flags & FANSWERED) s = addws(s, "\\Answered");
	if(flags & FFLAGGED) s = addws(s, "\\Flagged");
	if(flags & FDELETED) s = addws(s, "\\Deleted");
	if(flags & FDRAFT) s = addws(s, "\\Draft");
	return s;
}

addws(a, b: string): string
{
	if(a == "")
		return b;
	return a + " " + b;
}

# Parse flags string to bitmask (exported for testing)
parseflags(s: string): int
{
	ensureloaded();
	flags := 0;
	(nil, toks) := sys->tokenize(s, " ()");
	for(; toks != nil; toks = tl toks)
		flags |= flagfromstring(hd toks);
	return flags;
}

# ---- LIST response parsing ----

# Parse mailbox name from LIST response
# * LIST (\HasNoChildren) "/" "INBOX"
# * LIST (\HasNoChildren) "/" INBOX
# The attributes, the delimiter, then the name: a quoted string (its
# escapes undone), an atom or a literal.
parselistname(line: string): string
{
	ensureloaded();
	if(!hasprefix(line, "* LIST "))
		return nil;
	pos := skipvalue(line, len "* LIST ");
	(nil, pos) = parseatom(line, pos);
	pos = skipws2(line, pos);
	if(pos >= len line)
		return nil;
	name: string;
	if(line[pos] == '"' || line[pos] == '{')
		(name, nil) = parseatom(line, pos);
	else {
		# an atom runs to the line's end (a name with a parenthesis
		# in it is not cut there)
		e := len line;
		while(e > pos && (line[e-1] == ' ' || line[e-1] == '\t'))
			e--;
		name = line[pos:e];
	}
	return name;
}

# ---- Helper functions ----

# Get an integer from data at position pos
getint(data: string, pos: int): (int, int)
{
	pos = skipws2(data, pos);
	start := pos;
	while(pos < len data && data[pos] >= '0' && data[pos] <= '9')
		pos++;
	if(start == pos)
		return (0, pos);
	return (tocount(data[start:pos]), pos);
}

# The same for a UID: 32 bits unsigned (see uidstr); 0 if it does not fit
getuint(data: string, pos: int): (int, int)
{
	pos = skipws2(data, pos);
	start := pos;
	while(pos < len data && data[pos] >= '0' && data[pos] <= '9')
		pos++;
	(v, nil) := touint(data[start:pos]);
	return (v, pos);
}

# Get a whitespace-delimited token
gettoken(s: string): (string, string)
{
	# Skip leading whitespace
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	start := i;
	while(i < len s && s[i] != ' ' && s[i] != '\t')
		i++;
	if(start == i)
		return (nil, s);
	return (s[start:i], s[i:]);
}

# Parse "* N SOMETHING" -- extract N
parsenumber(line: string): int
{
	# Skip "* "
	if(len line < 3)
		return 0;
	rest := line[2:];
	(tok, nil) := gettoken(rest);
	return tocount(tok);
}

# Parse "* OK [KEY N]" -- extract N for the given KEY
parsebracketnum(line: string, key: string): int
{
	target := "[" + key + " ";
	i := strindex(line, target);
	if(i < 0)
		return 0;
	start := i + len target;
	end := start;
	while(end < len line && line[end] != ']' && line[end] != ' ')
		end++;
	return tocount(line[start:end]);
}

# IMAP quoting: wrap in double quotes, escape \ and "
quote(s: string): string
{
	result := "\"";
	for(i := 0; i < len s; i++) {
		if(s[i] == '"' || s[i] == '\\')
			result += "\\";
		result += s[i:i+1];
	}
	result += "\"";
	return result;
}

strindex(s, sub: string): int
{
	if(len sub > len s)
		return -1;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return i;
	}
	return -1;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

hassuffix(s, suffix: string): int
{
	return len s >= len suffix && s[len s - len suffix:] == suffix;
}

stripws(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	return s[i:j];
}

skipws2(data: string, pos: int): int
{
	while(pos < len data && (data[pos] == ' ' || data[pos] == '\t'))
		pos++;
	return pos;
}

# List reversal helpers
reverse(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

reversemsg(l: list of ref Msg): list of ref Msg
{
	r: list of ref Msg;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

reverseint(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
