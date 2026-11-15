implement Auth9ShortTest;

#
# auth9(2), Plan 9's authentication messages: each is of a fixed length
# and is unpacked by looking at fixed places in it, and one shorter than
# its length is no message (unpack gives nil), where it was an array
# bounds error in whoever unpacked it.  An authentication server's answer
# to a ticket request may be of a length it states (AuthOKvar): that
# length is held to what was asked for, two tickets, and the answer must
# be exactly that (it was held to 4096, and ten bytes were sliced and
# decrypted as two tickets).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "auth9.m";
	auth9: Auth9;
	Ticket, Ticketreq, Authenticator, Passwordreq: import auth9;
include "testing.m";
	testing: Testing;
	T: import testing;

Auth9ShortTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auth9_short_test.b";

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

# no key: the messages are taken as they are.  With one they are DES
# under it, by $Crypt, which the hosted emulator is not built with; the
# lengths looked at are the same either way.
key: array of byte;

# 1 if unpacking n bytes of each message gives nil and raises nothing
shortok(n: int): string
{
	a := array[n] of {* => byte 16r41};
	{
		(nil, t) := Ticket.unpack(a, key);
		if(t != nil && n < Auth9->TICKETLEN)
			return sys->sprint("a ticket of %d bytes was unpacked", n);
		(nil, tr) := Ticketreq.unpack(a);
		if(tr != nil && n < Auth9->TICKREQLEN)
			return sys->sprint("a ticket request of %d bytes was unpacked", n);
		(nil, au) := Authenticator.unpack(a, key);
		if(au != nil && n < Auth9->AUTHENTLEN)
			return sys->sprint("an authenticator of %d bytes was unpacked", n);
		(nil, pr) := Passwordreq.unpack(a, key);
		if(pr != nil && n < Auth9->PASSREQLEN)
			return sys->sprint("a password request of %d bytes was unpacked", n);
	} exception e {
	"*" =>
		return sys->sprint("unpacking %d bytes raised %s", n, e);
	}
	return nil;
}

testShort(t: ref T)
{
	for(n := 0; n <= Auth9->TICKREQLEN + 2; n++){
		e := shortok(n);
		if(e != nil){
			t.error(e);
			break;
		}
	}
	# whole messages still unpack
	tk := ref Ticket(Auth9->AuthTc, array[Auth9->CHALLEN] of {* => byte 9}, "client", "server", array[Auth9->DESKEYLEN] of {* => byte 5});
	(got, u) := Ticket.unpack(tk.pack(key), key);
	t.assert(got == Auth9->TICKETLEN && u != nil && u.cuid == "client" && u.suid == "server", "a whole ticket unpacks to what was packed");
}

# an authentication server on a pipe: reads the ticket request, answers with reply
server(fd: ref Sys->FD, reply: array of byte)
{
	buf := array[Auth9->TICKREQLEN] of byte;
	sys->readn(fd, buf, len buf);
	sys->write(fd, reply, len reply);
}

# _asgetticket against a server answering with reply: "ticket", "none", or what it raised
getticket(reply: array of byte): string
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return "pipe";
	spawn server(p[1], reply);
	p[1] = nil;
	tr := ref Ticketreq(Auth9->AuthTreq, "authid", "dom", array[Auth9->CHALLEN] of {* => byte 1}, "host", "user");
	{
		(tk, nil) := auth9->_asgetticket(p[0], tr, key);
		if(tk != nil)
			return "ticket";
		return "none";
	} exception e {
	"*" =>
		return "raised " + e;
	}
}

okvar(n: int, body: array of byte): array of byte
{
	a := array[6 + len body] of byte;
	a[0] = byte Auth9->AuthOKvar;
	a[1:] = array of byte sys->sprint("%.5d", n);
	a[6:] = body;
	return a;
}

testTicketReply(t: ref T)
{
	filler := array[4096] of {* => byte 16r42};
	# a stated length shorter than two tickets, at each end, and longer
	t.assertseq(getticket(okvar(10, filler[0:10])), "none", "an answer of 10 bytes");
	t.assertseq(getticket(okvar(100, filler[0:100])), "none", "an answer of 100 bytes");
	t.assertseq(getticket(okvar(2*Auth9->TICKETLEN - 1, filler[0:2*Auth9->TICKETLEN - 1])), "none", "an answer one byte short of two tickets");
	t.assertseq(getticket(okvar(4096, filler)), "none", "an answer of 4096 bytes");
	# two tickets, either way of saying so, are taken
	two := array[1 + 2*Auth9->TICKETLEN] of {* => byte 16r42};
	two[0] = byte Auth9->AuthOK;
	t.assertseq(getticket(two), "ticket", "an answer of two tickets");
	t.assertseq(getticket(okvar(2*Auth9->TICKETLEN, filler[0:2*Auth9->TICKETLEN])), "ticket", "an answer of two tickets, its length stated");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	auth9 = load Auth9 Auth9->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || auth9 == nil){
		sys->fprint(sys->fildes(2), "cannot load testing or auth9: %r\n");
		raise "fail:load";
	}
	auth9->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Short", testShort);
	run("TicketReply", testTicketReply);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
