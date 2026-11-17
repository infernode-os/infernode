implement MailconnTest;

#
# mailconn(2), a mail server's connection under deadlines and bounds
# (appl/lib/mailconn.b), against servers of the test's own on the
# loopback: one that says nothing, one that never ends its line, one
# that promises more bytes than it sends, one that takes STARTTLS's
# first step and stops.
#
# imap(2), smtp(2) and pop3(2) read their servers with no limit of time
# or size: a server that stopped answering held its caller for ever (in
# mail9p, every account's files), and a line was as long as the server
# made it.  Each read here ends by its deadline, with the connection
# closed and its processes gone.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "keyring.m";
include "tls.m";
include "mailconn.m";
	mailconn: Mailconn;
	Link: import mailconn;

MailconnTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mailconn_test.b";

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

# A server on a loopback port: it takes one connection, writes what it
# is given (if anything), then keeps the connection open, saying
# nothing, until it is told to go (hangup non-zero: it closes at once).
server(text: array of byte, hangup: int, addrc: chan of string, done: chan of int)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0) {
		addrc <-= nil;
		return;
	}
	fd := sys->open(c.dir + "/local", Sys->OREAD);
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0) {
		addrc <-= nil;
		return;
	}
	local := string buf[0:n];
	while(local != nil && (local[len local-1] == '\n' || local[len local-1] == ' '))
		local = local[0:len local-1];
	addrc <-= "tcp!" + local;
	(lok, nc) := sys->listen(c);
	if(lok < 0)
		return;
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil)
		return;
	if(len text > 0)
		sys->write(dfd, text, len text);
	if(!hangup)
		<-done;
}

start(t: ref T, text: string, hangup: int): (string, chan of int)
{
	addrc := chan of string;
	done := chan[1] of int;
	spawn server(array of byte text, hangup, addrc, done);
	addr := <-addrc;
	if(addr == nil)
		t.skip(sys->sprint("no loopback to announce on: %r"));
	return (addr, done);
}

nprogs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;) {
		(c, nil) := sys->dirread(fd);
		if(c <= 0)
			break;
		n += c;
	}
	return n;
}

testLines(t: ref T)
{
	(addr, done) := start(t, "one\r\ntwo\nthree, with more after\r\n0123456789tail\n", 0);
	(c, err) := Link.dial(addr, "localhost", Mailconn->CLEAR, nil, 5000);
	t.assert(err == nil && c != nil, "a server in clear is dialled: " + err);
	if(c == nil)
		return;
	c.deadline(3000, 0);
	(s, e) := c.getline(100);
	t.assert(e == nil, "a line is read: " + e);
	t.assertseq(s, "one", "without its CR LF");
	(s, e) = c.getline(100);
	t.assertseq(s, "two", "or its bare LF");
	(s, e) = c.getline(100);
	t.assertseq(s, "three, with more after", "the next line is the next");
	(b, be) := c.getbytes(10);
	t.assert(be == nil && string b == "0123456789", "ten bytes are the next ten: " + be);
	(s, e) = c.getline(100);
	t.assertseq(s, "tail", "and the line goes on after them");
	e = c.write(array of byte "hello\r\n");
	t.assert(e == nil, "a write is done: " + e);
	c.close();
	(nil, e) = c.getline(100);
	t.assert(e != nil, "a closed connection reads nothing");
	done <-= 1;
}

testSilence(t: ref T)
{
	before := nprogs();
	(addr, done) := start(t, "", 0);
	(c, err) := Link.dial(addr, "localhost", Mailconn->CLEAR, nil, 5000);
	t.assert(err == nil && c != nil, "a silent server is dialled: " + err);
	if(c == nil)
		return;
	c.deadline(400, 0);
	t0 := sys->millisec();
	(nil, e) := c.getline(100);
	dt := sys->millisec() - t0;
	t.assertseq(e, "timed out", "a line that never comes is given up at the deadline");
	t.assert(dt >= 300 && dt < 3000, sys->sprint("after about 400 ms (%d)", dt));
	t0 = sys->millisec();
	(nil, e) = c.getline(100);
	t.assert(e != nil && sys->millisec() - t0 < 200, "and the connection is over: the next read fails at once");
	t.assertseq(c.write(array of byte "x"), "timed out", "as does a write, with the reason");
	done <-= 1;
	sys->sleep(300);
	after := nprogs();
	t.assert(before < 0 || after <= before, sys->sprint("no process is left behind (%d before, %d after)", before, after));

	# the whole of an exchange has a limit too
	(addr, done) = start(t, "", 0);
	(c, err) = Link.dial(addr, "localhost", Mailconn->CLEAR, nil, 5000);
	if(c == nil) {
		t.error("second dial: " + err);
		return;
	}
	c.deadline(0, 400);
	t0 = sys->millisec();
	(nil, e) = c.getbytes(10);
	dt = sys->millisec() - t0;
	t.assert(e == "timed out" && dt < 3000, sys->sprint("bytes that never come are given up too (%s, %d ms)", e, dt));
	done <-= 1;
}

