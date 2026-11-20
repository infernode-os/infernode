implement LoadHeapfull;

#
# Loads and channels that cannot be made, and what the kernel's pool has
# afterwards.  Run in an emulator of its own (it fills the Dis heap) by
# tests/host/load_heapfull_test.sh, which reads the lines printed.
#
# A module being loaded is built in the kernel's pool (its instructions,
# its types, a copy of the file); its data and the Modlink a program holds
# it by are in the Dis heap, and making those raises when the heap is
# full.  Raised from the middle of the loader, everything built so far
# stayed in the kernel's pool for good, and a module whose Modlink could
# not be made stayed loaded with nothing to unload it.  A buffered channel
# of a tuple left its type behind whenever the buffer could not be made.
#

include "sys.m";
	sys: Sys;
include "draw.m";

LoadHeapfull: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Mod: module
{
	f:	fn(a: int): int;
};

# The same file through a module type that asks for 240 functions: the
# Modlink for it is some kilobytes, more than is left in a full heap.
# (Were it made, the load would be nil: the module has none of them.)
Wide: module
{
	g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11,
	g12, g13, g14, g15, g16, g17, g18, g19, g20, g21, g22, g23,
	g24, g25, g26, g27, g28, g29, g30, g31, g32, g33, g34, g35,
	g36, g37, g38, g39, g40, g41, g42, g43, g44, g45, g46, g47,
	g48, g49, g50, g51, g52, g53, g54, g55, g56, g57, g58, g59,
	g60, g61, g62, g63, g64, g65, g66, g67, g68, g69, g70, g71,
	g72, g73, g74, g75, g76, g77, g78, g79, g80, g81, g82, g83,
	g84, g85, g86, g87, g88, g89, g90, g91, g92, g93, g94, g95,
	g96, g97, g98, g99, g100, g101, g102, g103, g104, g105, g106, g107,
	g108, g109, g110, g111, g112, g113, g114, g115, g116, g117, g118, g119,
	g120, g121, g122, g123, g124, g125, g126, g127, g128, g129, g130, g131,
	g132, g133, g134, g135, g136, g137, g138, g139, g140, g141, g142, g143,
	g144, g145, g146, g147, g148, g149, g150, g151, g152, g153, g154, g155,
	g156, g157, g158, g159, g160, g161, g162, g163, g164, g165, g166, g167,
	g168, g169, g170, g171, g172, g173, g174, g175, g176, g177, g178, g179,
	g180, g181, g182, g183, g184, g185, g186, g187, g188, g189, g190, g191,
	g192, g193, g194, g195, g196, g197, g198, g199, g200, g201, g202, g203,
	g204, g205, g206, g207, g208, g209, g210, g211, g212, g213, g214, g215,
	g216, g217, g218, g219, g220, g221, g222, g223, g224, g225, g226, g227,
	g228, g229, g230, g231, g232, g233, g234, g235, g236, g237, g238, g239:	fn();
};

Any: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

DIR: con "/tmp/load_heapfull";
SRC: con "/dis/tests/load_heapfull_mod.dis";
NMOD: con 150;

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

big1: array of array of byte;
small: array of array of byte;

fill()
{
	i := 0;
	{
		for(; i < len big1; i++)
			if(big1[i] == nil)
				big1[i] = array[1024*1024] of byte;
	} exception {
	"*" =>
		;
	}
	j := 0;
	{
		for(; j < len small; j++)
			if(small[j] == nil)
				small[j] = array[1024] of byte;
	} exception {
	"*" =>
		;
	}
	{
		for(j = 0; j < len small; j++)
			if(small[j] == nil)
				small[j] = array[1] of byte;
	} exception {
	"*" =>
		;
	}
}

copy(src, dst: string): int
{
	fd := sys->open(src, Sys->OREAD);
	if(fd == nil)
		return -1;
	out := sys->create(dst, Sys->OWRITE, 8r644);
	if(out == nil)
		return -1;
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		if(sys->write(out, buf, n) != n)
			return -1;
	return 0;
}

