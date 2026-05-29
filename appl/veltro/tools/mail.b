implement ToolMail;

#
# mail - Veltro tool for reading and sending email via /n/mail
#
# A thin client over the mail9p filesystem (mounted at /n/mail). It does
# ordinary file operations only: it holds no credentials and speaks no
# IMAP or SMTP itself — mail9p owns the protocol and the OAuth tokens.
# The capability split is the namespace: a task that may only triage is
# bound the read-only field files; a task that may reply is additionally
# bound compose / draft-reply. This tool issues whatever its namespace
# permits and surfaces Rerror for anything it doesn't.
#
# Usage:
#   mail accounts                       List configured mail accounts
#   mail list [box]                     List recent messages (default INBOX)
#   mail unread [box]                   List only unread messages
#   mail read <uid> [box]               Show one message (headers + body)
#   mail send <to> <subject> -- <body>  Compose and send a message
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolMail: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

MAILROOT: con "/n/mail";
DEFBOX:   con "INBOX";
MAXLIST:  con 50;	# cap on messages scanned per list

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "mail";
}

doc(): string
{
	return "mail - Read and send email via the /n/mail filesystem\n\n" +
		"Usage:\n" +
		"  mail accounts                       List configured mail accounts\n" +
		"  mail list [box]                     List recent messages (default INBOX)\n" +
		"  mail unread [box]                   List only unread messages\n" +
		"  mail read <uid> [box]               Show one message (headers + body)\n" +
		"  mail send <to> <subject> -- <body>  Compose and send a message\n" +
		"  mail flag <uid> <+/-flag>...        Set message flags (e.g. flag 4412 seen)\n" +
		"  mail reply <uid> <draft body>       Reply to a message (threads automatically)\n\n" +
		"Notes:\n" +
		"  - Operates on the first configured account unless only one exists.\n" +
		"  - 'list'/'unread' show: <uid>  <from>  <subject>  [unread]\n" +
		"  - 'send' separates the recipient/subject from the body with ' -- '.\n\n" +
		"Examples:\n" +
		"  mail unread\n" +
		"  mail read 4412\n" +
		"  mail send alice@example.com Lunch? -- Are you free at noon tomorrow?\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"mail\"," +
		"\"description\":\"Read and send email through the user's mailbox (/n/mail). Subcommands: accounts (list accounts); list/unread [box] (list messages, marking unread); read <uid> [box] (show one message and mark it read); send <to> <subject> -- <body> (compose and send); flag <uid> <+/-flag>... (set flags, e.g. flag 4412 seen); reply <uid> <draft body> (reply, threaded automatically).\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"Full subcommand line, e.g. 'unread', 'read 4412', or 'send alice@example.com Lunch? -- Are you free at noon?'.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil) {
		e := init();
		if(e != nil)
			return "error: " + e;
	}

	(n, argv) := sys->tokenize(args, " \t");
	if(n < 1)
		return "error: usage: mail accounts|list|unread|read|send ...";

	verb := hd argv;
	rest := tl argv;

	case verb {
	"accounts" =>
		return cmdaccounts();
	"list" =>
		return cmdlist(boxarg(rest), 0);
	"unread" =>
		return cmdlist(boxarg(rest), 1);
	"read" =>
		return cmdread(rest);
	"send" =>
		return cmdsend(args);
	"flag" =>
		return cmdflag(rest);
	"reply" =>
		return cmdreply(rest);
	* =>
		return "error: unknown subcommand '" + verb +
			"' (want: accounts|list|unread|read|send|flag|reply)";
	}
}

# Optional [box] argument; defaults to INBOX.
boxarg(argv: list of string): string
{
	if(argv != nil && hd argv != "")
		return hd argv;
	return DEFBOX;
}

cmdaccounts(): string
{
	(names, err) := listaccounts();
	if(err != nil)
		return "error: " + err;
	if(names == nil)
		return "no mail accounts configured\n" +
			"(add one in the Keyring app, then connect it via mailctl)";
	out := "";
	for(; names != nil; names = tl names) {
		nm := hd names;
		(status, serr) := readfile(MAILROOT + "/accounts/" + nm + "/ctl");
		if(serr != nil)
			status = "(status unavailable)";
		out += nm + "\t" + strip(status) + "\n";
	}
	return out;
}

