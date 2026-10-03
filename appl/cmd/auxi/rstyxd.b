implement Rstyxd;

include "sys.m";
include "draw.m";
include "sh.m";
include "string.m";

sys: Sys;
str: String;
stderr: ref Sys->FD;

Rstyxd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

#
# argv is a list of Inferno supported algorithms from Security->Auth
#
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if (str == nil)
		badmod(String->PATH);

	fd := sys->fildes(0);
	stderr = sys->fildes(2);
	sys->pctl(sys->FORKFD, fd.fd :: nil);

	args := readargs(fd);
	if(args == nil)
		err(sys->sprint("error reading arguments: %r"));

	cmd := hd args;
	s := "";
	for (a := args; a != nil; a = tl a)
		s += hd a + " ";
	sys->fprint(stderr, "rstyxd: cmd: %s\n", s);
	s = nil;
	file: string;
	if(cmd == "sh")
		file = "/dis/sh.dis";
	else
		file = cmd + ".dis";
	mod := load Command file;
	if(mod == nil){
		mod = load Command "/dis/"+file;
		if(mod == nil)
			badmod("/dis/"+file);
	}

	# The session is its own process group: whatever it starts ends
	# with it (killsession).
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->FORKENV, nil);

	if(sys->mount(fd, nil, "/n/client", Sys->MREPL, "") < 0)
		err(sys->sprint("cannot mount connection on /n/client: %r"));

	if(sys->bind("/n/client/dev", "/dev", Sys->MBEFORE) < 0)
		err(sys->sprint("cannot bind /n/client/dev to /dev: %r"));

	fd = sys->open("/dev/cons", sys->OREAD);
	sys->dup(fd.fd, 0);
	fd = sys->open("/dev/cons", sys->OWRITE);
	sys->dup(fd.fd, 1);
	sys->dup(fd.fd, 2);
	fd = nil;

	pid := sys->pctl(0, nil);
	wfd := sys->open("#p/" + string pid + "/wait", Sys->OREAD);
	if(wfd == nil)
		wfd = sys->open("/prog/" + string pid + "/wait", Sys->OREAD);
	if(wfd == nil)
		err(sys->sprint("cannot open wait file: %r"));
	sync := chan of int;
	spawn runcmd(mod, cmd, args, sync);
	cpid := <-sync;
	spawn watchcaller(pid);
	waitchild(wfd, cpid);
	killsession(pid);
}

#
# The command runs in a child, and its end is read from the wait file,
# not from init returning: a command can end its process with exit (sh
# -c does), which no exception handler sees.
#
runcmd(mod: Command, cmd: string, args: list of string, sync: chan of int)
{
	sync <-= sys->pctl(0, nil);
	{
		mod->init(nil, args);
	} exception e {
	"fail:*" =>
		;	# the command's own exit status
	"*" =>
		sys->fprint(stderr, "rstyxd: %s: %s\n", cmd, e);
	}
}

waitchild(wfd: ref Sys->FD, cpid: int)
{
	buf := array[Sys->WAITLEN] of byte;
	for(;;) {
		n := sys->read(wfd, buf, len buf);
		if(n <= 0)
			return;
		(nil, l) := sys->tokenize(string buf[0:n], " ");
		if(l != nil && int hd l == cpid)
			return;
	}
}

#
# A session ends when its command does, or when the caller goes away,
# and everything it started ends with it.
#
# Without this the caller's export (cpu -> sys->export(..., EXPWAIT))
# lasted as long as anything on this machine still held the mount of it:
# cpu node sh -c 'echo hi' printed and never returned, a background
# job left over from a session kept reading the caller's /dev/cons, and
# programs from sessions whose caller had gone kept running for nobody
# -- enough of them starved a Raspberry Pi (#732).
#
# The caller has gone when its namespace no longer answers: a stat of
# /n/client every few seconds is one small round trip, and fails once
# the connection is hung up.
#
POLL: con 5000;

watchcaller(pid: int)
{
	for(;;) {
		sys->sleep(POLL);
		(ok, nil) := sys->stat("/n/client");
		if(ok < 0) {
			killsession(pid);
			return;
		}
	}
}

killsession(pid: int)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

readargs(fd: ref Sys->FD): list of string
{
	buf := array[1024] of byte;
	c := array[1] of byte;
	for(i:=0; ; i++){
		if(i>=len buf || sys->read(fd, c, 1)!=1)
			return nil;
		buf[i] = c[0];
		if(c[0] == byte '\n')
			break;
	}
	nb := int string buf[0:i];
	if(nb <= 0)
		return nil;
	args := readn(fd, nb);
	if (args == nil)
		return nil;
	return str->unquoted(string args[0:nb]);
}

readn(fd: ref Sys->FD, nb: int): array of byte
{
	buf:= array[nb] of byte;
	if(sys->readn(fd, buf, nb) != nb)
		return nil;
	return buf;
}


err(s: string)
{
	sys->fprint(stderr, "rstyxd: %s\n", s);
	raise "fail:error";
}

badmod(s: string)
{
	sys->fprint(stderr, "rstyxd: can't load %s: %r\n", s);
	raise "fail:load";
}
