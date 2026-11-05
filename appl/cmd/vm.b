implement Vm;

#
# vm -- run a command in another Dis VM (#944).
#
#	vm			what VMs there are, and what is in each
#	vm n cmd [arg ...]	run cmd in VM n; print its pid
#
# On the native kernel each core can run a Dis VM of its own (#X,
# devvm.c): a command in VM 1 runs alongside one in VM 0 on another
# core, sharing nothing with it but the kernel -- the files, pipes and
# 9P every Inferno program already talks through. The command gets this
# process's namespace, environment and file descriptors, as a spawned
# one would, so its output comes out where vm's would.
#
# Which VM a command goes to is the caller's choice; this does not
# decide. VM 0 is the boot VM, the desktop's, and the only one with
# $Tk and $Draw.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;

Vm: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Dev: con "#X/vm";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	argv = tl argv;
	if(argv == nil){
		listvms();
		return;
	}
	if(tl argv == nil)
		usage();
	(n, rest) := str->toint(hd argv, 10);
	if(rest != "" || n < 0)
		usage();
	cmd := hd tl argv;
	if(len cmd < 4 || cmd[len cmd - 4:] != ".dis")
		cmd += ".dis";
	if(cmd[0] != '/' && (len cmd < 2 || cmd[0:2] != "./"))
		cmd = "/dis/" + cmd;

	fd := sys->open(sys->sprint("%s/%d/run", Dev, n), Sys->ORDWR);
	if(fd == nil)
		fail(sys->sprint("cannot open VM %d: %r", n));
	b := array of byte str->quoted(cmd :: tl tl argv);
	if(sys->write(fd, b, len b) != len b)
		fail(sys->sprint("%s: %r", cmd));
	buf := array[32] of byte;
	r := sys->pread(fd, buf, len buf, big 0);
	if(r > 0)
		sys->print("%s", string buf[0:r]);
}

listvms()
{
	ctl := readfile(Dev + "/ctl");
	if(ctl == nil)
		fail(sys->sprint("no VMs here: %r"));
	sys->print("%s", ctl);
	for(i := 0; ; i++){
		s := readfile(sys->sprint("%s/%d/status", Dev, i));
		if(s == nil)
			break;
		sys->print("%s", s);
	}
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: vm [n cmd [arg ...]]\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "vm: %s\n", s);
	raise "fail:error";
}
