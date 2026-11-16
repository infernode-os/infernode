implement LogonUnlock;

#
# wm/logon's unlock without its screen, for tests/host/logon_unlock_test.sh:
#
#	logon_unlock direct addr password
#	logon_unlock cut n addr password
#	logon_unlock empty password
#
# direct: the secstore at addr.  cut: the same through a relay here that
# passes n of the server's records and then hangs up (3: the hello's
# answer, the OK, a file's size; the file itself never comes); later
# connections through it pass whole.  empty: a
# server here that answers the hello with a record of no bytes.
# Prints "UNLOCK err=<...> save=<...>".
#
#	logon_unlock slots user password recovery
#	logon_unlock mark user
#
# slots: gives the account a second factor's recovery slot (a data key
# wrapped under the recovery passphrase), as an enrolment's first step
# does, and prints the state twofaslot(2) then reports.  mark: records
# that the vault has been read under the data key.  For the states in
# which the login screen takes a vault that is under the password alone.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "secstore.m";

include "twofaslot.m";

LogonUnlock: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Logon: module
{
	unlock: fn(addr, pass: string): (string, string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	logon := load Logon "/dis/wm/logon.dis";
	if(logon == nil){
		sys->print("UNLOCK cannot load wm/logon: %r\n");
		raise "fail:load";
	}
	if(args != nil)
		args = tl args;
	if(args == nil)
		raise "fail:usage";
	addr, pass: string;
	case hd args {
	"slots" or "mark" =>
		secstore := load Secstore Secstore->PATH;
		ts := load Twofaslot Twofaslot->PATH;
		if(secstore == nil || ts == nil){
			sys->print("SLOTS cannot load: %r\n");
			raise "fail:load";
		}
		secstore->init();
		ts->init();
		if(hd args == "mark"){
			if(len args != 2)
				raise "fail:usage";
			e := ts->markenrolled(hd tl args);
			sys->print("STATE %s err=<%s>\n", ts->state(hd tl args), e);
			return;
		}
		if(len args != 4)
			raise "fail:usage";
		user := hd tl args;
		dk := array[32] of {* => byte 16r42};
		e := ts->writeslots(user, secstore->mkfilekey3(user, hd tl tl args), dk, nil, hd tl tl tl args, "");
		sys->print("STATE %s err=<%s>\n", ts->state(user), e);
		return;
	"direct" =>
		if(len args != 3)
			raise "fail:usage";
		addr = hd tl args;
		pass = hd tl tl args;
	"cut" =>
		if(len args != 4)
			raise "fail:usage";
		(c, a) := announce();
		spawn relay(c, hd tl tl args, int hd tl args);
		addr = a;
		pass = hd tl tl tl args;
	"empty" =>
		if(len args != 2)
			raise "fail:usage";
		(c, a) := announce();
		spawn emptyserver(c);
		addr = a;
		pass = hd tl args;
	* =>
		raise "fail:usage";
	}
	err, save: string;
	{
		(err, save) = logon->unlock(addr, pass);
	} exception e {
	"*" =>
		sys->print("UNLOCK exception: %s\n", e);
		return;
	}
	sys->print("UNLOCK err=<%s> save=<%s>\n", err, save);
}

announce(): (Sys->Connection, string)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		sys->print("UNLOCK announce: %r\n");
		raise "fail:announce";
	}
	fd := sys->open(c.dir + "/local", Sys->OREAD);
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		raise "fail:local";
	(nil, l) := sys->tokenize(string buf[0:n], "!\n");
	return (c, "tcp!127.0.0.1!" + hd tl l);
}

accept(c: Sys->Connection): (ref Sys->FD, ref Sys->FD)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0)
		return (nil, nil);
	return (sys->open(nc.dir + "/data", Sys->ORDWR), nc.cfd);
}

readn(fd: ref Sys->FD, n: int): array of byte
{
	a := array[n] of byte;
	for(o := 0; o < n;){
		k := sys->read(fd, a[o:], n - o);
		if(k <= 0)
			return nil;
		o += k;
	}
	return a;
}

# one record of ssl(3) as the wire has it, header and all
record(fd: ref Sys->FD): array of byte
{
	h := readn(fd, 2);
	if(h == nil)
		return nil;
	n := ((int h[0] & 16r7f) << 8) | int h[1];
	a := array[2 + n] of byte;
	a[0:] = h;
	if(n > 0){
		b := readn(fd, n);
		if(b == nil)
			return nil;
		a[2:] = b;
	}
	return a;
}

# The first connection is cut after n of the server's records; those
# after it (factotum's, if it was told to save here) pass whole.
relay(c: Sys->Connection, target: string, n: int)
{
	for(k := 0;; k++){
		(cfd, cctl) := accept(c);
		if(cfd == nil)
			return;
		(ok, t) := sys->dial(target, nil);
		if(ok < 0){
			sys->print("UNLOCK relay cannot dial %s: %r\n", target);
			return;
		}
		spawn pump(cfd, t.dfd);
		if(k == 0)
			cut(cfd, cctl, t, n);
		else
			spawn pump(t.dfd, cfd);
	}
}

cut(cfd, cctl: ref Sys->FD, t: Sys->Connection, n: int)
{
	for(i := 0; i < n; i++){
		r := record(t.dfd);
		if(r == nil)
			break;
		sys->write(cfd, r, len r);
	}
	sys->sleep(200);	# what was passed is read before the end comes
	sys->fprint(cctl, "hangup");
	sys->fprint(t.cfd, "hangup");
}

pump(from, dst: ref Sys->FD)
{
	buf := array[8192] of byte;
	while((n := sys->read(from, buf, len buf)) > 0)
		if(sys->write(dst, buf, n) != n)
			break;
}

emptyserver(c: Sys->Connection)
{
	(fd, ctl) := accept(c);
	if(fd == nil)
		return;
	record(fd);	# the hello
	sys->write(fd, array[] of {byte 16r80, byte 0}, 2);
	record(fd);
	sys->fprint(ctl, "hangup");
}
