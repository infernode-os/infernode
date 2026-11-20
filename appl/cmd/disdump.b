implement Disdump;

include "sys.m";
	sys: Sys;
include "draw.m";
include "dis.m";
	dis: Dis;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Disdump: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr := sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	if (bufio == nil) {
		sys->fprint(stderr, "dis: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:bad module";
	}

	dis = load Dis Dis->PATH;
	if (dis == nil) {
		sys->fprint(stderr, "dis: cannot load %s: %r\n", Dis->PATH);
		raise "fail:bad module";
	}

	# -l: the links and imports, with their type digests, not the code
	lflag := 0;
	if (len argv > 1 && hd tl argv == "-l") {
		lflag = 1;
		argv = tl argv;
	}
	if (len argv < 2) {
		sys->fprint(stderr, "usage: dis [-l] module...\n");
		raise "fail:usage";
	}
	dis->init();
	out := bufio->fopen(sys->fildes(1), Sys->OWRITE);
	errs := 0;
	for (argv = tl argv; argv != nil; argv = tl argv) {
		(mod, err) := dis->loadobj(hd argv);
		if (mod == nil) {
			sys->fprint(stderr, "dis: failed to load %s: %s\n", hd argv, err);
			errs++;
			continue;
		}
		if (lflag) {
			links(out, mod);
			continue;
		}
		for (i := 0; i < len mod.inst; i++)
			out.puts(dis->inst2s(mod.inst[i])+"\n");
	}
	out.close();
	if (errs)
		raise "fail:errors";
}

hex(d: array of byte): string
{
	if (d == nil)
		return "-";
	s := "";
	for (i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

# what the loader checks when the module is linked: each function it
# exports and imports, its 32-bit signature and, where the file has
# them (HASSIGS), the digest of its type
links(out: ref Iobuf, m: ref Dis->Mod)
{
	out.puts(sys->sprint("module %s rt 0x%ux\n", m.name, m.rt));
	for (i := 0; i < len m.links; i++) {
		l := m.links[i];
		out.puts(sys->sprint("\tlink %d,%d, 0x%ux, \"%s\" %s\n", l.desc, l.pc, l.sig, l.name, hex(l.dig)));
	}
	for (i = 0; i < len m.imports; i++)
		for (j := 0; j < len m.imports[i]; j++) {
			im := m.imports[i][j];
			out.puts(sys->sprint("\timport %d 0x%ux, \"%s\" %s\n", i, im.sig, im.name, hex(im.dig)));
		}
}
