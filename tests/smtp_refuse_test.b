implement SmtpRefuseTest;

#
# smtp(2) given what a caller may pass (appl/lib/smtp.b): addresses and
# a message that are not ones.
#
# An address was put between < and > on a command's line as it was: a
# recipient of "v@e.example>" CR LF "RCPT TO:<w@f.example" was two
# recipients, and callers pass addresses taken from received mail.  A
# message was sent whatever it held.  Both are looked at before anything
# is sent, so the answers here need no server.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "smtp.m";
	smtp: Smtp;

SmtpRefuseTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/smtp_refuse_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testOkaddr(t: ref T)
{
	good := array[] of {"alice@example.com", "a.b+tag@host.example", "postmaster", "user@[127.0.0.1]"};
	for(i := 0; i < len good; i++)
		t.assert(smtp->okaddr(good[i]), good[i] + " is an address");
	bad := array[] of {
		"", "v@e.example>\r\nRCPT TO:<w@f.example", "a@b\n", "a b@c", "Alice <alice@example.com>",
		"a@b>", "<a@b", "a@b\r", "a\tb@c", "a@b\0c", "a@b\u007f",
	};
	for(i = 0; i < len bad; i++)
		t.assert(!smtp->okaddr(bad[i]), sys->sprint("%q is not an address", bad[i]));
}

testOkheader(t: ref T)
{
	t.assert(smtp->okheader("Re: lunch on Friday"), "a subject is a header's value");
	t.assert(smtp->okheader(""), "so is an empty one");
	t.assert(!smtp->okheader("<1@x>\r\nX-Injected: yes"), "one with CR LF is not");
	t.assert(!smtp->okheader("a\nBcc: b@c"), "nor with a line feed");
	t.assert(!smtp->okheader("a\rb"), "nor a carriage return");
	t.assert(!smtp->okheader("a\0b"), "nor a NUL");
}

# what sendmail says with no connection: the refusal of its arguments
# comes before "connection is not open"
send(from: string, rcpts: list of string, msg: string): string
{
	(ok, e) := smtp->sendmail(from, rcpts, nil, msg :: nil);
	if(ok >= 0)
		return "sent";
	return e;
}

testSendmail(t: ref T)
{
	msg := "From: a@b.example\nTo: v@e.example\nSubject: x\n\nbody\n";
	e := send("a@b.example", "v@e.example>\r\nRCPT TO:<w@f.example" :: nil, msg);
	t.assert(has(e, "not an address"), "a recipient with a second RCPT in it is refused: " + e);
	e = send("a@b.example", "v@e.example" :: "Alice <a@x.example>" :: nil, msg);
	t.assert(has(e, "not an address"), "one bad recipient refuses the message: " + e);
	e = send("a@b.example>\r\nRCPT TO:<w@f.example", "v@e.example" :: nil, msg);
	t.assert(has(e, "not an address"), "a sender with a command in it is refused: " + e);
	e = send("a@b.example", "v@e.example" :: nil, "Subject: x\n\nbo\0dy\n");
	t.assert(has(e, "NUL"), "a message with a NUL in it is refused: " + e);
	e = send("a@b.example", "v@e.example" :: nil, "Subject: x\rBcc: w@f.example\n\nbody\n");
	t.assert(has(e, "carriage return"), "a header line with a carriage return in it is refused: " + e);
	# what is in order goes on to the connection, of which there is none
	e = send("a@b.example", "v@e.example" :: nil, "Subject: x\r\n\r\na\r.\rb\r\n");
	t.assert(has(e, "connection is not open"), "a carriage return in a body line is not refused: " + e);
	e = send("a@b.example", "v@e.example" :: nil, msg);
	t.assert(has(e, "connection is not open"), "nor an ordinary message: " + e);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	smtp = load Smtp Smtp->PATH;
	if(smtp == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Smtp->PATH);
		raise "fail:cannot load smtp";
	}

	run("Okaddr", testOkaddr);
	run("Okheader", testOkheader);
	run("Sendmail", testSendmail);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