cmdlist(box: string, unreadonly: int): string
{
	(acct, aerr) := firstaccount();
	if(aerr != nil)
		return "error: " + aerr;

	# Make sure the box is the selected one so its message dirs exist.
	selerr := selectbox(acct, box);
	if(selerr != nil)
		return "error: select " + box + ": " + selerr;

	boxpath := MAILROOT + "/accounts/" + acct + "/boxes/" + box;
	(uids, derr) := messageuids(boxpath);
	if(derr != nil)
		return "error: " + derr;
	if(uids == nil)
		return "no messages in " + box + "\n";

	out := "";
	count := 0;
	for(; uids != nil && count < MAXLIST; uids = tl uids) {
		uid := hd uids;
		mdir := boxpath + "/" + uid;
		(flags, nil) := readfile(mdir + "/flags");
		unread := strindex(flags, "Seen") < 0;
		if(unreadonly && !unread)
			continue;
		(from, nil) := readfile(mdir + "/from");
		(subj, nil) := readfile(mdir + "/subject");
		line := uid + "\t" + strip(from) + "\t" + strip(subj);
		if(unread)
			line += "\t[unread]";
		out += line + "\n";
		count++;
	}
	if(out == "") {
		if(unreadonly)
			return "no unread messages in " + box + "\n";
		return "no messages in " + box + "\n";
	}
	return out;
}

cmdread(argv: list of string): string
{
	if(argv == nil || hd argv == "")
		return "error: usage: mail read <uid> [box]";
	uid := hd argv;
	argv = tl argv;
	box := DEFBOX;
	if(argv != nil && hd argv != "")
		box = hd argv;

	(acct, aerr) := firstaccount();
	if(aerr != nil)
		return "error: " + aerr;
	selerr := selectbox(acct, box);
	if(selerr != nil)
		return "error: select " + box + ": " + selerr;

	mdir := MAILROOT + "/accounts/" + acct + "/boxes/" + box + "/" + uid;
	(from, ferr) := readfile(mdir + "/from");
	if(ferr != nil)
		return "error: no such message " + uid + " in " + box;
	(toaddr, nil) := readfile(mdir + "/to");
	(date, nil) := readfile(mdir + "/date");
	(subj, nil) := readfile(mdir + "/subject");
	(body, berr) := readfile(mdir + "/body");
	if(berr != nil)
		body = "(no body)";

	# Mark the message read now that we've fetched it.
	writeall(mdir + "/flags", "+Seen");

	return "From: " + strip(from) + "\n" +
		"To: " + strip(toaddr) + "\n" +
		"Date: " + strip(date) + "\n" +
		"Subject: " + strip(subj) + "\n\n" +
		body + "\n";
}

cmdsend(args: string): string
{
	# args is the full "send <to> <subject> -- <body>" line.
	rest := args;
	if(len rest >= 5 && rest[0:5] == "send ")
		rest = rest[5:];
	else if(rest == "send")
		rest = "";

	sep := strindex(rest, " -- ");
	if(sep < 0)
		return "error: usage: mail send <to> <subject> -- <body>";
	head := rest[0:sep];
	body := rest[sep + 4:];

	(nh, htoks) := sys->tokenize(head, " \t");
	if(nh < 2)
		return "error: usage: mail send <to> <subject> -- <body>";
	toaddr := hd htoks;
	subject := join(tl htoks, " ");
	if(strip(body) == "")
		return "error: empty message body";

	(acct, aerr) := firstaccount();
	if(aerr != nil)
		return "error: " + aerr;

	# RFC822: headers, blank line, body. mail9p fills From: from the
	# account credential and routes the SMTP send (XOAUTH2 if the
	# account is OAuth).
	msg := "To: " + toaddr + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"\r\n" +
		body + "\r\n";

	werr := writeall(MAILROOT + "/accounts/" + acct + "/compose", msg);
	if(werr != nil)
		return "error: send failed: " + werr;
	return "sent to " + toaddr + "\n";
}

