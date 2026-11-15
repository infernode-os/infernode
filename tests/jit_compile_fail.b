implement JitCompileFail;

#
# Modules a JIT will not compile, loaded again and again, and what is
# left afterwards.  Run in an emulator of its own by tests/host/
# jit_compile_fail_test.sh, which makes the modules (in the directory
# given) and reads the lines printed.
#
# The code generators raise for an instruction they will not compile,
# from the middle of compile(), which has no error label: what it had
# allocated was never freed (megabytes of the kernel's pool for each
# load of one large module with one such instruction).  An operand that
# indexes one of the compiler's tables -- a frame's type number, a
# movpc's pc, a branch whose destination is not an immediate, a case or
# goto table's place and its pcs -- was not looked at, and the compiler
# read or wrote wherever the file said (a fault in the emulator's own C,
# raised as "segmentation violation").  And a compile that gave up after
# generating the code left the module, which is then interpreted, with
# addresses in its case and goto tables.
#
# usage: jit_compile_fail dir count
#	dir/bad_*.dis are loaded count times each;
#	dir/ok_must.dis is a module that must be compiled, and is;
#	dir/mod_must.dis is jit_compile_fail_mod.dis saying it must be
#	compiled, which the amd64 JIT cannot do;
#	then jit_compile_fail_mod.dis itself is run.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "readdir.m";
	readdir: Readdir;

JitCompileFail: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Any: module
{
};

Ok: module
{
	f:	fn(a: int): int;
};

Tab: module
{
	run:	fn(): string;
};

MOD: con "/dis/tests/jit_compile_fail_mod.dis";

membuf: array of byte;
memfd: ref Sys->FD;

# the main pool's current size, allocating nothing
mainsize(): int
{
	n := sys->pread(memfd, membuf, len membuf, big 0);
	# lines of "cursize maxsize hw nalloc nfree nbrk max name"
	start := 0;
	for(i := 0; i < n; i++){
		if(membuf[i] != byte '\n')
			continue;
		if(i >= 4 && membuf[i-4] == byte 'm' && membuf[i-3] == byte 'a'
		&& membuf[i-2] == byte 'i' && membuf[i-1] == byte 'n'){
			v := 0;
			j := start;
			while(j < i && membuf[j] == byte ' ')
				j++;
			while(j < i && membuf[j] >= byte '0' && membuf[j] <= byte '9')
				v = v*10 + int membuf[j++] - '0';
			return v;
		}
		start = i+1;
	}
	return -1;
}

# The JIT off or on (/dev/jit); what it was, or nil.  A module whose
# header says it must be compiled is refused when compile() declines
# it only while the JIT is off: with it on, such a module is interpreted.
jit(v: string): string
{
	fd := sys->open("/dev/jit", Sys->ORDWR);
	if(fd == nil)
		return nil;
	buf := array[16] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	b := array of byte v;
	if(sys->pwrite(fd, b, len b, big 0) != len b)
		return nil;
	return string buf[0:n];
}

# what one load of path came to
load1(path: string): string
{
	{
		m := load Any path;
		if(m == nil)
			return sys->sprint("nil: %r");
		return "loaded";
	} exception e {
	"*" =>
		return "raised: " + e;
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil || len args != 3){
		sys->print("SKIP usage: jit_compile_fail dir count\n");
		return;
	}
	dir := hd tl args;
	count := int hd tl tl args;
	memfd = sys->open("/dev/memory", Sys->OREAD);
	if(memfd == nil){
		sys->print("SKIP no /dev/memory: %r\n");
		return;
	}
	membuf = array[4096] of byte;

	(a, n) := readdir->init(dir, Readdir->NAME);
	for(i := 0; i < n; i++){
		name := a[i].name;
		if(len name < 8 || name[0:4] != "bad_" || name[len name-4:] != ".dis")
			continue;
		path := dir + "/" + name;
		# the first load is not counted: its error string and the like stay
		last := load1(path);
		raised := nilret := loaded := 0;
		before := mainsize();
		for(j := 0; j < count; j++){
			last = load1(path);
			if(last == "loaded")
				loaded++;
			else if(len last > 4 && last[0:4] == "nil:")
				nilret++;
			else
				raised++;
		}
		grew := mainsize() - before;
		sys->print("BAD %s raised %d nil %d loaded %d grew %d: %s\n",
			name[4:len name-4], raised, nilret, loaded, grew, last);
	}

	was := jit("0");
	if(was == nil){
		sys->print("SKIP cannot turn the JIT off: %r\n");
		return;
	}

	# a module not loaded before is compiled and runs
	{
		ok := load Ok dir + "/ok_must.dis";
		if(ok == nil)
			sys->print("OK nil: %r\n");
		else
			sys->print("OK %d %d %d %d\n", ok->f(1000001), ok->f(3000007), ok->f(5), ok->f(4));
	} exception e {
	"*" =>
		sys->print("OK raised: %s\n", e);
	}

	# is the module with the large frame one this JIT cannot compile?
	sys->print("MUST %s\n", load1(dir + "/mod_must.dis"));
	jit(was);

	{
		tab := load Tab MOD;
		if(tab == nil)
			sys->print("TABLES nil: %r\n");
		else
			sys->print("TABLES %s\n", tab->run());
	} exception e {
	"*" =>
		sys->print("TABLES raised: %s\n", e);
	}
	sys->print("DONE\n");
}
