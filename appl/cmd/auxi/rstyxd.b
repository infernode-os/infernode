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

# Bound attacker-controlled allocation after authentication.  A certificate
# grants the right to request a command, not an unbounded share of the node's
# heap.  This is deliberately much larger than a normal cpu command line.
Maxargs: con 64*1024;

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

	pid := sys->pctl(0, nil);
	wfd := sys->open("#p/" + string pid + "/wait", Sys->OREAD);
	ctlfd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(wfd == nil || ctlfd == nil)
		err(sys->sprint("cannot open session process files: %r"));

	# Export a restricted copy of the server namespace from a trusted
	# helper, then enter a NEWNS rooted at an empty directory and mount
	# that export at /.  Bind-replacing a key file in the command's own
	# namespace is reversible with unmount; this two-process shape is not.
	# If the command unmounts / it falls into the empty directory, while
	# /usr and the server /dev are already empty in the export.  /prog is
	# retained because the shell needs its wait files to run child commands;
	# NODEVS below still prevents attaching a fresh #p.
	base := "/tmp/rstyxd-" + string pid + "-" + string sys->millisec();
	jail := base + "-root";
	emptyusr := base + "-usr";
	emptydev := base + "-dev";
	if(mkdir(jail) < 0 || mkdir(emptyusr) < 0 ||
	   mkdir(emptydev) < 0)
		err(sys->sprint("cannot make restricted namespace: %r"));
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		err(sys->sprint("cannot make namespace pipe: %r"));
	nssync := chan[1] of string;
	spawn serverexport(p[1], emptyusr, emptydev, jail, nssync);
	p[1] = nil;
	e := <-nssync;
	if(e != nil)
		err(e);

	if(sys->chdir(jail) < 0 || sys->pctl(Sys->NEWNS, nil) < 0)
		err(sys->sprint("cannot enter empty namespace: %r"));
	if(sys->mount(p[0], nil, "/", Sys->MREPL|Sys->MCREATE, "") < 0)
		err(sys->sprint("cannot mount restricted server namespace: %r"));
	p[0] = nil;

	if(sys->mount(fd, nil, "/n/client", Sys->MREPL|Sys->MCREATE, "") < 0)
		err(sys->sprint("cannot mount connection on /n/client: %r"));

	if(sys->bind("/n/client/dev", "/dev", Sys->MREPL) < 0)
		err(sys->sprint("cannot bind /n/client/dev to /dev: %r"));

	fd = sys->open("/dev/cons", sys->OREAD);
	if(fd == nil || sys->dup(fd.fd, 0) < 0)
		err(sys->sprint("cannot open caller console for reading: %r"));
	fd = sys->open("/dev/cons", sys->OWRITE);
	if(fd == nil || sys->dup(fd.fd, 1) < 0 || sys->dup(fd.fd, 2) < 0)
		err(sys->sprint("cannot open caller console for writing: %r"));
	fd = nil;

	# All intended devices are already names in /dev, including the
	# caller's draw, keyboard and pointer files.  From here on, a command
	# must not reattach #c, #S, #G, #p or any other omitted device.
	if(sys->pctl(Sys->NODEVS, nil) < 0)
		err(sys->sprint("cannot disable device attachment: %r"));
	sync := chan of int;
	spawn runcmd(mod, cmd, args, sync);
	cpid := <-sync;
	if(cpid < 0) {
		killsession(ctlfd);
		err("cannot isolate command file descriptors");
	}
	spawn watchcaller(ctlfd);
	waitchild(wfd, cpid);
	killsession(ctlfd);
}

mkdir(path: string): int
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r700);
	if(fd == nil)
		return -1;
	return 0;
}

serverexport(fd: ref Sys->FD, emptyusr, emptydev, jail: string,
		sync: chan of string)
{
	if(sys->pctl(Sys->FORKNS, nil) < 0) {
		sync <-= sys->sprint("cannot fork server namespace: %r");
		return;
	}
	if(sys->bind(emptyusr, "/usr", Sys->MREPL) < 0 ||
	   sys->bind(emptydev, "/dev", Sys->MREPL) < 0) {
		sync <-= sys->sprint("cannot restrict server namespace: %r");
		return;
	}
	# A machine or desktop factotum is a credential oracle even though its
	# ctl listing elides secrets: its rpc files can use the loaded keys.
	# Mask both locations used by bare-metal startup when they exist.
	if(hideifpresent(emptyusr, "/mnt/factotum") < 0 ||
	   hideifpresent(emptyusr, "/tmp/factotum") < 0) {
		sync <-= sys->sprint("cannot hide server factotum: %r");
		return;
	}
	# Do not export aliases for the masking directories themselves.  A bind
	# keeps its Chan after the source name is removed; the resulting empty
	# directory remains readable but refuses creation, so a command cannot
	# populate /usr or a masked factotum through their /tmp source qid.
	if(sys->remove(emptyusr) < 0 || sys->remove(emptydev) < 0) {
		sync <-= sys->sprint("cannot seal restricted namespace: %r");
		return;
	}
	# The writable boot filesystem must not be present in the exported tree.
	sys->unmount(nil, "/n/dos");
	if(sys->pctl(Sys->NEWFD, fd.fd :: 2 :: nil) < 0) {
		sync <-= sys->sprint("cannot isolate namespace exporter fds: %r");
		return;
	}
	fd = sys->fildes(fd.fd);
	sync <-= nil;
	sys->export(fd, "/", Sys->EXPWAIT);
	sys->unmount(nil, "/usr");
	sys->unmount(nil, "/dev");
	sys->unmount(nil, "/mnt/factotum");
	sys->unmount(nil, "/tmp/factotum");
	sys->remove(jail);
}

hideifpresent(empty, path: string): int
{
	(ok, nil) := sys->stat(path);
	if(ok < 0)
		return 0;
	return sys->bind(empty, path, Sys->MREPL);
}

#
# The command runs in a child, and its end is read from the wait file,
# not from init returning: a command can end its process with exit (sh
# -c does), which no exception handler sees.
#
runcmd(mod: Command, cmd: string, args: list of string, sync: chan of int)
{
	# The command receives only its console descriptors, not the session's
	# wait/control descriptors or either export transport.
	if(sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil) < 0) {
		sys->fprint(stderr, "rstyxd: cannot isolate command file descriptors: %r\n");
		sync <-= -1;
		return;
	}
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

watchcaller(ctlfd: ref Sys->FD)
{
	sys->pctl(Sys->NEWFD, ctlfd.fd :: nil);
	ctlfd = sys->fildes(ctlfd.fd);
	for(;;) {
		sys->sleep(POLL);
		(ok, nil) := sys->stat("/n/client");
		if(ok < 0) {
			killsession(ctlfd);
			return;
		}
	}
}

killsession(ctlfd: ref Sys->FD)
{
	if(ctlfd != nil)
		sys->fprint(ctlfd, "killgrp");
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
		if(c[0] < byte '0' || c[0] > byte '9')
			return nil;
	}
	nb := int string buf[0:i];
	if(nb <= 0)
		return nil;
	if(nb > Maxargs)
		err("command line exceeds 64 KiB");
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