cmdflag(argv: list of string): string
{
	if(argv == nil || hd argv == "")
		return "error: usage: mail flag <uid> <+/-flag>...";
	uid := hd argv;
	argv = tl argv;
	if(argv == nil)
		return "error: usage: mail flag <uid> <+/-flag>... " +
			"(e.g. mail flag 4412 seen)";
	# Build a diff-mode spec; bare flag names are made additive so
	# 'flag <uid> seen' adds \Seen without clearing other flags.
	spec := "";
	for(; argv != nil; argv = tl argv) {
		t := hd argv;
		if(t == "")
			continue;
		if(t[0] != '+' && t[0] != '-')
			t = "+" + t;
		if(spec != "")
			spec += " ";
		spec += t;
	}

	(acct, aerr) := firstaccount();
	if(aerr != nil)
		return "error: " + aerr;
	selerr := selectbox(acct, DEFBOX);
	if(selerr != nil)
		return "error: select " + DEFBOX + ": " + selerr;
	path := MAILROOT + "/accounts/" + acct + "/boxes/" + DEFBOX +
		"/" + uid + "/flags";
	werr := writeall(path, spec);
	if(werr != nil)
		return "error: flag failed: " + werr;
	return "flagged " + uid + " " + spec + "\n";
}

cmdreply(argv: list of string): string
{
	if(argv == nil || hd argv == "")
		return "error: usage: mail reply <uid> <draft body>";
	uid := hd argv;
	draft := join(tl argv, " ");
	if(strip(draft) == "")
		return "error: empty reply body";

	(acct, aerr) := firstaccount();
	if(aerr != nil)
		return "error: " + aerr;
	selerr := selectbox(acct, DEFBOX);
	if(selerr != nil)
		return "error: select " + DEFBOX + ": " + selerr;
	# mail9p's draft-reply fills Subject/To/In-Reply-To from the
	# original message and routes the SMTP send.
	path := MAILROOT + "/accounts/" + acct + "/boxes/" + DEFBOX +
		"/" + uid + "/draft-reply";
	werr := writeall(path, draft);
	if(werr != nil)
		return "error: reply failed: " + werr;
	return "replied to " + uid + "\n";
}

# Ensure `box` is the account's currently-selected mailbox.
selectbox(acct, box: string): string
{
	return writeall(MAILROOT + "/accounts/" + acct + "/ctl",
		"select " + box);
}

# UID directory names under a box (everything but the ctl file).
messageuids(boxpath: string): (list of string, string)
{
	(names, err) := listdir(boxpath);
	if(err != nil)
		return (nil, err);
	uids: list of string;
	for(; names != nil; names = tl names) {
		nm := hd names;
		if(nm == "ctl" || nm == "")
			continue;
		uids = nm :: uids;	# dirread order; reversed below
	}
	return (uids, nil);
}

# Account names under /n/mail/accounts.
listaccounts(): (list of string, string)
{
	return listdir(MAILROOT + "/accounts");
}

# The single configured account (or the first one).
firstaccount(): (string, string)
{
	(names, err) := listaccounts();
	if(err != nil)
		return ("", "cannot read mail accounts: " + err);
	if(names == nil)
		return ("", "no mail accounts configured " +
			"(add one in Keyring, then connect via mailctl)");
	return (hd names, nil);
}

# ── small filesystem helpers ───────────────────────────────────

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("cannot open %s: %r", path));
	data := "";
	buf := array[8192] of byte;
	for(;;) {
		nb := sys->read(fd, buf, len buf);
		if(nb < 0)
			return ("", sys->sprint("read %s: %r", path));
		if(nb == 0)
			break;
		data += string buf[0:nb];
	}
	return (data, nil);
}

writeall(path, data: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", path);
	return nil;
}

listdir(path: string): (list of string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	names: list of string;
	for(;;) {
		(nd, dirs) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++)
			names = dirs[i].name :: names;
	}
	return (names, nil);
}

# ── string helpers ─────────────────────────────────────────────

# Trim leading/trailing whitespace (incl. the trailing newline file
# reads usually carry).
strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' ||
	    s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' ||
	    s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

join(l: list of string, sep: string): string
{
	s := "";
	for(; l != nil; l = tl l) {
		if(s != "")
			s += sep;
		s += hd l;
	}
	return s;
}

strindex(s, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 0;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return i;
	return -1;
}
