implement NinepsrcConfigTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "msgsrc.m";

NinepsrcConfigTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

SRC: con "/dis/veltro/ninepsrc.dis";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	checkaccept("mounted=1");
	checkaccept("name=events-1 mounted=1 mountpt=/n/events file=events tsfield=unixsecs");
	checkreject("name=bad/name mounted=1", "unsafe source name");
	checkreject("name=bad\nname mounted=1", "unsafe source name");
	checkreject("mount=tcp!host!5640\nfile=x mounted=0", "unsafe mount");
	checkreject("mounted=1 mountpt=/mnt/msg", "unsafe mountpt");
	checkreject("mounted=1 mountpt=/n/../msg", "unsafe mountpt");
	checkreject("mounted=1 file=/events", "unsafe file");
	checkreject("mounted=1 file=../events", "unsafe file");
	checkreject("mounted=1 file=events\nctl", "unsafe file");
	checkreject("mounted=1 tsfield=../../x", "unsafe tsfield");

	sys->print("NINEPSRC_CONFIG: PASS unsafe config rejected\n");
}

checkaccept(config: string)
{
	src := load MsgSrc SRC;
	if(src == nil) {
		sys->print("NINEPSRC_CONFIG: FAIL cannot load %s: %r\n", SRC);
		raise "fail:ninepsrc";
	}
	err := src->init(config);
	if(err != nil) {
		sys->print("NINEPSRC_CONFIG: FAIL rejected safe config %s: %s\n", config, err);
		raise "fail:ninepsrc";
	}
}

checkreject(config, want: string)
{
	src := load MsgSrc SRC;
	if(src == nil) {
		sys->print("NINEPSRC_CONFIG: FAIL cannot load %s: %r\n", SRC);
		raise "fail:ninepsrc";
	}
	err := src->init(config);
	if(err == nil) {
		sys->print("NINEPSRC_CONFIG: FAIL accepted unsafe config: %s\n", config);
		raise "fail:ninepsrc";
	}
	if(!contains(err, want)) {
		sys->print("NINEPSRC_CONFIG: FAIL wrong error for %s: %s\n", config, err);
		raise "fail:ninepsrc";
	}
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}