testBounds(t: ref T)
{
	long := "";
	for(i := 0; i < 50; i++)
		long += "0123456789";
	(addr, done) := start(t, long, 0);
	(c, err) := Link.dial(addr, "localhost", Mailconn->CLEAR, nil, 5000);
	if(c == nil) {
		t.error("dial: " + err);
		return;
	}
	c.deadline(3000, 0);
	t0 := sys->millisec();
	(nil, e) := c.getline(100);
	t.assertseq(e, "line too long", "a line of 500 bytes with no end is refused where 100 are allowed");
	t.assert(sys->millisec() - t0 < 2000, "when the bytes have come, not at the deadline");
	done <-= 1;

	# a count of a gigabyte, and ten bytes: no array of a gigabyte
	(addr, done) = start(t, "0123456789", 1);
	(c, err) = Link.dial(addr, "localhost", Mailconn->CLEAR, nil, 5000);
	if(c == nil) {
		t.error("dial: " + err);
		return;
	}
	c.deadline(3000, 0);
	b: array of byte;
	{
		(b, e) = c.getbytes(1024*1024*1024);
	} exception x {
	"*" =>
		e = "exception: " + x;
	}
	t.assertseq(e, "connection closed", "a gigabyte promised and ten bytes sent is an error, not memory");
	t.assert(b == nil, "and no bytes");
}

testDial(t: ref T)
{
	(c, err) := Link.dial("tcp!127.0.0.1!1", "localhost", Mailconn->CLEAR, nil, 3000);
	t.assert(c == nil && err != nil, "a port nobody listens on is an error: " + err);

	# a server that greets and then says nothing to STARTTLS
	before := nprogs();
	(addr, done) := start(t, "* OK ready\r\n", 0);
	t0 := sys->millisec();
	(c, err) = Link.dial(addr, "localhost", Mailconn->IMAPSTARTTLS, nil, 500);
	dt := sys->millisec() - t0;
	t.assert(c == nil, "a server that never answers STARTTLS is not connected to");
	t.assertseq(err, "timed out", "and the dial ends at its deadline");
	t.assert(dt >= 400 && dt < 3000, sys->sprint("after about 500 ms (%d)", dt));
	done <-= 1;
	sys->sleep(300);
	after := nprogs();
	t.assert(before < 0 || after <= before, sys->sprint("no process is left behind (%d before, %d after)", before, after));

	# one that refuses it
	(addr, done) = start(t, "* OK ready\r\nS000 NO not here\r\n", 0);
	(c, err) = Link.dial(addr, "localhost", Mailconn->IMAPSTARTTLS, nil, 3000);
	t.assert(c == nil && err == "STARTTLS refused: NO not here", "a refused STARTTLS is refused: " + err);
	done <-= 1;

	# an SMTP server whose reply is not one
	(addr, done) = start(t, "hello there\r\n", 0);
	(c, err) = Link.dial(addr, "localhost", Mailconn->SMTPSTARTTLS, "client.example", 3000);
	t.assert(c == nil && err == "greeting: malformed reply", "an SMTP greeting with no code is refused: " + err);
	done <-= 1;
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
	mailconn = load Mailconn Mailconn->PATH;
	if(mailconn == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Mailconn->PATH);
		raise "fail:cannot load mailconn";
	}
	err := mailconn->init();
	if(err != nil) {
		sys->fprint(sys->fildes(2), "mailconn: %s\n", err);
		raise "fail:mailconn init";
	}

	run("Lines", testLines);
	run("Silence", testSilence);
	run("Bounds", testBounds);
	run("Dial", testDial);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