# never called: a module type's functions are asked for at a load only
# if the program uses them
usewide(m: Wide)
{
	m->g0(); m->g1(); m->g2(); m->g3(); m->g4(); m->g5(); m->g6(); m->g7();
	m->g8(); m->g9(); m->g10(); m->g11(); m->g12(); m->g13(); m->g14(); m->g15();
	m->g16(); m->g17(); m->g18(); m->g19(); m->g20(); m->g21(); m->g22(); m->g23();
	m->g24(); m->g25(); m->g26(); m->g27(); m->g28(); m->g29(); m->g30(); m->g31();
	m->g32(); m->g33(); m->g34(); m->g35(); m->g36(); m->g37(); m->g38(); m->g39();
	m->g40(); m->g41(); m->g42(); m->g43(); m->g44(); m->g45(); m->g46(); m->g47();
	m->g48(); m->g49(); m->g50(); m->g51(); m->g52(); m->g53(); m->g54(); m->g55();
	m->g56(); m->g57(); m->g58(); m->g59(); m->g60(); m->g61(); m->g62(); m->g63();
	m->g64(); m->g65(); m->g66(); m->g67(); m->g68(); m->g69(); m->g70(); m->g71();
	m->g72(); m->g73(); m->g74(); m->g75(); m->g76(); m->g77(); m->g78(); m->g79();
	m->g80(); m->g81(); m->g82(); m->g83(); m->g84(); m->g85(); m->g86(); m->g87();
	m->g88(); m->g89(); m->g90(); m->g91(); m->g92(); m->g93(); m->g94(); m->g95();
	m->g96(); m->g97(); m->g98(); m->g99(); m->g100(); m->g101(); m->g102(); m->g103();
	m->g104(); m->g105(); m->g106(); m->g107(); m->g108(); m->g109(); m->g110(); m->g111();
	m->g112(); m->g113(); m->g114(); m->g115(); m->g116(); m->g117(); m->g118(); m->g119();
	m->g120(); m->g121(); m->g122(); m->g123(); m->g124(); m->g125(); m->g126(); m->g127();
	m->g128(); m->g129(); m->g130(); m->g131(); m->g132(); m->g133(); m->g134(); m->g135();
	m->g136(); m->g137(); m->g138(); m->g139(); m->g140(); m->g141(); m->g142(); m->g143();
	m->g144(); m->g145(); m->g146(); m->g147(); m->g148(); m->g149(); m->g150(); m->g151();
	m->g152(); m->g153(); m->g154(); m->g155(); m->g156(); m->g157(); m->g158(); m->g159();
	m->g160(); m->g161(); m->g162(); m->g163(); m->g164(); m->g165(); m->g166(); m->g167();
	m->g168(); m->g169(); m->g170(); m->g171(); m->g172(); m->g173(); m->g174(); m->g175();
	m->g176(); m->g177(); m->g178(); m->g179(); m->g180(); m->g181(); m->g182(); m->g183();
	m->g184(); m->g185(); m->g186(); m->g187(); m->g188(); m->g189(); m->g190(); m->g191();
	m->g192(); m->g193(); m->g194(); m->g195(); m->g196(); m->g197(); m->g198(); m->g199();
	m->g200(); m->g201(); m->g202(); m->g203(); m->g204(); m->g205(); m->g206(); m->g207();
	m->g208(); m->g209(); m->g210(); m->g211(); m->g212(); m->g213(); m->g214(); m->g215();
	m->g216(); m->g217(); m->g218(); m->g219(); m->g220(); m->g221(); m->g222(); m->g223();
	m->g224(); m->g225(); m->g226(); m->g227(); m->g228(); m->g229(); m->g230(); m->g231();
	m->g232(); m->g233(); m->g234(); m->g235(); m->g236(); m->g237(); m->g238(); m->g239();
}

paths: array of string;

loadmods(): (int, int, int)
{
	raised := nilret := loaded := 0;
	for(i := 0; i < len paths; i++){
		{
			m := load Wide paths[i];
			if(m == nil)
				nilret++;
			else
				loaded++;
		} exception {
		"*" =>
			raised++;
		}
	}
	return (raised, nilret, loaded);
}

loadbig(n: int): (int, int, int)
{
	raised := nilret := loaded := 0;
	for(i := 0; i < n; i++){
		{
			m := load Any "/dis/limbo.dis";
			if(m == nil)
				nilret++;
			else
				loaded++;
		} exception {
		"*" =>
			raised++;
		}
	}
	return (raised, nilret, loaded);
}

chans(n: int): int
{
	raised := 0;
	for(i := 0; i < n; i++){
		{
			c := chan[100000000] of (int, int);
			c = nil;
		} exception {
		"*" =>
			raised++;
		}
	}
	return raised;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	membuf = array[4096] of byte;
	memfd = sys->open("/dev/memory", Sys->OREAD);
	if(memfd == nil){
		sys->print("SKIP no /dev/memory\n");
		return;
	}
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r777);
	paths = array[NMOD] of string;
	for(i := 0; i < NMOD; i++){
		paths[i] = sys->sprint("%s/m%d.dis", DIR, i);
		if(copy(SRC, paths[i]) < 0){
			sys->print("SKIP cannot copy %s to %s: %r\n", SRC, paths[i]);
			return;
		}
	}
	big1 = array[2048] of array of byte;
	small = array[1000000] of array of byte;

	# the channels need no full heap: the buffer asked for is beyond it
	m0 := mainsize();
	r := chans(100000);
	m1 := mainsize();
	sys->print("CHANS raised %d grew %d\n", r, m1 - m0);

	fill();
	m0 = mainsize();
	(raised, nilret, loaded) := loadmods();
	m1 = mainsize();
	sys->print("LINK raised %d nil %d loaded %d grew %d\n", raised, nilret, loaded, m1 - m0);

	fill();
	m0 = mainsize();
	(raised, nilret, loaded) = loadbig(30);
	m1 = mainsize();
	sys->print("PARSE raised %d nil %d loaded %d grew %d\n", raised, nilret, loaded, m1 - m0);

	big1 = nil;
	small = nil;

	# with room, they load
	m := load Mod paths[0];
	if(m == nil)
		sys->print("ROOM nil: %r\n");
	else
		sys->print("ROOM f(1) %d\n", m->f(1) != 0);
	c := chan[4] of (int, int);
	c <-= (3, 4);
	c <-= (5, 6);
	(a, b) := <-c;
	(d, e) := <-c;
	sys->print("CHAN %d %d %d %d\n", a, b, d, e);
	u := chan of (int, int);
	alt {
	u <-= (1, 2) =>
		sys->print("UNBUFFERED taken\n");
	* =>
		sys->print("UNBUFFERED empty\n");
	}

	for(i = 0; i < NMOD; i++)
		sys->remove(paths[i]);
	sys->remove(DIR);
	sys->print("DONE\n");
}
