implement Mail9pHold;

#
# tests/host/mail9p_hostile_test.sh's helper: it holds descriptors on an
# account's ctl, on a message's subject and on its compose, has the
# account disconnected and another connected (the two ctl requests given
# as arguments), and then uses the descriptors, saying what each did.
#
# usage: mail9p_hold account 'disconnect account' 'connect other ...'
#

include "sys.m";
	sys: Sys;
include "draw.m";

Mail9pHold: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(len args != 3) {
		sys->print("usage: mail9p_hold account disconnect connect\n");
		return;
	}
	acct := hd args;
	discon := hd tl args;
	conn := hd tl tl args;
	a := "/mnt/mail/accounts/" + acct;
	ctl := sys->open(a + "/ctl", Sys->OREAD);
	comp := sys->open(a + "/compose", Sys->OWRITE);
	subj := sys->open(a + "/boxes/INBOX/101/subject", Sys->OREAD);
	if(ctl == nil || comp == nil || subj == nil) {
		sys->print("hold: open: %r\n");
		return;
	}
	buf := array[256] of byte;
	n := sys->pread(subj, buf, len buf, big 0);
	if(n < 0)
		n = 0;
	sys->print("hold: before: subject reads: %s", string buf[0:n]);

	root := sys->open("/mnt/mail/ctl", Sys->OWRITE);
	if(root == nil || sys->fprint(root, "%s", discon) < 0)
		sys->print("hold: %s: %r\n", discon);
	if(root == nil || sys->fprint(root, "%s", conn) < 0)
		sys->print("hold: %s: %r\n", conn);

	n = sys->pread(ctl, buf, len buf, big 0);
	if(n < 0)
		sys->print("hold: after: ctl: error: %r\n");
	else
		sys->print("hold: after: ctl reads: %s", string buf[0:n]);
	n = sys->pread(subj, buf, len buf, big 0);
	if(n < 0)
		sys->print("hold: after: subject: error: %r\n");
	else
		sys->print("hold: after: subject reads: %s", string buf[0:n]);
	m := array of byte "From: alice@example.com\nTo: carol@example.org\nSubject: through the old descriptor\n\nhi\n";
	if(sys->write(comp, m, len m) != len m)
		sys->print("hold: after: compose: error: %r\n");
	else
		sys->print("hold: after: compose: write accepted\n");
	comp = nil;
	sys->sleep(1500);
	sys->print("hold: done\n");
}
